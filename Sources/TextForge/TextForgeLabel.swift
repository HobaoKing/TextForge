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

    @objc public var textTapAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var textLongPressAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var highlightTapAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }
    @objc public var highlightLongPressAction: TextForgeTextAction? { didSet { invalidateTextLayout() } }

    private var cachedLayouts: [TextForgeLayout] = []
    private var explicitTextLayout: TextForgeLayout?
    private var preparedTextLayout: TextForgeLayout?
    private var pendingLayout: TextForgeLayoutTask?
    private var pendingLayoutWidth: CGFloat?
    private var requiresAttributedLayout = false
    private var attachedViews: [UIView] = []
    private var activeHighlight: (TextForgeHighlight, NSRange)?
    private weak var actionTapGesture: UITapGestureRecognizer?
    private weak var actionPressGesture: UILongPressGestureRecognizer?
    private var customAccessibilityLabel: String?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
        refreshAttributeUsage()
    }

    /// 销毁标签时撤销排队或等待回到主线程的工作。
    deinit {
        pendingLayout?.cancel()
    }

    /// 读取当前显示的文本。赋值替换内部异步内容，显式布局继续优先显示。
    open override var text: String? {
        get { textLayout?.attributedText.string ?? super.text }
        set {
            preparedTextLayout = nil
            super.text = newValue
            refreshAttributeUsage()
        }
    }

    /// 读取当前显示的富文本。赋值替换内部异步内容，显式布局继续优先显示。
    open override var attributedText: NSAttributedString? {
        get { textLayout?.attributedText ?? super.attributedText }
        set { storeAttributedText(newValue) }
    }
    open override var font: UIFont! { didSet { if font != oldValue { invalidateTextLayout() } } }
    open override var textColor: UIColor! { didSet { if textColor != oldValue { invalidateTextLayout() } } }
    open override var textAlignment: NSTextAlignment { didSet { if textAlignment != oldValue { invalidateTextLayout() } } }
    open override var lineBreakMode: NSLineBreakMode { didSet { if lineBreakMode != oldValue { invalidateTextLayout() } } }
    open override var numberOfLines: Int { didSet { if numberOfLines != oldValue { invalidateTextLayout() } } }
    open override var preferredMaxLayoutWidth: CGFloat {
        didSet { if preferredMaxLayoutWidth != oldValue { invalidateTextLayout() } }
    }

    /// 保留宿主显式设置的朗读文案，否则跟随当前文本并去掉附件占位字符。
    open override var accessibilityLabel: String? {
        get {
            if let customAccessibilityLabel { return customAccessibilityLabel }
            return text?.replacingOccurrences(of: "\u{FFFC}", with: "") ?? super.accessibilityLabel
        }
        set {
            customAccessibilityLabel = newValue
            super.accessibilityLabel = newValue
        }
    }

    /// 将可见且可点击的高亮附加为 VoiceOver 操作，保留宿主原有自定义操作。
    open override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let inherited = super.accessibilityCustomActions ?? []
            guard requiresAttributedLayout || textLayout != nil, !bounds.isEmpty else {
                return inherited.isEmpty ? nil : inherited
            }
            let result = layout(for: bounds.size)
            var actions = inherited
            var seen = Set<NSRange>()
            let visible = result.visibleCharacterRange
            if let visible {
                result.attributedText.enumerateAttributes(in: visible) { attributes, range, _ in
                    guard (attributes[TextForgeHighlight.attribute] != nil || attributes[.link] != nil),
                          let index = result.visibleCharacter(atOrAfter: range.location, in: range) else { return }
                    let hit = interaction(atCharacter: index, in: result)
                    guard hit.highlight?.tapAction != nil || highlightTapAction != nil || textTapAction != nil,
                          seen.insert(hit.highlightRange).inserted else { return }
                    let name = (hit.text.string as NSString).substring(with: hit.highlightRange)
                    actions.append(UIAccessibilityCustomAction(name: name) { [weak self, weak result] _ in
                        guard let self, let result, !self.bounds.isEmpty,
                              self.layout(for: self.bounds.size) === result else { return false }
                        return self.dispatchTap(self.interaction(atCharacter: index, in: result))
                    })
                }
            }
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
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
            attributedText: styledText(source), size: size, insets: contentInsets,
            maximumNumberOfRows: numberOfLines, lineBreakMode: lineBreakMode,
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
            if self.bounds.width == 0 || self.bounds.width == size.width {
                self.preparedTextLayout = result
            }
            completion?()
        }
        pendingLayout = task
        pendingLayoutWidth = size.width
        return task
    }

    /// 刷新 UILabel 的基础文本并清理衍生布局。内部交付不触发子类公开属性的赋值逻辑。
    private func storeAttributedText(_ text: NSAttributedString?) {
        preparedTextLayout = nil
        super.attributedText = text
        refreshAttributeUsage()
    }

    /// 首次获得宽度时也校验待交付结果。已交付的异步文本保留原文，宽度变化后重新排版。
    open override var bounds: CGRect {
        didSet {
            guard oldValue.width != bounds.width else { return }
            if let pendingLayoutWidth, bounds.width != pendingLayoutWidth {
                cancelPendingLayout()
            }
            if let preparedTextLayout, bounds.width != preparedTextLayout.size.width {
                invalidateTextLayout()
            }
        }
    }

    /// 外观变化后丢弃派生布局，后台任务交付的旧配色也会在此标签刷新时重建。
    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            cachedLayouts.removeAll(keepingCapacity: true)
            setNeedsDisplay()
        }
    }

    /// 为富文本使用当前可用宽度测量，普通标签保持系统固有尺寸算法。
    open override var intrinsicContentSize: CGSize {
        if let textLayout { return textLayout.textBoundingSize }
        guard usesCustomLayout else { return super.intrinsicContentSize }
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : (
            numberOfLines != 1 && bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude
        )
        return layout(for: CGSize(width: width, height: .greatestFiniteMagnitude)).textBoundingSize
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
        return layout(for: CGSize(
            width: size.width > 0 ? size.width : .greatestFiniteMagnitude,
            height: size.height > 0 ? size.height : .greatestFiniteMagnitude
        )).textBoundingSize
    }

    /// 在扣除内边距后的可用宽度测量文本，并把内边距计入返回的文本区域。
    open override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        if usesCustomLayout {
            let result = layout(for: bounds.size, maximumNumberOfRows: numberOfLines)
            return CGRect(origin: bounds.origin, size: result.textBoundingSize)
        }
        let contentRect = insetTextRect(bounds)
        let textRect = super.textRect(forBounds: contentRect, limitedToNumberOfLines: numberOfLines)
        return CGRect(
            x: textRect.origin.x - contentInsets.left,
            y: textRect.origin.y - contentInsets.top,
            width: textRect.width + contentInsets.left + contentInsets.right,
            height: textRect.height + contentInsets.top + contentInsets.bottom
        )
    }

    /// 在与测量一致的内容区域绘制，宽度或高度耗尽时跳过绘制。
    open override func drawText(in rect: CGRect) {
        if usesCustomLayout {
            guard !bounds.isEmpty else { return }
            let result = layout(for: bounds.size)
            result.draw(
                at: drawingOrigin(for: result),
                activeRange: activeHighlight?.1,
                activeBackground: activeHighlight?.0.backgroundColor,
                activeForeground: activeHighlight?.0.highlightedTextColor
            )
            return
        }
        let contentRect = insetTextRect(rect)
        guard !contentRect.isEmpty else { return }
        super.drawText(in: contentRect)
    }

    /// 可见附件随当前布局挂载，重用标签时清除已经离开布局的视图。
    open override func layoutSubviews() {
        super.layoutSubviews()
        guard usesCustomLayout, !bounds.isEmpty else {
            removeAttachments(except: [])
            return
        }
        let result = layout(for: bounds.size)
        let origin = drawingOrigin(for: result)
        let attachments = result.viewAttachments()
        removeAttachments(except: Set(attachments.map { ObjectIdentifier($0.0) }))
        for (view, frame) in attachments where view !== self && !isDescendant(of: view) {
            if view.superview !== self { addSubview(view) }
            view.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
        }
        attachedViews = attachments.map { $0.0 }
    }

    /// 在按住高亮文字时显示背景，移动到其他范围或松开时结束高亮。
    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard textLayout != nil || requiresAttributedLayout,
              let point = touches.first?.location(in: self) else { return }
        let hit = interaction(at: point)
        if let highlight = hit.highlight, highlight.backgroundColor != nil || highlight.highlightedTextColor != nil {
            activeHighlight = (highlight, hit.highlightRange)
            setNeedsDisplay()
        }
    }

    /// 离开原高亮范围时清除按压反馈。
    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let activeHighlight, let point = touches.first?.location(in: self) else { return }
        if interaction(at: point).highlightRange != activeHighlight.1 { clearHighlight() }
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

    /// 无匹配回调时让位给父级手势，空白只允许明确的整标签操作。
    open override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === actionTapGesture || gestureRecognizer === actionPressGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard usesCustomLayout else { return false }
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
        textLayout != nil || requiresAttributedLayout || textVerticalAlignment != .center
            || characterSpacing != 0 || lineSpacing != 0 || paragraphSpacing != 0
            || textTapAction != nil || textLongPressAction != nil || highlightTapAction != nil || highlightLongPressAction != nil
    }

    /// 显式布局保留调用方指定的尺寸。派生布局要求同宽同限行，缩短容器时原字形区域必须仍能放下。
    private func layout(for size: CGSize, maximumNumberOfRows: Int? = nil) -> TextForgeLayout {
        if let textLayout = explicitTextLayout {
            if textLayout.matchesAppearance(traitCollection) { return textLayout }
            if let rebuilt = cachedLayouts.first { return rebuilt }
            let rebuilt = TextForgeLayout(
                attributedText: textLayout.attributedText, size: textLayout.size, insets: textLayout.insets,
                maximumNumberOfRows: textLayout.maximumNumberOfRows, lineBreakMode: textLayout.lineBreakMode
            )
            cachedLayouts = [rebuilt]
            return rebuilt
        }
        let rows = max(0, maximumNumberOfRows ?? numberOfLines)
        let fits: (TextForgeLayout) -> Bool = { result in
            result.size.width == size.width && result.maximumNumberOfRows == rows
                && (result.size.height == size.height
                    || (result.size.height > size.height && result.textBoundingSize.height <= size.height))
        }
        if let preparedTextLayout, fits(preparedTextLayout), preparedTextLayout.matchesAppearance(traitCollection) {
            return preparedTextLayout
        }
        if let cached = cachedLayouts.first(where: fits) { return cached }
        let original = super.attributedText ?? NSAttributedString(string: super.text ?? "")
        let result = TextForgeLayout(
            attributedText: styledText(original), size: size, insets: contentInsets,
            maximumNumberOfRows: rows, lineBreakMode: lineBreakMode
        )
        if cachedLayouts.count == 2 { cachedLayouts.removeLast() }
        cachedLayouts.insert(result, at: 0)
        return result
    }

    /// 保留输入的局部样式，补齐控件默认值，并应用控件级间距。
    private func styledText(_ original: NSAttributedString) -> NSAttributedString {
        let prepared = NSMutableAttributedString(attributedString: original)
        let range = NSRange(location: 0, length: original.length)
        original.enumerateAttributes(in: range) { attributes, segment, _ in
            if attributes[.font] == nil, let font { prepared.addAttribute(.font, value: font, range: segment) }
            if attributes[.foregroundColor] == nil, let textColor {
                prepared.addAttribute(.foregroundColor, value: textColor, range: segment)
            }
            if attributes[.paragraphStyle] == nil {
                let style = NSMutableParagraphStyle()
                style.alignment = textAlignment
                prepared.addAttribute(.paragraphStyle, value: style, range: segment)
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
    private func interaction(at point: CGPoint) -> TextForgeInteraction {
        let result = layout(for: bounds.size)
        let origin = drawingOrigin(for: result)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let index = result.character(at: local) else {
            return TextForgeInteraction(text: result.attributedText)
        }
        return interaction(atCharacter: index, in: result)
    }

    /// 将定位到的 UTF-16 字符映射到字素和完整高亮区间，供触摸及辅助操作使用。
    private func interaction(atCharacter index: Int, in result: TextForgeLayout) -> TextForgeInteraction {
        let text = result.attributedText
        let origin = drawingOrigin(for: result)
        let characterRange = (text.string as NSString).rangeOfComposedCharacterSequence(at: index)
        var resultHit = TextForgeInteraction(
            text: text, characterRange: characterRange,
            characterRect: result.rect(for: characterRange).offsetBy(dx: origin.x, dy: origin.y)
        )
        let full = NSRange(location: 0, length: text.length)
        var range = NSRange(location: index, length: 0)
        let highlight = text.attribute(TextForgeHighlight.attribute, at: index, longestEffectiveRange: &range, in: full) as? TextForgeHighlight
        if highlight != nil || text.attribute(.link, at: index, longestEffectiveRange: &range, in: full) != nil {
            resultHit.highlight = highlight
            resultHit.highlightRange = range
            resultHit.highlightRect = result.rect(for: range).offsetBy(dx: origin.x, dy: origin.y)
        }
        return resultHit
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
        _ = dispatchTap(interaction(at: gesture.location(in: self)))
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

    /// 只在长按进入识别状态时派发一次，避免移动和结束重复回调。
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let hit = interaction(at: gesture.location(in: self))
        let highlightAction = hit.highlight?.longPressAction ?? highlightLongPressAction
        textLongPressAction?(self, hit.text, hit.characterRange, hit.characterRect)
        if hit.highlightRange.location != NSNotFound {
            highlightAction?(self, hit.text, hit.highlightRange, hit.highlightRect)
        }
    }

    /// 扫描富文本中的自有高亮和视图附件，普通样式仍沿用原生 UILabel。
    private func refreshAttributeUsage() {
        requiresAttributedLayout = false
        if let attributedText = super.attributedText {
            attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length)) { attributes, _, stop in
                if attributes[TextForgeHighlight.attribute] != nil || attributes[.link] != nil
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
        cancelPendingLayout()
        preparedTextLayout = nil
        cachedLayouts.removeAll(keepingCapacity: true)
        clearHighlight()
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
    let text: NSAttributedString
    var characterRange = NSRange(location: NSNotFound, length: 0)
    var characterRect = CGRect.null
    var highlight: TextForgeHighlight?
    var highlightRange = NSRange(location: NSNotFound, length: 0)
    var highlightRect = CGRect.null
}
