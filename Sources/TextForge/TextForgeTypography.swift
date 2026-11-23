import UIKit

/// 以字体基线或控件内容区域为基准进行纵向对齐。
@objc public enum TextForgeVerticalAlignment: Int {
    case top
    case center
    case bottom
}

/// 以 UTF-16 范围和控件坐标回传交互对应的富文本。
/// 命中截断标记时，富文本为截断标记，范围是标记内部的下标。
public typealias TextForgeTextAction = (UIView, NSAttributedString, NSRange, CGRect) -> Void

@objc(TextForgeTypography)
public final class TextForgeTypography: NSObject {
    /// 标记由 styledText 为原本无段落样式的区间合成的段落属性，供控件补齐对齐和断行策略。
    static let synthesizedParagraphStyle = NSAttributedString.Key("TextForge.SynthesizedParagraphStyle")

    /// 复制传入富文本并覆盖指定的间距，nil 保留原属性，0 可显式清除该项。圆角背景为相邻字素预留的水平间距另行叠加。
    @objc public static func styledText(
        _ text: NSAttributedString,
        characterSpacing: NSNumber?,
        lineSpacing: NSNumber?,
        paragraphSpacing: NSNumber?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: text.length)
        if let characterSpacing {
            text.enumerateAttribute(TextForgeBackground.marginKern, in: range) { extra, part, _ in
                let kern = characterSpacing.doubleValue + ((extra as? NSNumber)?.doubleValue ?? 0)
                result.addAttribute(.kern, value: kern, range: part)
            }
        }
        if lineSpacing != nil || paragraphSpacing != nil {
            text.enumerateAttribute(.paragraphStyle, in: range) { value, segment, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                if let lineSpacing { style.lineSpacing = CGFloat(lineSpacing.doubleValue) }
                if let paragraphSpacing { style.paragraphSpacing = CGFloat(paragraphSpacing.doubleValue) }
                result.addAttribute(.paragraphStyle, value: style.copy(), range: segment)
                if value == nil {
                    result.addAttribute(Self.synthesizedParagraphStyle, value: true, range: segment)
                }
            }
        }
        return result
    }
}

@objc(TextForgeHighlight)
public final class TextForgeHighlight: NSObject {
    /// 富文本属性名，值为 TextForgeHighlight。可用它在富文本中枚举已有的高亮。
    @objc public static let attributeName = NSAttributedString.Key("TextForge.Highlight")

    @objc public var userInfo: [String: Any]?
    @objc public var highlightedTextColor: UIColor?
    @objc public var tapAction: TextForgeTextAction?
    @objc public var longPressAction: TextForgeTextAction?
    /// 写入文本时使用的常态前景色，nil 保留文本原色。
    @objc public let color: UIColor?
    /// 按住时画在文字下方的底色，nil 表示没有按压底色。
    @objc public let backgroundColor: UIColor?
    /// 按压底色的圆角半径，单位为点。
    @objc public var cornerRadius: CGFloat = 0
    /// 按压底色相对文字排版矩形的边距，负值外扩。
    @objc public var backgroundInsets: UIEdgeInsets = .zero

    @objc public init(color: UIColor?, backgroundColor: UIColor?) {
        self.color = color
        self.backgroundColor = backgroundColor
    }

    /// 只设置按压底色，文字保留原色。
    @objc public convenience init(backgroundColor: UIColor?) {
        self.init(color: nil, backgroundColor: backgroundColor)
    }

