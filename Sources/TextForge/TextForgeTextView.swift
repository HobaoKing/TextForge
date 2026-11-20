import UIKit

/// 在原生 UITextView 上补齐占位文案和已提交文本的变化回调。
@objc(TextForgeTextView)
public final class TextForgeTextView: UITextView {
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
    public override var text: String! {
        didSet {
            lastCommittedText = text ?? ""
            updatePlaceholderVisibility()
        }
    }

    /// 直接设置富文本时同步占位状态，以其纯文本作为下一次编辑的比较基线。
    public override var attributedText: NSAttributedString! {
        didSet {
            lastCommittedText = text ?? ""
            updatePlaceholderVisibility()
        }
    }

    /// 按 UITextView 的内容区摆放占位标签，保持字体、对齐和内边距一致。
    public override func layoutSubviews() {
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

    /// 组字结束后读取最终文本，兼容提交时未单独发送文本变化通知的输入路径。
    public override func unmarkText() {
        let wasComposing = markedTextRange != nil
        super.unmarkText()
        if wasComposing { textDidChange() }
    }

    /// 只观察此输入框的 UIKit 编辑通知，保持宿主对 UITextViewDelegate 的控制权。
    private func setupPlaceholder() {
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        lastCommittedText = text ?? ""
        updatePlaceholderVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextChangeNotification(_:)),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    @objc private func handleTextChangeNotification(_ notification: Notification) {
        textDidChange()
    }

    /// 文本或组字内容出现后隐藏占位，恢复为空时重新布局占位文字。
    private func updatePlaceholderVisibility() {
        let content = attributedPlaceholder?.string ?? placeholder ?? ""
        placeholderLabel.isHidden = !(text ?? "").isEmpty || content.isEmpty
        if !placeholderLabel.isHidden { setNeedsLayout() }
    }

    /// 跳过中文组字和重复通知，先更新比较基线再回调，允许宿主在回调中改写文本。
    private func textDidChange() {
        updatePlaceholderVisibility()
        guard markedTextRange == nil else { return }
        let currentText = text ?? ""
        guard currentText != lastCommittedText else { return }
        lastCommittedText = currentText
        onTextChange?(currentText)
    }
}
