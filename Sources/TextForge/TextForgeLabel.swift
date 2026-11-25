import UIKit

/// 简单文本沿用 UILabel，复杂排版、绘制、附件和交互共用 TextForgeLayout。
@objc(TextForgeLabel)
open class TextForgeLabel: UILabel, UIGestureRecognizerDelegate {
    /// 文本与控件边界之间的内边距，单位为点，使用非负的有限值。
    @objc public var contentInsets: UIEdgeInsets = .zero {
        didSet {
            guard contentInsets != oldValue else { return }
            invalidateTextLayout()
        }
    }

    @objc public var textContainerInset: UIEdgeInsets {
        get { contentInsets }
        set { contentInsets = newValue }
    }

    /// 非零时以点覆盖全串字距，设回 0 后恢复 attributedText 的原始字距。
    @objc public var characterSpacing: CGFloat = 0 { didSet { invalidateTextLayout() } }
    /// 非零时以点覆盖行距；设回 0 后恢复每段原始行距。
    @objc public var lineSpacing: CGFloat = 0 { didSet { invalidateTextLayout() } }
    /// 非零时以点覆盖段后距；设回 0 后恢复每段原始段距。
    @objc public var paragraphSpacing: CGFloat = 0 { didSet { invalidateTextLayout() } }
    /// 大于 0 时以点锁定每行高度并按该行字体居中基线，防止行内大尺寸徽章或表情撑高单行。
    @objc public var fixedLineHeight: CGFloat = 0 {
        didSet {
            if fixedLineHeight != oldValue { invalidateTextLayout() }
        }
    }
    @objc public var textVerticalAlignment: TextForgeVerticalAlignment = .center {
        didSet { invalidateTextLayout() }
    }

    /// 显式赋值时，以该布局为准，设为 nil 恢复控件内容。只读时也可取得仍适配控件宽度的异步结果。
    @objc public var textLayout: TextForgeLayout? {
        get {
            if let explicitTextLayout { return explicitTextLayout }
            guard let preparedTextLayout, bounds.width == 0 || bounds.width == preparedTextLayout.size.width else { return nil }
            return preparedTextLayout
        }
        set {
            explicitTextLayout = newValue
            invalidateTextLayout()
        }
    }

    /// 末行放不下时替代系统省略号的标记，例如"…全文"。仅在 `lineBreakMode` 为 `.byTruncatingTail` 时生效。
    /// 标记缺少的字体和颜色沿用截断处的正文，可携带 TextForgeHighlight 或链接响应点击。
    @objc public var truncationToken: NSAttributedString? {
        didSet {
            truncationToken = truncationToken.map { NSAttributedString(attributedString: $0) }
            invalidateTextLayout()
        }
    }

    /// 文本需要绕开的区域，坐标以扣除内边距后的内容区左上角为原点。
    @objc public var exclusionPaths: [UIBezierPath] = [] { didSet { invalidateTextLayout() } }

    /// 叠加在 `.link` 范围上的显示属性，会覆盖该范围原有的同名属性。传空字典则保留文本自身样式。
    @objc public var linkTextAttributes: [NSAttributedString.Key: Any] = TextForgeContainer.defaultLinkTextAttributes {
        didSet { hasExplicitLinkStyle = true; invalidateTextLayout() }
    }

    /// 只对这个标签生效的排版调试叠层，nil 时沿用 `TextForgeDebugOptions.shared`。
    @objc public var debugOptions: TextForgeDebugOptions? { didSet { invalidateTextLayout() } }

    /// 高亮和链接的触摸热区向外扩展的半径，单位为点。手指落在多个热区内时取最近的一个。
    @objc public var highlightTouchExtensionRadius: CGFloat = 0

    /// 开启后长按弹出系统的拷贝菜单，复制当前文本的全文，附件占位字符不会进入剪贴板。
    @objc public var allowsCopy = false

    /// 开启后长按正文按词选择，可拖手柄并复制选区。默认关闭，原来的长按全文复制继续由 allowsCopy 控制。
    @objc public var isSelectable = false { didSet { if oldValue != isSelectable { invalidateTextLayout() } } }
    private var selection: TextForgeLabelSelection?
    private var extendingWord = false

    /// 有选区时，点到标签以外的地方是否清除选区，默认开启。标签外有按钮要读取 `selectedText` 时关掉它，
    /// 否则点按钮的同一下触摸会先把选区清掉。
    @objc public var clearsSelectionOnOutsideTap = true {
        didSet { if oldValue != clearsSelectionOnOutsideTap { observeOutsideTaps() } }
    }
    /// 选区存在期间挂在窗口上的点击识别器。不取消、不延迟触摸，与其他手势同时识别。
    private weak var outsideTapGesture: UITapGestureRecognizer?

    /// 选区菜单里排在系统操作之后的自定义项，例如"引用""搜索"。iOS 16 起生效，更早的系统只显示系统操作。
    @objc public var selectionActions: [TextForgeSelectionAction] = []

    /// 以原文 UTF-16 下标表示当前选区；无选区时 location 为 NSNotFound。
    @objc public var selectedRange: NSRange { selection?.range ?? NSRange(location: NSNotFound, length: 0) }

    /// 选区的复制文案，保留附件替代文字；无选区时为 nil。
    @objc public var selectedText: String? {
        guard let selection else { return nil }
        return TextForgeAttachment.copyText(for: selection.layout.attributedText.attributedSubstring(from: selection.range))
    }

    /// 手动选择一段可见正文，端点扩展到完整字素。越界、跨截断缺口或未启用选择时返回 false，保留现有选区。
    @objc(selectTextInRange:) @discardableResult
    public func selectText(in range: NSRange) -> Bool {
        guard isSelectable, let layout = displayedTextLayout else { return false }
        let text = layout.attributedText.string as NSString
        guard range.location >= 0, range.location < text.length, range.length > 0,
              range.length <= text.length - range.location else { return false }
        let expanded = text.rangeOfComposedCharacterSequences(for: range)
        guard let segment = layout.selectionSegments.first(where: { NSIntersectionRange($0, expanded) == expanded }) else { return false }
        if let selection, selection.layout === layout, selection.segment == segment {
            selection.setRange(expanded, asAnchor: true)
        } else {
            clearSelection()
            let overlay = TextForgeLabelSelection(layout: layout, segment: segment, range: expanded)
            selection = overlay
            addSubview(overlay)
            positionSelection(overlay)
            observeOutsideTaps()
        }
        return true
    }

    /// 选择点中的系统分词；表情、标点和附件按单个字素选择。坐标相对标签，省略号与“全文”标记保留原交互。
    @objc(selectWordAtPoint:) @discardableResult
    public func selectWord(at point: CGPoint) -> Bool {
        guard isSelectable, let layout = displayedTextLayout else { return false }
        let index = characterIndex(at: point)
        guard let segment = layout.selectionSegments.first(where: { NSLocationInRange(index, $0) }) else { return false }
        let string = layout.attributedText.string as NSString
        var word = string.rangeOfComposedCharacterSequence(at: index)
        string.enumerateSubstrings(in: string.paragraphRange(for: word), options: [.byWords, .localized, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(index, range) { word = range }
            if NSMaxRange(range) > index { stop.pointee = true }
        }
        return selectText(in: NSIntersectionRange(word, segment))
    }

    /// 清除视觉选区及其菜单，Cell 换文或离开窗口时也会执行。
    @objc public func clearSelection() {
        guard let selection else { return }
        extendingWord = false
        self.selection = nil
        selection.removeFromSuperview()
        observeOutsideTaps()
        dismissSelectionMenu()
    }

    /// 按当前状态挂上或摘掉窗口上的点击识别器：有选区、已开启且标签在窗口里时才需要它。
    private func observeOutsideTaps() {
        let host = selection != nil && clearsSelectionOnOutsideTap ? window : nil
        if outsideTapGesture?.view === host { return }
        if let outsideTapGesture { outsideTapGesture.view?.removeGestureRecognizer(outsideTapGesture) }
        guard let host else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        host.addGestureRecognizer(tap)
        outsideTapGesture = tap
    }

    /// 点击落在标签和选区手柄之外才会送到这里，见 `gestureRecognizer(_:shouldReceive:)`。
    @objc private func handleOutsideTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { clearSelection() }
    }