    /// 在合法的 UTF-16 范围内写入颜色和高亮对象，越界或空范围保持原文本。
    @objc public func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.location >= 0, range.location <= text.length,
              range.length > 0, range.length <= text.length - range.location else { return }
        if let color { text.addAttribute(.foregroundColor, value: color, range: range) }
        text.addAttribute(Self.attributeName, value: self, range: range)
    }

    /// 读取相应 UTF-16 位置的高亮信息，越界时返回 nil。
    @objc public static func highlight(in text: NSAttributedString, at index: Int) -> TextForgeHighlight? {
        guard index >= 0, index < text.length else { return nil }
        return text.attribute(attributeName, at: index, effectiveRange: nil) as? TextForgeHighlight
    }

    /// 按压时使用的底色描述，没有底色时为 nil。
    var pressedBackground: TextForgeBackground? {
        guard let backgroundColor else { return nil }
        let background = TextForgeBackground(fillColor: backgroundColor, cornerRadius: cornerRadius)
        background.insets = backgroundInsets
        return background
    }
}

@MainActor
@objc(TextForgeAttachment)
public final class TextForgeAttachment: NSObject {
    private static let copyKey = NSAttributedString.Key("TextForge.AttachmentCopyText")
    private static let speechKey = NSAttributedString.Key("TextForge.AttachmentAccessibilityText")

