import UIKit

/// 在原生 UITextView 上补齐占位文案和已提交文本的变化回调。
/// 子类覆盖文本、布局或组字方法时应调用 super，以同步占位状态和编辑回调的比较基线。
@objc(TextForgeTextView)
open class TextForgeTextView: UITextView {
    /// 文本为空时显示的占位文案，nil 或空串表示隐藏。
    @objc public var placeholder: String? {
        didSet { updatePlaceholderVisibility() }
    }

    @objc public var placeholderText: String? {
        get { placeholder }
        set { placeholder = newValue }
    }

    /// 自定义占位字体，nil 跟随编辑字体。
    @objc public var placeholderFont: UIFont? { didSet { setNeedsLayout() } }

    /// 占位文字颜色，默认跟随系统浅色和深色外观。
    @objc public var placeholderColor: UIColor = .placeholderText {
        didSet { setNeedsLayout() }
    }

    @objc public var placeholderTextColor: UIColor? {
        get { placeholderColor }
        set { placeholderColor = newValue ?? .placeholderText }
    }

    /// 提供富文本占位，nil 恢复纯文本。显示内容与调用方后续的可变对象编辑隔离。
    @objc public var placeholderAttributedText: NSAttributedString? {
        get { attributedPlaceholder }
        set {
            attributedPlaceholder = newValue.map { NSAttributedString(attributedString: $0) }
            updatePlaceholderVisibility()
        }
    }

    /// 仅在用户编辑后的已提交文本变化时，在主线程回调当前全文。
    @objc public var onTextChange: ((String) -> Void)?

    /// 用户输入的字数上限，按 NSString 的 UTF-16 长度计，0 表示不限。输入、粘贴或候选字上屏后超出时，
    /// 截掉本次新增内容里放不下的尾部，截断点落在完整字素上，不会留下半个表情。拼音组字期间不截断。
    /// 正文原本就超过上限时（程序赋值），用户不能再加长，但可以删除和缩短。发生截断时清空撤销记录。
    /// 只约束用户编辑：直接给 `text`、`attributedText` 赋值不受影响，修改上限也不会裁剪已有正文。
    @objc public var maximumTextLength = 0

    /// 用户输入因 `maximumTextLength` 被截断后在主线程回调，可用来提示"最多输入 N 个字"。在 `onTextChange` 之后调用。
    @objc public var onTextLimitReached: (() -> Void)?

    /// 高度自适应的最少、最多行数，都为 0 时关闭（默认），输入框保持 UITextView 原有行为。
    /// 任一大于 0 时：`preferredHeight` 与 `intrinsicContentSize` 跟随内容在两者之间变化，自动布局下无需高度约束；
    /// 内容超过最多行数后开启滚动，否则关闭滚动。开启期间由输入框接管 `isScrollEnabled`。
    @objc public var minimumNumberOfLines = 0 { didSet { updatePreferredHeight() } }
    @objc public var maximumNumberOfLines = 0 { didSet { updatePreferredHeight() } }

    /// 高度自适应开启时，按当前宽度、字体和内容算出的输入框高度（含上下内边距），单位为点；关闭时为 0。
    @objc public private(set) var preferredHeight: CGFloat = 0

    /// `preferredHeight` 变化后在主线程回调新高度。用 frame 布局的宿主在这里更新输入框和输入栏的高度。
    @objc public var onPreferredHeightChange: ((CGFloat) -> Void)?

    private var isMeasuringHeight = false
    private var measuredWidth: CGFloat = -1
    /// 存储编辑进行中不能排版测量，先记下，等编辑结束或下一次布局再算。
    private var needsHeightUpdate = false
    /// 滚动开关刚切换，等高度落定后的下一次布局再把光标滚进可见区域或回到顶部。
    private var needsScrollReset = false

    /// 字体和内边距都参与行高换算，变化后重新计算高度。
    open override var font: UIFont? { didSet { updatePreferredHeight() } }
    open override var textContainerInset: UIEdgeInsets { didSet { updatePreferredHeight() } }

