import UIKit

/// 一次排版的边界与策略。交给 TextForgeLayout 后会被复制，之后再改不影响已生成的布局。
@objc(TextForgeContainer)
public final class TextForgeContainer: NSObject, NSCopying {
    /// 包含内边距的外部边界，单位为点。某一维不限时传 `.greatestFiniteMagnitude`。
    @objc public var size: CGSize
    /// 文本与外部边界之间的内边距，单位为点。
    @objc public var insets: UIEdgeInsets
    /// 最多显示的行数，0 表示不限行。
    @objc public var maximumNumberOfRows = 0
    /// 放不下时的处理方式，默认折行且不加省略号。
    @objc public var lineBreakMode: NSLineBreakMode = .byWordWrapping

    /// 单行允许的最小字号比例。1 保持原字号，仅在启用缩放时试排。
    @objc public var minimumScaleFactor: CGFloat = 1

    /// 替代系统省略号的截断标记，仅在 `lineBreakMode` 为 `.byTruncatingTail` 且内容放不下时生效。
    /// 标记缺少的字体、前景色和段落样式沿用截断处的正文，可携带 TextForgeHighlight 或链接来响应点击。
    @objc public var truncationToken: NSAttributedString? {
        didSet { truncationToken = truncationToken.map { NSAttributedString(attributedString: $0) } }
    }

    /// 文本需要绕开的区域，坐标以扣除内边距后的排版区左上角为原点。
    @objc public var exclusionPaths: [UIBezierPath] = []

    /// 叠加在 `.link` 范围上的显示属性，会覆盖该范围原有的同名属性。传空字典则保留文本自身样式。
    @objc public var linkTextAttributes: [NSAttributedString.Key: Any] = TextForgeContainer.defaultLinkTextAttributes {
        didSet { hasExplicitLinkStyle = true }
    }
    private(set) var hasExplicitLinkStyle = false

    /// 链接的默认外观：系统链接色，不加下划线。
    @objc public static var defaultLinkTextAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: UIColor.link]
    }

    @objc public init(size: CGSize, insets: UIEdgeInsets) {
        self.size = size
        self.insets = insets
    }

    @objc public convenience init(size: CGSize) {
        self.init(size: size, insets: .zero)
    }

    /// 生成可直接交给标签或预排版容器的全文标记。点击可见文字或执行辅助操作时，在主线程回调标记自身的范围。
    @objc(readMoreTokenWithTitle:action:)
    public static func readMoreToken(title: String = "…全文", action: @escaping TextForgeTextAction) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title)
        let highlight = TextForgeHighlight(color: .link, backgroundColor: .tertiarySystemFill)
        highlight.cornerRadius = 3
        highlight.tapAction = action
        highlight.apply(to: text, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 复制全部配置。排除路径逐个复制，调用方之后修改原路径不会影响副本。
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = TextForgeContainer(size: size, insets: insets)
        copy.maximumNumberOfRows = maximumNumberOfRows
        copy.lineBreakMode = lineBreakMode
        copy.minimumScaleFactor = minimumScaleFactor
        copy.truncationToken = truncationToken
        copy.exclusionPaths = exclusionPaths.map { $0.copy() as? UIBezierPath ?? $0 }
        if hasExplicitLinkStyle { copy.linkTextAttributes = linkTextAttributes }
        return copy
    }
}

/// 一行排版结果。范围使用原文的 UTF-16 下标，坐标以布局外部边界的左上角为原点。
@objc(TextForgeLine)
public final class TextForgeLine: NSObject {
    /// 本行可见原文的外接范围。头部和中部截断可能在范围中留下空缺，截断标记本身不计入范围。
    @objc public let range: NSRange
    /// 本行文字占用的矩形，高度包含行距。
    @objc public let rect: CGRect
    /// 基线的纵坐标。
    @objc public let baseline: CGFloat
    /// 所在的视觉行，从 0 开始。排除路径把同一行切成多段时，各段共享同一个值。
    @objc public let row: Int

    init(range: NSRange, rect: CGRect, baseline: CGFloat, row: Int) {
        self.range = range
        self.rect = rect
        self.baseline = baseline
        self.row = row
    }
}

/// 画在文字下方的圆角背景或描边，可用于标签、提及和按压反馈。
@objc(TextForgeBackground)
public final class TextForgeBackground: NSObject {
    /// 富文本属性名，值为 TextForgeBackground。
    @objc public static let attributeName = NSAttributedString.Key("TextForge.Background")

    @objc public var fillColor: UIColor?
    @objc public var strokeColor: UIColor?
    /// 描边线宽，单位为点，0 表示不描边。
    @objc public var strokeWidth: CGFloat = 0
    @objc public var cornerRadius: CGFloat = 0
    /// 相对文字排版矩形的边距，正值收缩、负值外扩。
    @objc public var insets: UIEdgeInsets = .zero

    @objc public init(fillColor: UIColor?, cornerRadius: CGFloat) {
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
    }

    @objc public convenience init(fillColor: UIColor?) {
        self.init(fillColor: fillColor, cornerRadius: 0)
    }

    /// 在合法的 UTF-16 范围内写入背景，越界或空范围保持原文本。跨行时每行各画一段。
    @objc public func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.location >= 0, range.location <= text.length,
              range.length > 0, range.length <= text.length - range.location else { return }
        text.addAttribute(Self.attributeName, value: self, range: range)
    }

    /// 生成颜色已按给定外观解析的独立副本，供后台排版线程只读使用。
    func resolved(with traits: UITraitCollection) -> TextForgeBackground {
        let copy = TextForgeBackground(fillColor: fillColor?.resolvedColor(with: traits), cornerRadius: cornerRadius)
        copy.strokeColor = strokeColor?.resolvedColor(with: traits)
        copy.strokeWidth = strokeWidth
        copy.insets = insets
        return copy
    }

    /// 在当前图形上下文中按配置填充并描边一段矩形。
    func draw(in rect: CGRect) {
        let area = rect.inset(by: insets)
        guard area.width > 0, area.height > 0 else { return }
        if let fillColor {
            fillColor.setFill()
            UIBezierPath(roundedRect: area, cornerRadius: cornerRadius).fill()
        }
        if let strokeColor, strokeWidth > 0 {
            let half = strokeWidth / 2
            let path = UIBezierPath(roundedRect: area.insetBy(dx: half, dy: half), cornerRadius: max(0, cornerRadius - half))
            path.lineWidth = strokeWidth
            strokeColor.setStroke()
            path.stroke()
        }
    }
}