    /// 把选区扩到它所在的整段连续可见正文，并重新弹出菜单。截断留下的缺口另一侧不会被选中。
    open override func selectAll(_ sender: Any?) {
        guard let selection, selectText(in: selection.segment) else { return }
        showSelectionMenu()
    }

    /// 为伸出标签的手柄圆点保留绘制空间，并将文字原点转换到覆盖层坐标。
    private func positionSelection(_ overlay: TextForgeLabelSelection) {
        overlay.frame = bounds.insetBy(dx: -4, dy: -4)
        let origin = drawingOrigin(for: overlay.layout)
        overlay.refresh(origin: convert(origin, to: overlay))
        bringSubviewToFront(overlay)
    }

    /// 手指松开后使用实际选区作为系统复制菜单的锚点。
    func showSelectionMenu() {
        guard let selection, !selection.menuRect.isEmpty else { return }
        let area = selection.convert(selection.menuRect, to: self)
        presentCopyMenu(at: CGPoint(x: area.midX, y: area.midY))
    }

    /// 只收起本标签的菜单，避免复用或拖选打断其他第一响应者。
    func dismissSelectionMenu() {
        guard isFirstResponder else { return }
        if #available(iOS 16.0, *) {
            interactions.compactMap { $0 as? UIEditMenuInteraction }.first?.dismissMenu()
        } else {
            UIMenuController.shared.hideMenu(from: self)
        }
    }

    /// 切换输入焦点后清理旧选区，防止继续复制先前标签内的文字。
    open override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { clearSelection() }
        return resigned
    }

    /// 离开窗口时释放手柄、滚动观察和窗口上的点击旁观；进入新层级后按新视口挂载附件，已有选区改到新窗口旁观。
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearSelection(); stopObservingScrolls() }
        observeOutsideTaps()
        setNeedsLayout()
    }

    /// 拷贝菜单出现和消失时在主线程回调，参数为是否可见。可用来切换选中底色。
    @objc public var copyMenuVisibilityHandler: ((Bool) -> Void)?

    @objc public var textTapAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var textLongPressAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var highlightTapAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var highlightLongPressAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }

    private var hasExplicitLinkStyle = false
    private var cachedLayouts: [TextForgeLayout] = []
    private var previousLayouts: [TextForgeLayout.ParagraphCandidate] = []
    private var explicitTextLayout: TextForgeLayout?
    private var preparedTextLayout: TextForgeLayout?
    private var pendingLayout: TextForgeLayoutTask?
    private var pendingLayoutWidth: CGFloat?
    private var requiresAttributedLayout = false
    private var scrollObservations: [NSKeyValueObservation] = []
    private var observedScrolls: [ObjectIdentifier] = []
    private var attachedViews: [UIView] = []
    private var activeHighlight: (highlight: TextForgeHighlight, range: NSRange, inToken: Bool)?
    private weak var actionTapGesture: UITapGestureRecognizer?
    private weak var actionPressGesture: UILongPressGestureRecognizer?
    private var customAccessibilityLabel: String?
    private var linkElements: [TextForgeLinkElement] = []
    private var defaultFont: UIFont?
    private var defaultTextColor: UIColor?
    private var defaultTextAlignment: NSTextAlignment = .natural
    private var defaultLineBreakMode: NSLineBreakMode = .byTruncatingTail
    private var isStoringAttributedText = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        defaultFont = super.font
        defaultTextColor = super.textColor
        defaultTextAlignment = super.textAlignment
        defaultLineBreakMode = super.lineBreakMode
        configureInteraction()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        defaultFont = super.font
        defaultTextColor = super.textColor
        defaultTextAlignment = super.textAlignment
        defaultLineBreakMode = super.lineBreakMode
        configureInteraction()
        refreshAttributeUsage()
    }

    /// 销毁标签时撤销排队或等待回到主线程的工作。
    deinit {
        pendingLayout?.cancel()
    }

    /// 切回纯文本时恢复宿主的默认样式；显式布局继续优先显示。
    open override var text: String? {
        get { textLayout?.attributedText.string ?? super.text }
        set {
            preparedTextLayout = nil
            isStoringAttributedText = true
            super.text = newValue
            restorePlainTextStyle()
            isStoringAttributedText = false
            refreshAttributeUsage()
        }
    }

    /// 读取当前显示的富文本。赋值替换内部异步内容，显式布局继续优先显示。
    open override var attributedText: NSAttributedString? {
        get { textLayout?.attributedText ?? super.attributedText }
        set { storeAttributedText(newValue) }
    }
    // 选中态仅影响绘制，切换时可继续使用同一份布局和常态位图。
    open override var isHighlighted: Bool { didSet { if oldValue != isHighlighted { setNeedsDisplay() } } }
    open override var highlightedTextColor: UIColor? { didSet { setNeedsDisplay() } }
    /// 宿主变更默认字体时重新排版，忽略 UIKit 存储富文本时同步的首段样式。
    open override var font: UIFont! {
        didSet {
            guard !isStoringAttributedText, defaultFont != super.font else { return }
            defaultFont = super.font
            invalidateTextLayout()
        }
    }
    /// 宿主变更默认文字颜色时重新排版，忽略 UIKit 存储富文本时同步的首段样式。
    open override var textColor: UIColor! {
        didSet {
            guard !isStoringAttributedText, defaultTextColor != super.textColor else { return }
            defaultTextColor = super.textColor
            invalidateTextLayout()
        }
    }
    /// 宿主变更默认对齐方式时重新排版，忽略 UIKit 存储富文本时同步的首段样式。
    open override var textAlignment: NSTextAlignment {
        didSet {
            guard !isStoringAttributedText, defaultTextAlignment != super.textAlignment else { return }
            defaultTextAlignment = super.textAlignment
            invalidateTextLayout()
        }
    }
    /// 宿主变更默认断行模式时重新排版，忽略 UIKit 存储富文本时同步的首段样式。
    open override var lineBreakMode: NSLineBreakMode {
        didSet {
            guard !isStoringAttributedText, defaultLineBreakMode != super.lineBreakMode else { return }
            defaultLineBreakMode = super.lineBreakMode
            invalidateTextLayout()
        }
    }
    open override var numberOfLines: Int { didSet { if numberOfLines != oldValue { invalidateTextLayout() } } }
    open override var adjustsFontSizeToFitWidth: Bool {
        didSet { if adjustsFontSizeToFitWidth != oldValue { invalidateTextLayout() } }
    }
    open override var minimumScaleFactor: CGFloat {
        didSet { if minimumScaleFactor != oldValue { invalidateTextLayout() } }
    }
    open override var preferredMaxLayoutWidth: CGFloat {
        didSet { if preferredMaxLayoutWidth != oldValue { invalidateTextLayout() } }
    }

    /// 保留宿主显式设置的朗读文案，否则跟随当前文本并去掉附件占位字符。
    open override var accessibilityLabel: String? {
        get {
            if let customAccessibilityLabel { return customAccessibilityLabel }
            if let attributedText { return TextForgeAttachment.accessibilityText(for: attributedText) }
            return text?.replacingOccurrences(of: "\u{FFFC}", with: "") ?? super.accessibilityLabel
        }
        set {
            customAccessibilityLabel = newValue
            super.accessibilityLabel = newValue
        }
    }

    /// 将可见且可点击的高亮附加为 VoiceOver 操作，保留宿主原有自定义操作。显示出来的截断标记同样参与。
    open override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let inherited = super.accessibilityCustomActions ?? []
            guard usesCustomLayout, !bounds.isEmpty else {
                return inherited.isEmpty ? nil : inherited
            }
            let result = layout(for: bounds.size)
            let actions = inherited + accessibleHighlights(in: result).map { item in
                UIAccessibilityCustomAction(name: item.name) { [weak self, weak result] _ in
                    guard let self, let result, !self.bounds.isEmpty,
                          self.layout(for: self.bounds.size) === result else { return false }
                    return self.dispatchTap(self.interaction(atCharacter: item.index, inToken: item.inToken, in: result))
                }
            }
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    /// 给 VoiceOver 的"链接"转子提供可见且可点击的高亮和链接，用户可以在转子里逐个跳转并双击激活。
    /// 标签本身仍是一个整体元素，朗读全文的方式不变；宿主设置的其他转子保留。
    open override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            let inherited = super.accessibilityCustomRotors ?? []
            guard !currentLinkElements().isEmpty else { return inherited.isEmpty ? nil : inherited }
            let rotor = UIAccessibilityCustomRotor(systemType: .link) { [weak self] predicate in
                // 每次按当前显示的布局取目标：文本或尺寸变化后，旧元素按范围对不上就从头开始。
                guard let self else { return nil }
                let elements = self.currentLinkElements()
                let current = predicate.currentItem.targetElement as? TextForgeLinkElement
                let position = current.flatMap { element in
                    elements.firstIndex { $0.range == element.range && $0.inToken == element.inToken }
                }
                let forward = predicate.searchDirection == .next
                let next = position.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : elements.count - 1)
                guard elements.indices.contains(next) else { return nil }
                return UIAccessibilityCustomRotorItemResult(targetElement: elements[next], targetRange: nil)
            }
            return inherited + [rotor]
        }
        set { super.accessibilityCustomRotors = newValue }
    }

    /// 当前布局里"链接"转子的目标。系统只弱引用转子返回的元素，所以由标签按布局缓存；布局换了就重建。
    private func currentLinkElements() -> [TextForgeLinkElement] {
        guard usesCustomLayout, !bounds.isEmpty else {
            linkElements.removeAll()
            return []
        }
        let result = layout(for: bounds.size)
        if let first = linkElements.first, first.layout === result { return linkElements }
        linkElements = accessibleHighlights(in: result).map { item in
            let element = TextForgeLinkElement(label: self, layout: result, index: item.index, range: item.range, inToken: item.inToken)
            element.accessibilityLabel = item.name
            element.accessibilityTraits = .link
            return element
        }
        return linkElements
    }

    /// 列出布局里可见、有朗读名称且点击后确实有回调可执行的高亮和链接，正文在前、截断标记在后。
    /// index 是该项第一个可见字符的下标，range 是完整高亮范围；inToken 为 true 时两者都相对截断标记。
    private func accessibleHighlights(in result: TextForgeLayout) -> [(name: String, index: Int, range: NSRange, inToken: Bool)] {
        var items: [(name: String, index: Int, range: NSRange, inToken: Bool)] = []
        var scopes: [(text: NSAttributedString, range: NSRange, inToken: Bool)] = []
        if let visible = result.visibleCharacterRange { scopes.append((result.attributedText, visible, false)) }
        if result.showsTruncationToken, let token = result.truncationToken {
            scopes.append((token, NSRange(location: 0, length: token.length), true))
        }
        for scope in scopes {
            var seen = Set<NSRange>()
            scope.text.enumerateAttributes(in: scope.range) { attributes, range, _ in
                guard attributes[TextForgeHighlight.attributeName] != nil || attributes[.link] != nil else { return }
                guard let index = result.firstVisibleCharacter(in: range, inToken: scope.inToken) else { return }
                let hit = interaction(atCharacter: index, inToken: scope.inToken, in: result)
                guard hit.highlight?.tapAction != nil || highlightTapAction != nil || textTapAction != nil,
                      seen.insert(hit.highlightRange).inserted else { return }
                let name = TextForgeAttachment.accessibilityText(for: hit.text.attributedSubstring(from: hit.highlightRange))
                guard !name.isEmpty else { return }
                items.append((name, index, hit.highlightRange, scope.inToken))
            }
        }
        return items
    }

    /// 转子里的链接被激活或被询问位置时调用。布局已经换掉时返回 nil，旧元素随之失效。
    fileprivate func linkInteraction(index: Int, inToken: Bool, in result: TextForgeLayout) -> (rect: CGRect, activate: () -> Bool)? {
        guard !bounds.isEmpty, layout(for: bounds.size) === result else { return nil }
        let hit = interaction(atCharacter: index, inToken: inToken, in: result)
        guard hit.highlightRange.location != NSNotFound else { return nil }
        return (hit.highlightRect, { [weak self] in self?.dispatchTap(hit) ?? false })
    }

    /// 当前边界下实际用于绘制的布局，可查询行数、逐行信息和是否截断。控件尚无尺寸时为 nil。
    /// 布局的坐标以文本外部边界左上角为原点，换算到控件坐标请用本类的 `characterIndex(at:)` 和 `rect(forRange:)`。
    /// 普通文本走系统 UILabel 绘制时，这里返回的是按相同参数用 TextKit 排出的近似结果。
    @objc public var displayedTextLayout: TextForgeLayout? {
        bounds.isEmpty ? nil : layout(for: bounds.size)
    }

    /// 当前边界下内容是否放不下。控件尚无尺寸时为 false。
    @objc public var isTruncated: Bool { displayedTextLayout?.isTruncated ?? false }

    /// 是否有可见的自定义截断标记。
    @objc public var showsTruncationToken: Bool { displayedTextLayout?.showsTruncationToken ?? false }

    /// 可见标记在标签坐标中的外接矩形，未显示时返回 CGRect.null。
    @objc public var truncationTokenRect: CGRect {
        guard let result = displayedTextLayout else { return .null }
        let rect = result.truncationTokenRect
        guard !rect.isNull else { return .null }
        let origin = drawingOrigin(for: result)
        return rect.offsetBy(dx: origin.x - result.insets.left, dy: origin.y - result.insets.top)
    }

    /// 返回控件坐标下该点所在字形对应的原文 UTF-16 下标，落在空白或截断标记上时返回 NSNotFound。
    @objc(characterIndexAtPoint:) public func characterIndex(at point: CGPoint) -> Int {
        guard let result = displayedTextLayout else { return NSNotFound }
        let origin = drawingOrigin(for: result)
        return result.characterIndex(at: CGPoint(
            x: point.x - origin.x + result.insets.left, y: point.y - origin.y + result.insets.top
        ))
    }

    /// 返回原文范围在控件坐标下的外接矩形，范围不可见或控件尚无尺寸时为 `CGRect.null`。
    @objc(rectForRange:) public func rect(forRange range: NSRange) -> CGRect {
        guard let result = displayedTextLayout else { return .null }
        let origin = drawingOrigin(for: result)
        return result.containerRect(for: range, inToken: false).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 允许拷贝时可成为第一响应者，系统菜单据此找到拷贝操作。
    open override var canBecomeFirstResponder: Bool { allowsCopy || isSelectable || super.canBecomeFirstResponder }

    /// 只在允许拷贝且有文本时提供拷贝操作；选区还没占满所在的可见片段时提供全选。其余编辑操作沿用系统判断。
    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return (allowsCopy || selection != nil) && !copyableText.isEmpty }
        if action == #selector(selectAll(_:)) { return selection.map { $0.range != $0.segment } ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// 有局部选区时复制选区，否则沿用全文复制。附件均使用其替代文案。
    open override func copy(_ sender: Any?) {
        guard selection != nil || allowsCopy else { return }
        let text = copyableText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    /// 清除旧内容并按指定的点尺寸准备新布局。更换内容、样式或设置不匹配的宽度会取消等待中的请求。
    /// 主线程交付后保存原始富文本，后续样式或尺寸变化可以用其重新排版。
    @discardableResult
    @objc public func setAttributedTextAsynchronously(
        _ text: NSAttributedString, size: CGSize, rendersAsynchronously: Bool,
        completion: (() -> Void)? = nil
    ) -> TextForgeLayoutTask {
        let startingWidth = bounds.width
        let source = NSAttributedString(attributedString: text)
        explicitTextLayout = nil
        storeAttributedText(nil)
        let task = TextForgeLayout.prepare(
            attributedText: styledText(source), container: makeContainer(size: size, rows: numberOfLines),
            renderScale: rendersAsynchronously ? max(1, traitCollection.displayScale) : 0,
            traitCollection: traitCollection
        ) { [weak self] result in
            guard let self else { return }
            if self.bounds.width != startingWidth, self.bounds.width != size.width {
                self.cancelPendingLayout()
                return
            }
            self.pendingLayout = nil
            self.pendingLayoutWidth = nil
            self.storeAttributedText(source)
            self.preparedTextLayout = result
            completion?()
        }
        pendingLayout = task
        pendingLayoutWidth = size.width
        return task
    }

    /// 换文时保留不限行正文的候选栈，下次同尺寸排版可复用未变化段；保护控件默认字体与颜色不被首字符局部属性覆盖。
    private func storeAttributedText(_ text: NSAttributedString?) {
        var candidates: [TextForgeLayout.ParagraphCandidate] = []
        if text != nil, numberOfLines == 0, explicitTextLayout == nil {
            candidates = cachedLayouts.isEmpty ? previousLayouts : cachedLayouts.compactMap(TextForgeLayout.ParagraphCandidate.init)
        }
        preparedTextLayout = nil
        isStoringAttributedText = true
        super.attributedText = text
        if text == nil { restorePlainTextStyle() }
        isStoringAttributedText = false
        refreshAttributeUsage()
        if usesCustomLayout { previousLayouts = candidates }
    }

    /// 在纯文本赋值事务中恢复 UIKit 绘制与测量使用的样式，避免沿用上一段富文本的首字符属性。
    private func restorePlainTextStyle() {
        if let defaultFont, super.font != defaultFont { super.font = defaultFont }
        if let defaultTextColor, super.textColor != defaultTextColor { super.textColor = defaultTextColor }
        if super.textAlignment != defaultTextAlignment { super.textAlignment = defaultTextAlignment }
        if super.lineBreakMode != defaultLineBreakMode { super.lineBreakMode = defaultLineBreakMode }
    }

    /// 首次获得宽度时也校验待交付结果。已交付的异步文本保留原文，宽度变化后重新排版。
    open override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size { clearSelection() }
            guard oldValue.width != bounds.width else { return }
            if let pendingLayoutWidth, bounds.width != pendingLayoutWidth {
                cancelPendingLayout()
            }
            if let preparedTextLayout, bounds.width != preparedTextLayout.size.width {
                invalidateTextLayout()
            }
        }
    }

    /// 用 frame 改变尺寸不经过 bounds 的属性观察。这里同样清除选区，避免手柄和底色停在旧排版的位置。
    open override var frame: CGRect {
        didSet { if oldValue.size != frame.size { clearSelection() } }
    }

    /// 标签环境变化时刷新像素；字号、方向或字重环境变化时清空派生几何并通知宿主重新测高。
    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection != previousTraitCollection else { return }
        previousLayouts.removeAll(keepingCapacity: true)
        cachedLayouts.removeAll(keepingCapacity: true)
        let previousLayoutMatched = previousTraitCollection.map { textLayout?.matchesAppearance($0) ?? true } ?? true
        if !previousLayoutMatched || textLayout?.matchesAppearance(traitCollection) == false ||
            traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory ||
            traitCollection.layoutDirection != previousTraitCollection?.layoutDirection ||
            traitCollection.legibilityWeight != previousTraitCollection?.legibilityWeight {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
        setNeedsDisplay()
    }

    /// 为富文本使用当前可用宽度测量，普通标签保持系统固有尺寸算法。
    open override var intrinsicContentSize: CGSize {
        if let explicitTextLayout { return measuredSize(of: layout(for: explicitTextLayout.size)) }
        guard usesCustomLayout else { return super.intrinsicContentSize }
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : (
            numberOfLines != 1 && bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude
        )
        return measuredSize(of: layout(for: CGSize(width: width, height: .greatestFiniteMagnitude), measuring: true))
    }

    /// 显式绘制预排版文本，即使 UILabel 自己没有设置 text 或 attributedText。
    open override func draw(_ rect: CGRect) {
        if usesCustomLayout {
            drawText(in: rect)
        } else {
            super.draw(rect)
        }
    }

    /// 按调用方的边界测量富文本，显式布局直接返回其尺寸，内部结果仅在约束兼容时复用。
    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard usesCustomLayout else { return super.sizeThatFits(size) }
        return measuredSize(of: layout(for: CGSize(
            width: size.width > 0 ? size.width : .greatestFiniteMagnitude,
            height: size.height > 0 ? size.height : .greatestFiniteMagnitude
        ), measuring: true))
    }

    /// 显式布局按完整尺寸占位，切换外观触发重排后也保持此规则。控件自身排版按文字宽度自适应。
    private func measuredSize(of result: TextForgeLayout) -> CGSize {
        explicitTextLayout != nil ? result.textBoundingSize : result.fittingSize
    }

    /// 在扣除内边距后的可用宽度测量文本，并把内边距计入返回的文本区域。
    /// UIKit 解析基线锚点时也会调用这里：单行文本的基线是系统实现在测量过程中记下的。自定义排版不走系统实现，
    /// 基线会落在标签顶边，所以单行时用同一内容区再问一次系统实现，让它按标签自己的文本记下基线，返回值不用。
    /// 固定行高把文字在行框里上下居中，内容区相应下移后再问。显式 `textLayout` 的内容不在系统标签里，这种标签的基线锚点仍在顶边。
    open override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        if usesCustomLayout {
            let result = layout(for: bounds.size, maximumNumberOfRows: numberOfLines, measuring: true)
            if numberOfLines == 1, explicitTextLayout == nil {
                var content = insetTextRect(bounds)
                if fixedLineHeight > 0, let line = result.lines.first, line.range.length > 0 {
                    var ascent: CGFloat = 0
                    result.attributedText.enumerateAttribute(.font, in: line.range) { value, _, _ in
                        if let font = value as? UIFont { ascent = max(ascent, font.ascender) }
                    }
                    if ascent > 0 { content.origin.y += line.baseline - result.insets.top - ascent }
                }
                _ = super.textRect(forBounds: content, limitedToNumberOfLines: numberOfLines)
            }
            return CGRect(origin: bounds.origin, size: measuredSize(of: result))
        }
        let contentRect = insetTextRect(bounds)
        let textRect = super.textRect(forBounds: contentRect, limitedToNumberOfLines: numberOfLines)
        guard !textRect.isEmpty else { return .zero }
        return CGRect(
            x: textRect.origin.x - contentInsets.left,
            y: textRect.origin.y - contentInsets.top,
            width: textRect.width + contentInsets.left + contentInsets.right,
            height: textRect.height + contentInsets.top + contentInsets.bottom
        )
    }

    /// 在与测量一致的内容区域绘制，宽度或高度耗尽时跳过绘制。开启调试叠层时在文字之上再画一层调试线。
    open override func drawText(in rect: CGRect) {
        if usesCustomLayout {
            guard !bounds.isEmpty else { return }
            let result = layout(for: bounds.size)
            result.draw(
                at: drawingOrigin(for: result),
                activeRange: activeHighlight?.range,
                activeInToken: activeHighlight?.inToken ?? false,
                activeBackground: activeHighlight?.highlight.pressedBackground,
                activeForeground: activeHighlight?.highlight.highlightedTextColor,
                highlightedColor: isHighlighted ? highlightedTextColor : nil,
                clip: rect.intersection(UIGraphicsGetCurrentContext()?.boundingBoxOfClipPath ?? rect), traits: traitCollection
            )
            if let options = debugOptions ?? TextForgeDebugOptions.shared { drawDebugOverlay(for: result, options: options) }
            return
        }
        let contentRect = insetTextRect(rect)
        guard !contentRect.isEmpty else { return }
        super.drawText(in: contentRect)
    }

    /// 在文字之上按一个像素的线宽画出调试线：每行的占用矩形与基线、整段文字的外接矩形、附件槽。
    /// 位置取自正在显示的同一份布局；截断标记里的附件不画。
    private func drawDebugOverlay(for result: TextForgeLayout, options: TextForgeDebugOptions) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let origin = drawingOrigin(for: result)
        // 布局的公开坐标以外部边界左上角为原点，换到标签坐标。
        let offset = CGPoint(x: origin.x - result.insets.left, y: origin.y - result.insets.top)
        let scale = max(1, traitCollection.displayScale)
        let width = 1 / scale
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(width)
        // 边线落在整像素上才是清晰的一像素线：外沿对齐到像素，再向内收半个线宽。
        func stroke(_ rect: CGRect, _ color: UIColor) {
            guard !rect.isNull else { return }
            let moved = rect.offsetBy(dx: offset.x, dy: offset.y)
            let minX = (moved.minX * scale).rounded(.down) / scale, minY = (moved.minY * scale).rounded(.down) / scale
            let maxX = (moved.maxX * scale).rounded(.up) / scale, maxY = (moved.maxY * scale).rounded(.up) / scale
            context.setStrokeColor(color.cgColor)
            context.stroke(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: width / 2, dy: width / 2))
        }
        if let color = options.lineColor { for line in result.lines { stroke(line.rect, color) } }
        if let color = options.textBoundsColor { stroke(result.textBoundingRect, color) }
        if let color = options.attachmentColor, let visible = result.visibleCharacterRange {
            result.attributedText.enumerateAttribute(.attachment, in: visible) { value, range, _ in
                guard value != nil else { return }
                for index in range.location..<NSMaxRange(range) {
                    for rect in result.rects(forRange: NSRange(location: index, length: 1)) { stroke(rect, color) }
                }
            }
        }
        if let color = options.baselineColor {
            context.setStrokeColor(color.cgColor)
            for line in result.lines {
                let y = ((line.baseline + offset.y) * scale).rounded(.down) / scale + width / 2
                context.move(to: CGPoint(x: line.rect.minX + offset.x, y: y))
                context.addLine(to: CGPoint(x: line.rect.maxX + offset.x, y: y))
            }
            context.strokePath()
        }
    }

    /// 退出窗口或换文时解除观察，避免滚动视图离开后继续驱动旧标签。
    private func stopObservingScrolls() {
        scrollObservations.removeAll()
        observedScrolls.removeAll()
    }

    /// 求各级裁剪视图的交集；滚动不一定触发子视图布局，观察滚动容器的可见边界以驱动附件进出。
    private func attachmentViewport() -> CGRect {
        var visible = bounds
        var ancestor = superview
        var scrolls: [UIScrollView] = []
        while let view = ancestor {
            if view.clipsToBounds {
                visible = visible.intersection(convert(view.bounds, from: view))
                if let scroll = view as? UIScrollView { scrolls.append(scroll) }
            }
            ancestor = view.superview
        }
        let ids = scrolls.map(ObjectIdentifier.init)
        if ids != observedScrolls {
            observedScrolls = ids
            scrollObservations = scrolls.flatMap { scroll in
                // UIKit 在主线程更改滚动几何，KVO 在写入线程同步回调，确保本轮 layoutIfNeeded 能看到新视口。
                [scroll.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.setNeedsLayout() } },
                 scroll.observe(\.bounds) { [weak self] _, _ in MainActor.assumeIsolated { self?.setNeedsLayout() } }]
            }
        }
        return visible
    }

    /// 按标签绘制原点和滚动视口挂载相交附件，回收离屏视图并保持选区位于附件上方。
    open override func layoutSubviews() {
        super.layoutSubviews()
        guard usesCustomLayout, !bounds.isEmpty else {
            removeAttachments(except: [])
            return
        }
        let result = layout(for: bounds.size)
        let origin = drawingOrigin(for: result)
        let attachments: [(UIView, CGRect)]
        if !result.hasViewAttachments {
            stopObservingScrolls()
            attachments = []
        } else {
            let viewport = attachmentViewport().offsetBy(dx: -origin.x, dy: -origin.y)
            attachments = result.viewAttachments(in: viewport)
        }
        removeAttachments(except: Set(attachments.map { ObjectIdentifier($0.0) }))
        for (view, frame) in attachments where view !== self && !isDescendant(of: view) {
            if view.superview !== self { addSubview(view) }
            view.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
        }
        attachedViews = attachments.map { $0.0 }
        if let selection { positionSelection(selection) }
    }

    /// 在按住高亮文字时显示背景，移动到其他范围或松开时结束高亮。
    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard usesCustomLayout, !bounds.isEmpty,
              let point = touches.first?.location(in: self) else { return }
        let hit = interaction(at: point)
        if let highlight = hit.highlight, highlight.backgroundColor != nil || highlight.highlightedTextColor != nil {
            activeHighlight = (highlight, hit.highlightRange, hit.inToken)
            setNeedsDisplay()
        }
    }

    /// 离开原高亮范围时清除按压反馈。
    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let activeHighlight, let point = touches.first?.location(in: self) else { return }
        let hit = interaction(at: point)
        if hit.highlightRange != activeHighlight.range || hit.inToken != activeHighlight.inToken { clearHighlight() }
    }

    /// 完成触摸后清除按压反馈，独立的手势负责派发事件。
    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        clearHighlight()
    }

    /// 滚动或父视图取消触摸时结束高亮。
    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        clearHighlight()
    }

    /// 允许伸出控件边界的选区手柄以及热区扩展半径内的高亮链接接收触摸。
    open override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        if let selection, selection.point(inside: convert(point, to: selection), with: event) {
            return true
        }
        guard usesCustomLayout, !bounds.isEmpty, highlightTouchExtensionRadius > 0,
              bounds.insetBy(dx: -highlightTouchExtensionRadius, dy: -highlightTouchExtensionRadius).contains(point) else {
            return false
        }
        let hit = interaction(at: point)
        guard hit.highlightRange.location != NSNotFound else { return false }
        return hit.highlight?.tapAction != nil || hit.highlight?.longPressAction != nil
            || highlightTapAction != nil || highlightLongPressAction != nil
    }

    /// 让普通文字和链接之外的空白透传给下层控件，保留附件子视图、宿主手势以及确实可执行的标签操作。
    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        guard target === self else { return target }
        if selection != nil || (isSelectable && characterIndex(at: point) != NSNotFound) { return self }
        if textTapAction != nil || textLongPressAction != nil || (allowsCopy && !copyableText.isEmpty) { return self }
        if gestureRecognizers?.contains(where: {
            $0 !== actionTapGesture && $0 !== actionPressGesture && $0.isEnabled
        }) == true { return self }
        guard usesCustomLayout else { return nil }
        let hit = interaction(at: point)
        guard hit.highlightRange.location != NSNotFound else { return nil }
        return hit.highlight?.tapAction != nil || hit.highlight?.longPressAction != nil
            || highlightTapAction != nil || highlightLongPressAction != nil ? self : nil
    }

    /// 无匹配回调时让位给父级手势，空白只允许明确的整标签操作。
    open override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === actionTapGesture || gestureRecognizer === actionPressGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if gestureRecognizer === actionTapGesture, selection != nil { return true }
        if gestureRecognizer === actionPressGesture, isSelectable, characterIndex(at: gestureRecognizer.location(in: self)) != NSNotFound { return true }
        if gestureRecognizer is UILongPressGestureRecognizer, allowsCopy, !copyableText.isEmpty { return true }
        guard usesCustomLayout, !bounds.isEmpty else { return false }
        let hit = interaction(at: gestureRecognizer.location(in: self))
        if gestureRecognizer is UILongPressGestureRecognizer {
            return hit.highlight?.longPressAction != nil
                || (hit.highlightRange.location != NSNotFound && highlightLongPressAction != nil)
                || textLongPressAction != nil
        }
        return hit.highlight?.tapAction != nil
            || (hit.highlightRange.location != NSNotFound && highlightTapAction != nil)
            || textTapAction != nil
    }

    /// 判断当前内容是否需要同一份可查询、可复用的布局。
    private var usesCustomLayout: Bool {
        isSelectable || textLayout != nil || requiresAttributedLayout || textVerticalAlignment != .center
            || truncationToken != nil || !exclusionPaths.isEmpty || fixedLineHeight > 0
            || debugOptions != nil || TextForgeDebugOptions.shared != nil
            || characterSpacing != 0 || lineSpacing != 0 || paragraphSpacing != 0
            || textTapAction != nil || textLongPressAction != nil || highlightTapAction != nil || highlightLongPressAction != nil
    }

    /// 显式布局保留调用方指定的尺寸。派生布局要求同宽同限行，缩短容器时原字形区域必须仍能放下。
    /// measuring 为 true 表示结果只用于测量尺寸：与系统标签一样，多行文本测量时不缩字，
    /// 缩字只发生在按实际边界绘制时；单行沿用按给定宽度缩小后的尺寸。
    private func layout(for size: CGSize, maximumNumberOfRows: Int? = nil, measuring: Bool = false) -> TextForgeLayout {
        if let textLayout = explicitTextLayout {
            if textLayout.matchesAppearance(traitCollection) { return textLayout }
            if let rebuilt = cachedLayouts.first, rebuilt.matchesAppearance(traitCollection) { return rebuilt }
            let rebuilt = TextForgeLayout(container: textLayout.container, attributedText: textLayout.attributedText,
                                         fallbackTraits: traitCollection)
            cachedLayouts = [rebuilt]
            return rebuilt
        }
        let rows = max(0, maximumNumberOfRows ?? numberOfLines)
        let scale = adjustsFontSizeToFitWidth && !(measuring && rows != 1) ? minimumScaleFactor : 1
        let fits: (TextForgeLayout) -> Bool = { result in
            result.size.width == size.width && result.maximumNumberOfRows == rows
                && result.container.minimumScaleFactor == scale && result.fitsHeight(size.height)
        }
        if let preparedTextLayout, fits(preparedTextLayout), preparedTextLayout.matchesAppearance(traitCollection) {
            return preparedTextLayout
        }
        if let cached = cachedLayouts.first(where: fits) { return cached }
        let original = super.attributedText ?? NSAttributedString(string: super.text ?? "")
        let previous = previousLayouts.firstIndex { $0.box.size.width == size.width }.map { previousLayouts.remove(at: $0) }
        let result = TextForgeLayout(container: makeContainer(size: size, rows: rows, minimumScale: scale),
                                     attributedText: styledText(original), fallbackTraits: nil, reusing: previous)
        if rows == 0, !result.isTruncated { result.captureAttachmentMetrics() }
        if cachedLayouts.count == 2 { cachedLayouts.removeLast() }
        cachedLayouts.insert(result, at: 0)
        return result
    }

    /// 用控件当前的内边距、换行、截断标记、排除路径和链接外观组装一次排版的容器。
    /// minimumScale 为 nil 时按绘制的口径取缩字下限。
    private func makeContainer(size: CGSize, rows: Int, minimumScale: CGFloat? = nil) -> TextForgeContainer {
        let container = TextForgeContainer(size: size, insets: contentInsets)
        container.maximumNumberOfRows = rows
        container.lineBreakMode = defaultLineBreakMode
        container.minimumScaleFactor = minimumScale ?? (adjustsFontSizeToFitWidth ? minimumScaleFactor : 1)
        container.fixedLineHeight = fixedLineHeight
        container.truncationToken = truncationToken
        container.exclusionPaths = exclusionPaths
        if hasExplicitLinkStyle { container.linkTextAttributes = linkTextAttributes }
        return container
    }

    /// 保留输入的局部样式，补齐控件默认值，并应用控件级间距。
    private func styledText(_ original: NSAttributedString) -> NSAttributedString {
        let prepared = NSMutableAttributedString(attributedString: original)
        let range = NSRange(location: 0, length: original.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = defaultTextAlignment
        if defaultLineBreakMode == .byCharWrapping { paragraph.lineBreakMode = .byCharWrapping }
        let defaults: [(NSAttributedString.Key, Any?)] = [
            (.font, defaultFont ?? font),
            (.foregroundColor, defaultTextColor ?? textColor),
            (.paragraphStyle, paragraph)
        ]
        // 按单个属性的连续区间补值；仅颜色频繁变化的长段落只需设置一次段落样式。
        for (key, value) in defaults {
            guard let value else { continue }
            original.enumerateAttribute(key, in: range) { existing, part, _ in
                if existing == nil {
                    prepared.addAttribute(key, value: value, range: part)
                } else if key == .paragraphStyle {
                    original.enumerateAttribute(TextForgeTypography.synthesizedParagraphStyle, in: part) { marker, segment, _ in
                        if marker != nil, let style = (existing as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                            style.alignment = defaultTextAlignment
                            if defaultLineBreakMode == .byCharWrapping { style.lineBreakMode = .byCharWrapping }
                            prepared.addAttribute(key, value: style.copy(), range: segment)
                        } else if let mutable = existing as? NSMutableParagraphStyle {
                            prepared.addAttribute(key, value: mutable.copy(), range: segment)
                        }
                    }
                }
            }
        }
        return TextForgeTypography.styledText(
            prepared,
            characterSpacing: characterSpacing == 0 ? nil : NSNumber(value: Double(characterSpacing)),
            lineSpacing: lineSpacing == 0 ? nil : NSNumber(value: Double(lineSpacing)),
            paragraphSpacing: paragraphSpacing == 0 ? nil : NSNumber(value: Double(paragraphSpacing))
        )
    }

    /// 相同原点用于绘制、附件和命中测试，纵向空余空间按配置分配。
    private func drawingOrigin(for result: TextForgeLayout) -> CGPoint {
        let remaining = max(0, bounds.height - result.textBoundingSize.height)
        let offset: CGFloat
        switch textVerticalAlignment {
        case .top: offset = 0
        case .center: offset = remaining / 2
        case .bottom: offset = remaining
        }
        return CGPoint(x: bounds.minX + result.insets.left, y: bounds.minY + result.insets.top + offset)
    }

    /// 分别计算整标签操作的字素范围和高亮操作的链接范围。未命中时范围为 NSNotFound。
    /// 没有直接点中高亮时，在触摸热区扩展半径内改用最近的高亮。
    private func interaction(at point: CGPoint) -> TextForgeInteraction {
        let result = layout(for: bounds.size)
        let origin = drawingOrigin(for: result)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var found = TextForgeInteraction(text: result.attributedText)
        if let hit = result.hit(at: local) {
            found = interaction(atCharacter: hit.index, inToken: hit.inToken, in: result)
        }
        guard found.highlightRange.location == NSNotFound, highlightTouchExtensionRadius > 0,
              let nearest = nearestHighlight(to: local, in: result) else { return found }
        // 整标签回调仍按手指实际落点报告字符，只有两者同属正文或同属截断标记时才能合并。
        if found.characterRange.location != NSNotFound, found.inToken != nearest.inToken { return found }
        found.text = nearest.text
        found.inToken = nearest.inToken
        found.highlight = nearest.highlight
        found.highlightRange = nearest.highlightRange
        found.highlightRect = nearest.highlightRect
        return found
    }

    /// 在可见的高亮和链接中找出与触摸点距离不超过扩展半径且最近的一个，坐标以排版区左上角为原点。
    private func nearestHighlight(to point: CGPoint, in result: TextForgeLayout) -> TextForgeInteraction? {
        var best: (distance: CGFloat, index: Int, inToken: Bool)?
        var scopes: [(text: NSAttributedString, range: NSRange, inToken: Bool)] = []
        if let visible = result.visibleCharacterRange { scopes.append((result.attributedText, visible, false)) }
        if result.showsTruncationToken, let token = result.truncationToken {
            scopes.append((token, NSRange(location: 0, length: token.length), true))
        }
        for scope in scopes {
            scope.text.enumerateAttributes(in: scope.range) { attributes, range, _ in
                guard attributes[TextForgeHighlight.attributeName] != nil || attributes[.link] != nil,
                      let index = result.firstVisibleCharacter(in: range, inToken: scope.inToken) else { return }
                for rect in result.runRects(for: range, inToken: scope.inToken) {
                    let distance = hypot(
                        max(rect.minX - point.x, 0, point.x - rect.maxX),
                        max(rect.minY - point.y, 0, point.y - rect.maxY)
                    )
                    if distance <= highlightTouchExtensionRadius, distance < best?.distance ?? .greatestFiniteMagnitude {
                        best = (distance, index, scope.inToken)
                    }
                }
            }
        }
        return best.map { interaction(atCharacter: $0.index, inToken: $0.inToken, in: result) }
    }

    /// 将定位到的 UTF-16 字符映射到字素和完整高亮区间，供触摸及辅助操作使用。
    /// inToken 为 true 时下标和返回的范围都相对截断标记，回调收到的富文本也是截断标记。
    private func interaction(atCharacter index: Int, inToken: Bool, in result: TextForgeLayout) -> TextForgeInteraction {
        let text = inToken ? (result.truncationToken ?? NSAttributedString()) : result.attributedText
        guard index >= 0, index < text.length else { return TextForgeInteraction(text: text, inToken: inToken) }
        let origin = drawingOrigin(for: result)
        let characterRange = (text.string as NSString).rangeOfComposedCharacterSequence(at: index)
        var resultHit = TextForgeInteraction(
            text: text, inToken: inToken, characterRange: characterRange,
            characterRect: result.containerRect(for: characterRange, inToken: inToken).offsetBy(dx: origin.x, dy: origin.y)
        )
        let full = NSRange(location: 0, length: text.length)
        var range = NSRange(location: index, length: 0)
        let highlight = text.attribute(TextForgeHighlight.attributeName, at: index, longestEffectiveRange: &range, in: full) as? TextForgeHighlight
        if highlight != nil || text.attribute(.link, at: index, longestEffectiveRange: &range, in: full) != nil {
            resultHit.highlight = highlight
            resultHit.highlightRange = range
            resultHit.highlightRect = result.containerRect(for: range, inToken: inToken).offsetBy(dx: origin.x, dy: origin.y)
        }
        return resultHit
    }

    /// 手柄的拖动由选区自身识别，父标签保留普通文字、链接与截断标记的原有手势。
    /// 窗口上的识别器只接收落在标签及其子视图之外的触摸。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === outsideTapGesture { return touch.view.map { !$0.isDescendant(of: self) } ?? true }
        return touch.view !== selection || selection == nil
    }

    /// 窗口上的识别器只做旁观，与页面上任何手势同时识别；标签自己的点击和长按保持互斥。
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === outsideTapGesture || otherGestureRecognizer === outsideTapGesture
    }

    /// 为长按和短按分别配置 UIKit 手势，长按成立时避免重复短按。
    private func configureInteraction() {
        isUserInteractionEnabled = true
        contentMode = .redraw
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        actionTapGesture = tap
        actionPressGesture = press
        tap.delegate = self
        press.delegate = self
        tap.require(toFail: press)
        addGestureRecognizer(tap)
        addGestureRecognizer(press)
    }

    /// 先派发整标签点击，再派发对应高亮；同一高亮优先使用局部回调。
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let hit = interaction(at: gesture.location(in: self))
        clearSelection()
        _ = dispatchTap(hit)
    }

    /// 派发整段和高亮回调，返回是否确实执行操作。
    private func dispatchTap(_ hit: TextForgeInteraction) -> Bool {
        let genericAction = textTapAction
        let highlightAction = hit.highlight?.tapAction ?? highlightTapAction
        genericAction?(self, hit.text, hit.characterRange, hit.characterRect)
        if hit.highlightRange.location != NSNotFound {
            highlightAction?(self, hit.text, hit.highlightRange, hit.highlightRect)
            if highlightAction != nil { return true }
        }
        return genericAction != nil
    }

    /// 显式长按回调优先。普通正文长按选词，持续拖动扩选，松手才弹菜单；关闭选词时沿用原来的全文复制。
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if usesCustomLayout, !bounds.isEmpty {
                let hit = interaction(at: point)
                let action = hit.highlightRange.location == NSNotFound ? nil : hit.highlight?.longPressAction ?? highlightLongPressAction
                if isSelectable, textLongPressAction == nil, action == nil, selectWord(at: point) {
                    extendingWord = true
                    return
                }
                textLongPressAction?(self, hit.text, hit.characterRange, hit.characterRect)
                action?(self, hit.text, hit.highlightRange, hit.highlightRect)
            }
            if allowsCopy { presentCopyMenu(at: point) }
        case .changed:
            if extendingWord, let selection { selection.extendWord(to: gesture.location(in: selection)) }
        case .ended:
            if extendingWord { extendingWord = false; showSelectionMenu() }
        case .cancelled, .failed:
            if extendingWord { clearSelection() }
        default: break
        }
    }

    /// 旧系统的菜单收起后只通知一次，随即停止监听，避免响应其他控件的菜单。
    @objc private func copyMenuDidHide() {
        NotificationCenter.default.removeObserver(self, name: UIMenuController.didHideMenuNotification, object: nil)
        copyMenuVisibilityHandler?(false)
    }

    /// 选区优先，全文复制仍从原文导出，省略号和展示标记不会进入剪贴板。
    private var copyableText: String {
        if let selectedText { return selectedText }
        if let attributedText { return TextForgeAttachment.copyText(for: attributedText) }
        return (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// 在触摸点弹出系统拷贝菜单。只有控件在窗口内、有原文且拿到第一响应者时才尝试呈现。
    /// iOS 16 及以上使用 UIEditMenuInteraction，更早的系统使用 UIMenuController。
    private func presentCopyMenu(at point: CGPoint) {
        guard window != nil, !copyableText.isEmpty, becomeFirstResponder() else { return }
        if #available(iOS 16.0, *) {
            let existing = interactions.compactMap { $0 as? UIEditMenuInteraction }.first
            let menu = existing ?? UIEditMenuInteraction(delegate: self)
            if existing == nil { addInteraction(menu) }
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        } else {
            let center = NotificationCenter.default
            center.removeObserver(self, name: UIMenuController.didHideMenuNotification, object: nil)
            center.addObserver(
                self, selector: #selector(copyMenuDidHide), name: UIMenuController.didHideMenuNotification, object: nil
            )
            copyMenuVisibilityHandler?(true)
            UIMenuController.shared.showMenu(from: self, rect: selection.map { $0.convert($0.menuRect, to: self) } ?? bounds)
        }
    }

    /// 扫描富文本中的自有高亮、圆角背景、链接和视图附件，普通样式仍沿用原生 UILabel。
    private func refreshAttributeUsage() {
        requiresAttributedLayout = false
        if let attributedText = super.attributedText {
            attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length)) { attributes, _, stop in
                if attributes[TextForgeHighlight.attributeName] != nil || attributes[.link] != nil
                    || attributes[TextForgeBackground.attributeName] != nil
                    || attributes[TextForgeDrawing.attributeName] != nil
                    || attributes[TextForgeTypography.synthesizedParagraphStyle] != nil
                    || attributes[.attachment] is TextForgeViewAttachment {
                    requiresAttributedLayout = true
                    stop.pointee = true
                }
            }
        }
        invalidateTextLayout()
    }

    /// 取消当前请求并同时清理关联宽度，防止已取消的结果在复用后交付。
    private func cancelPendingLayout() {
        pendingLayout?.cancel()
        pendingLayout = nil
        pendingLayoutWidth = nil
    }

    /// 样式、内容或布局变化时丢弃派生结果、释放旧附件并重新测量。
    private func invalidateTextLayout() {
        clearSelection()
        cancelPendingLayout()
        preparedTextLayout = nil
        previousLayouts.removeAll(keepingCapacity: true)
        cachedLayouts.removeAll(keepingCapacity: true)
        linkElements.removeAll()
        clearHighlight()
        stopObservingScrolls()
        removeAttachments(except: [])
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// 清理仍在当前标签中的附件，避免移走已经由其他标签接管的视图。
    private func removeAttachments(except retained: Set<ObjectIdentifier>) {
        for view in attachedViews where view.superview === self && !retained.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        attachedViews.removeAll()
    }

    /// 结束按压反馈并请求重绘，空状态保持原样。
    private func clearHighlight() {
        guard activeHighlight != nil else { return }
        activeHighlight = nil
        setNeedsDisplay()
    }

    /// 扣除物理方向的内边距，将不足的宽高限制为零。
    private func insetTextRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + contentInsets.left,
            y: rect.minY + contentInsets.top,
            width: max(0, rect.width - contentInsets.left - contentInsets.right),
            height: max(0, rect.height - contentInsets.top - contentInsets.bottom)
        )
    }
}