    /// 高度自适应开启时由内容决定高度，宽度不设固有值；关闭时沿用系统结果。
    open override var intrinsicContentSize: CGSize {
        guard minimumNumberOfLines > 0 || maximumNumberOfLines > 0 else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    /// 按当前宽度重新计算自适应高度并切换滚动开关。高度变化时刷新固有尺寸并通知宿主；尚无宽度时按单行估算。
    /// 不能在文本存储处理编辑的通知里调用：那时排版数据还没同步，测量会越界崩溃。
    private func updatePreferredHeight() {
        needsHeightUpdate = false
        guard minimumNumberOfLines > 0 || maximumNumberOfLines > 0 else {
            preferredHeight = 0
            return
        }
        guard !isMeasuringHeight else { return }
        isMeasuringHeight = true
        defer { isMeasuringHeight = false }
        let line = (font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let chrome = textContainerInset.top + textContainerInset.bottom
        measuredWidth = bounds.width
        let lower = minimumNumberOfLines > 0 ? CGFloat(minimumNumberOfLines) * line + chrome : 0
        let upper = maximumNumberOfLines > 0 ? max(lower, CGFloat(maximumNumberOfLines) * line + chrome) : .greatestFiniteMagnitude
        // 整篇测量的耗时随正文长度线性增长（几万字要几十毫秒，每次按键都会卡）。有行数上限时先看开头一段，
        // 已经明显超出就不必量全文。
        var scrolls = bounds.width > 0 && upper < .greatestFiniteMagnitude && leadingTextExceeds(upper - chrome, lineHeight: line)
        let content = scrolls ? upper
            : bounds.width > 0 ? sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height : line + chrome
        if !scrolls { scrolls = content > upper + 0.5 }
        let height = ceil(min(max(content, lower), upper))
        if isScrollEnabled != scrolls {
            isScrollEnabled = scrolls
            needsScrollReset = true
            setNeedsLayout()
        }
        guard height != preferredHeight else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
        onPreferredHeightChange?(height)
    }

    /// 把光标滚进可见区域。TextKit 2 对视口外的内容只估算高度，这里先排完全文再滚动；
    /// 每次滚动后重新布局核对，位置稳定即停，最多八次。光标在文末时直接滚到底。
    private func scrollCaretToVisible() {
        guard isScrollEnabled, let end = selectedTextRange?.end else { return }
        let atEnd = offset(from: end, to: endOfDocument) == 0
        // 只在滚动开关刚打开时走到这里（通常是一次粘贴了很多行）。先让 TextKit 2 排完全文，
        // 内容高度才是准的；这一步的耗时与那次粘贴本身同量级，之后的按键不会再触发。
        if #available(iOS 16.0, *), let manager = textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        for _ in 0..<8 {
            layoutIfNeeded()
            let visible = CGRect(origin: contentOffset, size: bounds.size)
            let bottom = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
            if atEnd {
                if abs(contentOffset.y - bottom) < 0.5 { return }
                setContentOffset(CGPoint(x: contentOffset.x, y: bottom), animated: false)
            } else {
                let caret = caretRect(for: end)
                if visible.contains(caret) { return }
                scrollRectToVisible(caret, animated: false)
            }
        }
    }

    /// 长正文的快速判断：只量开头一段，它的高度已经比 limit（不含上下内边距）多出一行以上时返回 true。
    /// 开头一段的高度不会超过全文，所以 true 一定成立；返回 false 只表示这里判断不了，调用方再量全文。
    /// 用字符串绘制的度量估算，与输入框实际排版可能差几个点，留出的一行余量用来吸收这个差别。
    private func leadingTextExceeds(_ limit: CGFloat, lineHeight: CGFloat) -> Bool {
        let sampleLength = 2048
        guard textStorage.length > sampleLength, textContainer.exclusionPaths.isEmpty else { return false }
        let end = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: sampleLength).location
        let width = bounds.width - textContainerInset.left - textContainerInset.right - 2 * textContainer.lineFragmentPadding
        guard end > 0, width > 0 else { return false }
        let sample = textStorage.attributedSubstring(from: NSRange(location: 0, length: end))
        let height = sample.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        return height > limit + lineHeight
    }

