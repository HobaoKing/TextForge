import UIKit

/// 以字体基线或控件内容区域为基准进行纵向对齐。
@objc public enum TextForgeVerticalAlignment: Int {
    case top
    case center
    case bottom
}

/// 以 UTF-16 范围和控件坐标回传交互对应的原始富文本。
public typealias TextForgeTextAction = (UIView, NSAttributedString, NSRange, CGRect) -> Void

@objc(TextForgeTypography)
public final class TextForgeTypography: NSObject {
    /// 复制传入富文本并覆盖指定的间距，nil 保留原属性，0 可显式清除该项。其余段落属性和文本范围保持原样。
    @objc public static func styledText(
        _ text: NSAttributedString,
        characterSpacing: NSNumber?,
        lineSpacing: NSNumber?,
        paragraphSpacing: NSNumber?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: text.length)
        if let characterSpacing {
            result.addAttribute(.kern, value: characterSpacing, range: range)
        }
        if lineSpacing != nil || paragraphSpacing != nil {
            text.enumerateAttribute(.paragraphStyle, in: range) { value, segment, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                if let lineSpacing { style.lineSpacing = CGFloat(lineSpacing.doubleValue) }
                if let paragraphSpacing { style.paragraphSpacing = CGFloat(paragraphSpacing.doubleValue) }
                result.addAttribute(.paragraphStyle, value: style.copy(), range: segment)
            }
        }
        return result
    }
}

@objc(TextForgeHighlight)
public final class TextForgeHighlight: NSObject {
    @objc public var userInfo: [String: Any]?
    @objc public var highlightedTextColor: UIColor?
    @objc public var tapAction: TextForgeTextAction?
    @objc public var longPressAction: TextForgeTextAction?

    let backgroundColor: UIColor?
    private let foregroundColor: UIColor?
    static let attribute = NSAttributedString.Key("TextForge.Highlight")

    @objc public init(color: UIColor?, backgroundColor: UIColor?) {
        foregroundColor = color
        self.backgroundColor = backgroundColor
    }

    /// 在合法的 UTF-16 范围内写入颜色和高亮对象，越界或空范围保持原文本。
    @objc public func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.location >= 0, range.location <= text.length,
              range.length > 0, range.length <= text.length - range.location else { return }
        if let foregroundColor { text.addAttribute(.foregroundColor, value: foregroundColor, range: range) }
        text.addAttribute(Self.attribute, value: self, range: range)
    }

    /// 读取相应 UTF-16 位置的高亮信息，越界时返回 nil。
    @objc public static func highlight(in text: NSAttributedString, at index: Int) -> TextForgeHighlight? {
        guard index >= 0, index < text.length else { return nil }
        return text.attribute(attribute, at: index, effectiveRange: nil) as? TextForgeHighlight
    }
}

@MainActor
@objc(TextForgeAttachment)
public final class TextForgeAttachment: NSObject {
    /// 图片按原尺寸居中放入指定尺寸的附件槽，按字体基线对齐，尺寸以点计。
    @objc public static func image(
        _ image: UIImage,
        size: CGSize,
        font: UIFont,
        alignment: TextForgeVerticalAlignment
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let bounds = attachmentBounds(size: size, font: font, alignment: alignment)
        attachment.bounds = bounds
        if bounds.size == image.size {
            attachment.image = image
        } else if !bounds.isEmpty {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            attachment.image = renderer.image { _ in
                image.draw(at: CGPoint(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2))
            }
        }
        return NSAttributedString(attachment: attachment)
    }

    /// 为文本保留指定尺寸并随标签挂载传入视图，同一个 UIView 由当前显示的标签持有。
    @objc public static func view(
        _ view: UIView,
        size: CGSize,
        font: UIFont,
        alignment: TextForgeVerticalAlignment
    ) -> NSAttributedString {
        let attachment = TextForgeViewAttachment(view: view)
        attachment.bounds = attachmentBounds(size: size, font: font, alignment: alignment)
        return NSAttributedString(attachment: attachment)
    }

    /// 换算相对基线向上的偏移，使图片或视图与字体的顶部、中心或底部对齐。
    private static func attachmentBounds(size: CGSize, font: UIFont, alignment: TextForgeVerticalAlignment) -> CGRect {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        let y: CGFloat
        switch alignment {
        case .top: y = font.ascender - height
        case .center: y = (font.ascender + font.descender - height) / 2
        case .bottom: y = font.descender
        }
        return CGRect(x: 0, y: y, width: width, height: height)
    }
}

final class TextForgeViewAttachment: NSTextAttachment {
    let view: UIView
    let viewSize: CGSize

    /// 捕获宿主传入时的内容尺寸，重复挂载时仍按原尺寸居中。
    @MainActor
    init(view: UIView) {
        self.view = view
        viewSize = view.bounds.size
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        // 剪贴板或归档恢复无法还原宿主持有的 UIView。
        return nil
    }
}