private struct TextForgeInteraction {
    /// 回调收到的富文本：正文，或命中截断标记时的截断标记。
    var text: NSAttributedString
    var inToken = false
    var characterRange = NSRange(location: NSNotFound, length: 0)
    var characterRect = CGRect.null
    var highlight: TextForgeHighlight?
    var highlightRange = NSRange(location: NSNotFound, length: 0)
    var highlightRect = CGRect.null
}

@available(iOS 16.0, *)
extension TextForgeLabel: UIEditMenuInteractionDelegate {
    /// UIKit 在主线程询问菜单位置。协议签名未声明隔离，此处显式在主执行器读取文字区域。
    nonisolated public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        MainActor.assumeIsolated {
            if let selection { return selection.convert(selection.menuRect, to: self) }
            guard let result = displayedTextLayout else { return bounds }
            let origin = drawingOrigin(for: result)
            return result.textBoundingRect.offsetBy(dx: origin.x - result.insets.left, dy: origin.y - result.insets.top)
        }
    }

    /// 有选区时把宿主的自定义项接在系统操作之后；没有选区或没有自定义项时用系统默认菜单。
    nonisolated public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        MainActor.assumeIsolated {
            guard selection != nil, !selectionActions.isEmpty else { return nil }
            let custom = selectionActions.map { item in
                UIAction(title: item.title, image: item.image) { [weak self] _ in
                    // 菜单弹出后选区可能已被清除或改变，按点击时的选区回调。
                    guard let self, let text = self.selectedText else { return }
                    item.handler(self, text, self.selectedRange)
                }
            }
            return UIMenu(children: suggestedActions + custom)
        }
    }

    /// UIKit 开始在主线程呈现拷贝菜单时，回调宿主更新选中样式。
    nonisolated public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        MainActor.assumeIsolated { copyMenuVisibilityHandler?(true) }
    }

    /// UIKit 在主线程结束收起动画后再通知宿主恢复底色。
    nonisolated public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        MainActor.assumeIsolated {
            animator.addCompletion { [weak self] in self?.copyMenuVisibilityHandler?(false) }
        }
    }
}

/// "链接"转子里的一个目标。不在标签的无障碍元素树里，位置和激活都回到标签按当前布局计算。
private final class TextForgeLinkElement: UIAccessibilityElement {
    private weak var label: TextForgeLabel?
    private(set) weak var layout: TextForgeLayout?
    private let index: Int
    let range: NSRange
    let inToken: Bool

    init(label: TextForgeLabel, layout: TextForgeLayout, index: Int, range: NSRange, inToken: Bool) {
        self.label = label
        self.layout = layout
        self.index = index
        self.range = range
        self.inToken = inToken
        super.init(accessibilityContainer: label)
    }

    /// 链接在屏幕上的外接矩形；标签已换文或离开时为空。
    override var accessibilityFrame: CGRect {
        get {
            guard let label, let layout, let link = label.linkInteraction(index: index, inToken: inToken, in: layout) else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(link.rect, in: label)
        }
        set {}
    }

    /// 双击激活时执行与点击该链接相同的回调，返回是否确实执行了操作。
    override func accessibilityActivate() -> Bool {
        guard let label, let layout, let link = label.linkInteraction(index: index, inToken: inToken, in: layout) else { return false }
        return link.activate()
    }
}
