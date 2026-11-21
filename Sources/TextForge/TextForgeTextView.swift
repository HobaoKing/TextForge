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

    /// 直接设置纯文本时恢复系统链接外观并同步占位和比较基线。
    open override var text: String! {
        didSet {
            refreshLinkStyle(for: nil)
            lastCommittedText = text ?? ""
            observedStorageText = lastCommittedText
            compositionBaseline = nil
            updatePlaceholderVisibility()
        }
    }

    /// 直接设置富文本时应用其链接样式并同步占位，以纯文本作为下一次编辑的比较基线。
    open override var attributedText: NSAttributedString! {
        didSet {
            refreshLinkStyle(for: attributedText)
            lastCommittedText = text ?? ""
            observedStorageText = lastCommittedText
            compositionBaseline = nil
            updatePlaceholderVisibility()
        }
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
        if compositionBaseline == nil { compositionBaseline = text ?? "" }
        isUpdatingComposition = true
        update()
        isUpdatingComposition = false
        textDidChange()
    }

    /// 记录第一笔拼音前的正文。后续改写标记只更新占位状态，原生标记真正结束才比较最终文本。
    open override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        updateComposition { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    /// 候选字可直接替换标记；整次插入完成后再报告上屏结果。
    open override func insertText(_ text: String) {
        guard compositionBaseline != nil || markedTextRange != nil else { super.insertText(text); return }
        updateComposition { super.insertText(text) }
    }

    /// 部分输入法经 UITextInput 的范围替换接口提交候选，沿用同一个组字边界。
    open override func replace(_ range: UITextRange, withText text: String) {
        guard compositionBaseline != nil || markedTextRange != nil else { super.replace(range, withText: text); return }
        updateComposition { super.replace(range, withText: text) }
    }

    /// 删除或撤销标记时，UIKit 可以分多步修改存储，只比较操作结束后的正文。
    open override func deleteBackward() {
        guard compositionBaseline != nil || markedTextRange != nil else { super.deleteBackward(); return }
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

    /// 存储通知先于 UIKit 编辑通知。直接写入只同步界面，下一次用户编辑以变更前的真实内容为基线。
    @objc private func storageDidChange(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let current = storage.string
        guard current != observedStorageText else { return }
        lastCommittedText = compositionBaseline ?? observedStorageText
        observedStorageText = current
        updatePlaceholderVisibility()
    }

    @objc private func handleTextChangeNotification(_ notification: Notification) {
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
