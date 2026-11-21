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

    private let placeholderLabel = UILabel()
    private var lastCommittedText = ""
    private var observedStorageText = ""
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

    /// 直接设置文本时同步占位状态和比较基线，由调用端自行处理业务通知。
    open override var text: String! {
        didSet {
            lastCommittedText = text ?? ""
            observedStorageText = lastCommittedText
            compositionBaseline = nil
            updatePlaceholderVisibility()
        }
    }

    /// 直接设置富文本时同步占位状态，以其纯文本作为下一次编辑的比较基线。
    open override var attributedText: NSAttributedString! {
        didSet {
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

    /// 组字可包含多次底层存储修改。保存进入组字前的全文，只在最终提交时比较一次。
    open override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if compositionBaseline == nil, markedText != nil { compositionBaseline = text ?? "" }
        super.setMarkedText(markedText, selectedRange: selectedRange)
        if markedTextRange == nil, compositionBaseline != nil { textDidChange() }
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
        let wasComposing = markedTextRange != nil
        super.unmarkText()
        if wasComposing { textDidChange() }
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
        guard markedTextRange == nil else { return }
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