    /// 用户编辑后正文超出上限时，从本次新增内容的末尾删掉超出的部分。previous 是这次编辑之前的正文：
    /// 与当前正文比较公共前缀和后缀得到新增范围，所以输入、粘贴、替换选区、拖入都只动新增的文字，
    /// 光标落在保留内容之后。正文原本就超限（程序赋值）时以原长度为准，只挡住继续变长，删除和缩短不受影响。
    /// 经 UITextInput 删除，宿主的 UITextViewDelegate 会再收到一次 textViewDidChange，看到截断后的正文。返回是否发生了截断。
    private func enforceTextLimit(previous: String) -> Bool {
        let string = textStorage.string as NSString
        guard maximumTextLength > 0, string.length > maximumTextLength else { return false }
        let old = previous as NSString
        let allowed = max(maximumTextLength, old.length)
        guard string.length > allowed else { return false }
        // 只在超限时比较，粘贴几十万字也只是一次线性扫描。
        let current = Array((string as String).utf16)
        let before = Array(previous.utf16)
        var prefix = 0
        let shared = min(current.count, before.count)
        while prefix < shared, current[prefix] == before[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shared - prefix, current[current.count - 1 - suffix] == before[before.count - 1 - suffix] { suffix += 1 }
        let inserted = NSRange(location: prefix, length: current.count - suffix - prefix)
        let excess = min(string.length - allowed, inserted.length)
        guard excess > 0 else { return false }
        var range = NSRange(location: NSMaxRange(inserted) - excess, length: excess)
        // 起点落在字素中间时向前退到字素开头，宁可多删新增的内容也不留下半个表情；但不退进原有文字。
        let cluster = string.rangeOfComposedCharacterSequence(at: range.location).location
        let start = max(cluster, inserted.location)
        range = NSRange(location: start, length: NSMaxRange(range) - start)
        guard let from = position(from: beginningOfDocument, offset: range.location),
              let to = position(from: from, offset: range.length), let target = textRange(from: from, to: to) else { return false }
        // 这次删除是同一笔用户编辑的收尾，不单独记作一次变化，也不改比较基线。
        textAssignmentDepth += 1
        isUpdatingComposition = true
        super.replace(target, withText: "")
        isUpdatingComposition = false
        textAssignmentDepth -= 1
        observedStorageText = textStorage.string
        // 光标放在保留下来的新增内容之后。系统粘贴会在通知之后按截断前的位置再设一次选区，
        // 那个位置已经越界，光标会掉到文首；本轮结束后只纠正这一种情况，不动宿主或用户之后设的其他选区。
        let caret = NSRange(location: range.location, length: 0)
        let expected = observedStorageText
        selectedRange = caret
        if caret.location > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textStorage.string == expected, self.markedTextRange == nil,
                      self.selectedRange == NSRange(location: 0, length: 0) else { return }
                self.selectedRange = caret
            }
        }
        // 系统为刚才那笔输入记下的撤销范围已经对不上截断后的正文，撤销会越界崩溃。清空撤销记录。
        undoManager?.removeAllActions()
        return true
    }

    private var usesDocumentLinkStyle = false
    private var hasExplicitLinkStyle = false

    /// 宿主显式设置时沿用 UIKit 的全局覆盖。设为 nil 恢复自动选择文档或系统链接外观。
    open override var linkTextAttributes: [NSAttributedString.Key: Any]! {
        get { super.linkTextAttributes }
        set {
            hasExplicitLinkStyle = newValue != nil
            usesDocumentLinkStyle = false
            super.linkTextAttributes = newValue
            if newValue == nil { refreshLinkStyle(for: super.attributedText) }
        }
    }

    /// 高级 HTML 导入的链接自带 CSS。切换回普通内容时恢复 UIKit 默认样式，不影响显式业务设置。
    private func refreshLinkStyle(for text: NSAttributedString?) {
        guard !hasExplicitLinkStyle else { return }
        var styled = false
        if let text {
            text.enumerateAttribute(TextForgeHTML.styledLink, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if value != nil { styled = true; stop.pointee = true }
            }
        }
        if usesDocumentLinkStyle != styled {
            usesDocumentLinkStyle = styled
            super.linkTextAttributes = styled ? [:] : nil
        }
    }

    private let placeholderLabel = UILabel()
    private var lastCommittedText = ""
    private var observedStorageText = ""
    private var isUpdatingComposition = false
    private var textAssignmentDepth = 0
    private var hasPendingStorageEdit = false
    private var isUpdatingAttributes = false
    private var isSettingMarkedText = false
    private var compositionBaseline: String?
    private var customAccessibilityValue: String?
    private var attributedPlaceholder: NSAttributedString?

    /// 默认使用上下 6 点、左右 4 点内容内边距，传入自定义容器时保留容器的行片段边距。
    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        if textContainer == nil { self.textContainer.lineFragmentPadding = 0 }
        setupPlaceholder()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlaceholder()
    }

    /// 直接设置纯文本时恢复系统链接外观并同步占位；用户编辑事务内由代理触发的同步裁剪保留编辑前比较基线。
    open override var text: String! {
        willSet { textAssignmentDepth += 1 }
        didSet {
            textAssignmentDepth -= 1
            refreshLinkStyle(for: nil)
            observedStorageText = text ?? ""
            if !isUpdatingComposition, !hasPendingStorageEdit {
                lastCommittedText = observedStorageText
                compositionBaseline = nil
            }
            updatePlaceholderVisibility()
        }
    }

    /// 直接设置富文本时应用其链接样式并同步占位；用户编辑事务内由代理触发的同步裁剪保留编辑前比较基线。
    open override var attributedText: NSAttributedString! {
        willSet { textAssignmentDepth += 1 }
        didSet {
            textAssignmentDepth -= 1
            refreshLinkStyle(for: attributedText)
            observedStorageText = text ?? ""
            if !isUpdatingComposition, !hasPendingStorageEdit {
                lastCommittedText = observedStorageText
                compositionBaseline = nil
            }
            updatePlaceholderVisibility()
        }
    }

    /// 在非组字状态下就地更新富文本样式（如话题、提及高亮），保持正文字符、当前光标选区且不触发额外的 onTextChange。
    /// 可从原生编辑代理内调用。组字、递归更新或正文码元变化时返回 false；只写回变动的属性段。
    @objc(updateTextAttributes:) @discardableResult
    public func updateTextAttributes(_ body: (NSMutableAttributedString) -> Void) -> Bool {
        guard !isUpdatingAttributes, !isSettingMarkedText, markedTextRange == nil else { return false }
        isUpdatingAttributes = true
        defer { isUpdatingAttributes = false }
        let current = NSAttributedString(attributedString: textStorage)
        let mutable = NSMutableAttributedString(attributedString: current)
        body(mutable)
        guard mutable.string.utf16.elementsEqual(current.string.utf16), textStorage.isEqual(to: current),
              markedTextRange == nil else { return false }
        let savedTyping = typingAttributes
        textStorage.beginEditing()
        mutable.enumerateAttributes(in: NSRange(location: 0, length: mutable.length)) { attrs, range, _ in
            current.enumerateAttributes(in: range) { old, part, _ in
                if !(old as NSDictionary).isEqual(to: attrs) { textStorage.setAttributes(attrs, range: part) }
            }
        }
        textStorage.endEditing()
        if !(typingAttributes as NSDictionary).isEqual(to: savedTyping) { typingAttributes = savedTyping }
        refreshLinkStyle(for: textStorage)
        return true
    }

    /// 按 UITextView 的内容区摆放占位标签，保持字体、对齐和内边距一致。
    open override func layoutSubviews() {
        super.layoutSubviews()
        if needsHeightUpdate || bounds.width != measuredWidth { updatePreferredHeight() }
        if needsScrollReset {
            // 刚开始滚动时（例如一次粘贴了很多行）光标可能在可见区域之外；不再滚动时内容回到顶部。
            needsScrollReset = false
            if isScrollEnabled {
                // 滚动要等本轮布局结束。TextKit 2 对视口外的内容只估算高度，滚过去之后位置会被修正，
                // 所以按光标矩形滚动并复核，最多三次。
                DispatchQueue.main.async { [weak self] in self?.scrollCaretToVisible() }
            } else {
                setContentOffset(CGPoint(x: contentOffset.x, y: -adjustedContentInset.top), animated: false)
            }
        }
        guard !placeholderLabel.isHidden else { return }
        placeholderLabel.font = placeholderFont ?? font ?? UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.textAlignment = textAlignment
        placeholderLabel.semanticContentAttribute = semanticContentAttribute
        if let attributedPlaceholder {
            placeholderLabel.attributedText = attributedPlaceholder
        } else {
            placeholderLabel.text = placeholder
        }
        let inset = textContainerInset
        let padding = textContainer.lineFragmentPadding
        let width = max(0, bounds.width - inset.left - inset.right - 2 * padding)
        let height = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        placeholderLabel.frame = CGRect(x: inset.left + padding, y: inset.top, width: width, height: height)
    }

    /// UIKit 替换标记时可先删后写，期间短暂没有 markedTextRange。等最外层操作完成再判断是否提交。
    private func updateComposition(_ update: () -> Void) {
        if isUpdatingComposition { update(); return }
        hasPendingStorageEdit = false
        if compositionBaseline == nil { compositionBaseline = text ?? "" }
        isUpdatingComposition = true
        update()
        isUpdatingComposition = false
        textDidChange()
    }

    /// 非空组字替换期间抑制样式更新；空串或 nil 取消组字后，原生代理可立即更新最终正文的样式。
    open override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        updateComposition {
            let previous = isSettingMarkedText
            isSettingMarkedText = previous || !(markedText?.isEmpty ?? true)
            super.setMarkedText(markedText, selectedRange: selectedRange)
            isSettingMarkedText = previous
        }
    }

    /// 候选字或普通输入均在整次插入完成后再比较并报告上屏结果，兼容代理在 textViewDidChange 中同步裁剪。
    open override func insertText(_ text: String) {
        updateComposition { super.insertText(text) }
    }

    /// 部分输入法经 UITextInput 的范围替换接口提交候选，沿用同一个编辑事务边界。
    open override func replace(_ range: UITextRange, withText text: String) {
        updateComposition { super.replace(range, withText: text) }
    }

    /// 删除字符或撤销标记时，UIKit 与代理可以分多步修改存储，只比较操作结束后的正文。
    open override func deleteBackward() {
        updateComposition { super.deleteBackward() }
    }

    /// 编辑器的朗读值使用附件的替代文案，保留宿主显式设置和系统安全输入行为。
    open override var accessibilityValue: String? {
        get {
            if let customAccessibilityValue { return customAccessibilityValue }
            guard !isSecureTextEntry, let attributedText, TextForgeAttachment.hasTextAlternatives(in: attributedText) else {
                return super.accessibilityValue
            }
            return TextForgeAttachment.accessibilityText(for: attributedText)
        }
        set {
            customAccessibilityValue = newValue
            super.accessibilityValue = newValue
        }
    }

    /// 剪切同步完成，用操作开始时的正文比较代理裁剪后的最终结果。
    open override func cut(_ sender: Any?) {
        updateComposition { super.cut(sender) }
    }

    /// 粘贴可能异步加载。丢弃先前独立存储编辑的基线，在 UIKit 真正写入时再取当前正文。
    open override func paste(_ sender: Any?) {
        hasPendingStorageEdit = false
        super.paste(sender)
    }

    /// 通过项目提供者发起粘贴时，同样从此次载入后的写入开始记录。
    open override func paste(itemProviders: [NSItemProvider]) {
        hasPendingStorageEdit = false
        super.paste(itemProviders: itemProviders)
    }

    /// 选区含语义附件时用其替代文字提供纯文本；其余选区沿用系统复制，包括安全输入限制。
    open override func copy(_ sender: Any?) {
        guard !isSecureTextEntry, let attributedText, selectedRange.location >= 0,
              selectedRange.location <= attributedText.length, selectedRange.length > 0,
              selectedRange.length <= attributedText.length - selectedRange.location else { return super.copy(sender) }
        let selection = attributedText.attributedSubstring(from: selectedRange)
        guard TextForgeAttachment.hasTextAlternatives(in: selection) else { return super.copy(sender) }
        var item: [String: Any] = ["public.utf8-plain-text": TextForgeAttachment.copyText(for: selection)]
        if allowsEditingTextAttributes, let data = try? selection.data(
            from: NSRange(location: 0, length: selection.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) { item["com.apple.flat-rtfd"] = data }
        UIPasteboard.general.items = [item]
    }

    /// 组字结束后读取最终文本，兼容提交时未单独发送文本变化通知的输入路径。
    open override func unmarkText() {
        guard compositionBaseline != nil || markedTextRange != nil else { super.unmarkText(); return }
        updateComposition { super.unmarkText() }
    }

    /// 分别观察此输入框的文本存储和 UIKit 编辑通知，保持宿主对两个 delegate 的控制权。
    private func setupPlaceholder() {
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        lastCommittedText = text ?? ""
        observedStorageText = lastCommittedText
        updatePlaceholderVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidChange(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextChangeNotification(_:)),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    /// 原生粘贴和剪切可直接写入存储，再调用宿主代理，最后发送 UIKit 通知。
    /// 从第一笔存储变更保留编辑前正文，直到 UIKit 确认；代理内赋值或直接裁剪存储都只改变最终值。
    @objc private func storageDidChange(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let current = storage.string
        guard current != observedStorageText else { return }
        if textAssignmentDepth == 0, !isUpdatingComposition, !hasPendingStorageEdit {
            lastCommittedText = observedStorageText
            hasPendingStorageEdit = true
            // 无 UIKit 通知的独立写入只在本轮合并。释放标记不改比较基线，迟到的通知仍可比较最终正文。
            DispatchQueue.main.async { [weak self] in self?.hasPendingStorageEdit = false }
        }
        observedStorageText = current
        updatePlaceholderVisibility(measuresHeight: false)
    }

    /// UIKit 确认用户编辑后消费存储基线；普通赋值不发送此通知，组字事务仍在最外层完成后交付。
    @objc private func handleTextChangeNotification(_ notification: Notification) {
        hasPendingStorageEdit = false
        textDidChange()
    }

    /// 文本或组字内容出现后隐藏占位，恢复为空时重新布局占位文字，并更新自适应高度。
    /// measuresHeight 为 false 用于存储编辑进行中：只做标记，高度留到编辑结束或下一次布局再算。
    private func updatePlaceholderVisibility(measuresHeight: Bool = true) {
        let content = attributedPlaceholder?.string ?? placeholder ?? ""
        placeholderLabel.isHidden = textStorage.length > 0 || content.isEmpty
        if !placeholderLabel.isHidden { setNeedsLayout() }
        if measuresHeight {
            updatePreferredHeight()
        } else if minimumNumberOfLines > 0 || maximumNumberOfLines > 0 {
            needsHeightUpdate = true
            setNeedsLayout()
        }
    }

    /// 跳过中文组字和重复通知，先按字数上限截断，再更新比较基线并回调，允许宿主在回调中改写文本。
    private func textDidChange() {
        updatePlaceholderVisibility()
        guard !isUpdatingComposition, markedTextRange == nil else { return }
        let truncated = enforceTextLimit(previous: compositionBaseline ?? lastCommittedText)
        defer { if truncated { onTextLimitReached?() } }
        let currentText = text ?? ""
        if let compositionBaseline {
            lastCommittedText = compositionBaseline
            self.compositionBaseline = nil
        }
        guard currentText != lastCommittedText else { return }
        lastCommittedText = currentText
        onTextChange?(currentText)
    }
}