    /// 给已有的图片或视图附件设置文字替代。nil 清除该项，朗读默认沿用复制文本；空串可显式静音。
    @objc(attachmentString:copyText:accessibilityText:)
    public static func withTextAlternatives(_ text: NSAttributedString, copyText: String?, accessibilityText: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            for (key, alternative) in [(copyKey, copyText), (speechKey, accessibilityText)] {
                if let alternative { result.addAttribute(key, value: alternative, range: range) }
                else { result.removeAttribute(key, range: range) }
            }
        }
        return result
    }

    /// 导出全文或子串的纯文本，附件按复制文案展开。没有复制文案的装饰性附件省略。
    @objc(copyTextForAttributedString:) public static func copyText(for text: NSAttributedString) -> String {
        replacingAttachments(in: text, forSpeech: false)
    }

    /// 导出朗读文案，未单独设置朗读名称的附件沿用复制文案。
    @objc(accessibilityTextForAttributedString:) public static func accessibilityText(for text: NSAttributedString) -> String {
        replacingAttachments(in: text, forSpeech: true)
    }

    /// 按 UTF-16 下标替换附件。显式文案（含空串）优先，未指定时沿用系统 HTML 图片的 alt。
    private static func replacingAttachments(in text: NSAttributedString, forSpeech: Bool) -> String {
        let source = text.string as NSString
        let marker = "\u{FFFC}"
        var next = source.range(of: marker)
        guard next.location != NSNotFound else { return text.string }
        let result = NSMutableString(capacity: source.length)
        var start = 0
        while next.location != NSNotFound {
            result.append(source.substring(with: NSRange(location: start, length: next.location - start)))
            let copy = text.attribute(copyKey, at: next.location, effectiveRange: nil) as? String
            let spoken = forSpeech ? text.attribute(speechKey, at: next.location, effectiveRange: nil) as? String : nil
            let attachment = text.attribute(.attachment, at: next.location, effectiveRange: nil) as? NSTextAttachment
            result.append(spoken ?? copy ?? attachment?.accessibilityLabel ?? "")
            start = NSMaxRange(next)
            next = source.range(of: marker, options: [], range: NSRange(location: start, length: source.length - start))
        }
        result.append(source.substring(from: start))
        return result as String
    }

    /// 编辑器只接管带显式或原生替代文案的内容，其余选择继续交给 UIKit 的原生复制和辅助功能。
    static func hasTextAlternatives(in text: NSAttributedString) -> Bool {
        guard text.string.contains("\u{FFFC}") else { return false }
        var found = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            found = attributes[copyKey] != nil || attributes[speechKey] != nil
                || (attributes[.attachment] as? NSTextAttachment)?.accessibilityLabel != nil
            if found { stop.pointee = true }
        }
        return found
    }

    /// 图片按原尺寸居中放入指定尺寸的附件槽，按字体基线对齐，尺寸以点计。
    @objc public static func image(
        _ image: UIImage,
        size: CGSize,
        font: UIFont,
        alignment: TextForgeVerticalAlignment
    ) -> NSAttributedString {
        self.image(image, contentMode: .center, size: size, font: font, alignment: alignment)
    }

    /// 图片按内容模式放入指定尺寸的附件槽，超出槽的部分被裁掉。
    /// 支持 scaleToFill、scaleAspectFit、scaleAspectFill 和 center，其余模式按 center 处理。
    @objc public static func image(
        _ image: UIImage,
        contentMode: UIView.ContentMode,
        size: CGSize,
        font: UIFont,
        alignment: TextForgeVerticalAlignment
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let bounds = attachmentBounds(size: size, font: font, alignment: alignment)
        attachment.bounds = bounds
        let slot = bounds.size
        var drawSize = image.size
        if image.size.width > 0, image.size.height > 0 {
            let horizontal = slot.width / image.size.width
            let vertical = slot.height / image.size.height
            switch contentMode {
            case .scaleToFill:
                drawSize = slot
            case .scaleAspectFit:
                drawSize = CGSize(width: image.size.width * min(horizontal, vertical), height: image.size.height * min(horizontal, vertical))
            case .scaleAspectFill:
                drawSize = CGSize(width: image.size.width * max(horizontal, vertical), height: image.size.height * max(horizontal, vertical))
            default:
                break
            }
        }
        if drawSize == slot, slot == image.size {
            attachment.image = image
        } else if !bounds.isEmpty {
            let format = UIGraphicsImageRendererFormat()
            format.scale = max(image.scale, UIScreen.main.scale, UITraitCollection.current.displayScale)
            let renderer = UIGraphicsImageRenderer(size: slot, format: format)
            attachment.image = renderer.image { _ in
                image.draw(in: CGRect(
                    x: (slot.width - drawSize.width) / 2, y: (slot.height - drawSize.height) / 2,
                    width: drawSize.width, height: drawSize.height
                ))
            }.withRenderingMode(image.renderingMode)
        } else {
            attachment.image = TextForgeViewAttachment.blankImage
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

    /// 为文本保留指定尺寸，仅当附件落入标签可见视口时才在主线程调用 provider 实例化视图。
    @objc(viewWithSize:font:alignment:provider:)
    public static func view(
        size: CGSize,
        font: UIFont,
        alignment: TextForgeVerticalAlignment,
        provider: @escaping @MainActor () -> UIView
    ) -> NSAttributedString {
        let attachment = TextForgeViewAttachment(size: size, provider: provider)
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
    /// 供视图附件与后台分离占位共用，阻止 TextKit 在 image 为 nil 时绘制系统默认缺失图标。
    static let blankImage = UIImage()
    private var cachedView: UIView?
    private let provider: (@MainActor () -> UIView)?
    private(set) var viewSize: CGSize

    /// 捕获宿主传入时的内容尺寸，重复挂载时仍按原尺寸居中。
    @MainActor
    init(view: UIView) {
        cachedView = view
        provider = nil
        viewSize = view.bounds.size
        super.init(data: nil, ofType: nil)
        image = Self.blankImage
    }

    /// 仅记录占位尺寸与主线程构造闭包，在视口真正需要挂载时才创建 UIView。
    @MainActor
    init(size: CGSize, provider: @escaping @MainActor () -> UIView) {
        cachedView = nil
        self.provider = provider
        viewSize = CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        )
        super.init(data: nil, ofType: nil)
        image = Self.blankImage
    }

    /// 在主线程返回已缓存或按需创建的视图，首次实例化后若视图自带非零尺寸则同步记录。
    @MainActor
    var view: UIView {
        if let cachedView { return cachedView }
        let created = provider!()
        if created.bounds.size.width > 0, created.bounds.size.height > 0 {
            viewSize = created.bounds.size
        }
        cachedView = created
        return created
    }

    required init?(coder: NSCoder) {
        // 剪贴板或归档恢复无法还原宿主持有的 UIView。
        return nil
    }
}
