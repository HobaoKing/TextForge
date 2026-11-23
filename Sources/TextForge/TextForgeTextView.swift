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
        updatePlaceholderVisibility()
    }

    /// UIKit 确认用户编辑后消费存储基线；普通赋值不发送此通知，组字事务仍在最外层完成后交付。
    @objc private func handleTextChangeNotification(_ notification: Notification) {
        hasPendingStorageEdit = false
        textDidChange()
    }

    /// 文本或组字内容出现后隐藏占位，恢复为空时重新布局占位文字。
    private func updatePlaceholderVisibility() {
        let content = attributedPlaceholder?.string ?? placeholder ?? ""
        placeholderLabel.isHidden = textStorage.length > 0 || content.isEmpty
        if !placeholderLabel.isHidden { setNeedsLayout() }
    }

    /// 跳过中文组字和重复通知，先更新比较基线再回调，允许宿主在回调中改写文本。
    private func textDidChange() {
        updatePlaceholderVisibility()
        guard !isUpdatingComposition, markedTextRange == nil else { return }
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
