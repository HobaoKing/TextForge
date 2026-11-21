import UIKit

/// 导入时的阅读样式。未设置的属性沿用文档；作者的显式 CSS 优先于阅读默认值。
@MainActor
@objc(TextForgeHTMLReadingStyle)
public final class TextForgeHTMLReadingStyle: NSObject {
    @objc public var defaultFont: UIFont?
    @objc public var textColor: UIColor?
    @objc public var linkColor: UIColor?
    /// nil 沿用文档，true/false 分别指定链接默认有/无下划线。
    @objc public var underlinesLinks: NSNumber?
    /// 图片最大显示宽度（点）；0 表示沿用原尺寸。
    @objc public var maximumImageWidth: CGFloat = 0
    /// 宿主图片缺少尺寸时的临时占位（点）。加载成功后按原图比例重排。
    @objc public var placeholderSize = CGSize(width: 24, height: 24)
    @objc public var placeholderImage: UIImage?

    /// 使用零优先级选择器，在作者样式之前加入默认规则。动态颜色按发起导入时的外观解析。
    var stylesheet: String {
        var body: [String] = [], link: [String] = []
        if let font = defaultFont {
            let family = font.familyName.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
            let familyName = font.familyName.hasPrefix(".") ? "-apple-system" : "'\(family)'"
            // 固定阅读字号时关闭 WebKit 的窄栏文字放大；作者仍可用自己的规则覆盖。
            body.append("-webkit-text-size-adjust:none;font-family:\(familyName);font-size:\(font.pointSize)px")
            if let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any],
               let weight = traits[.weight] as? NSNumber {
                let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
                let nearest = weights.indices.min {
                    abs(weights[$0].rawValue - weight.doubleValue) < abs(weights[$1].rawValue - weight.doubleValue)
                } ?? 3
                body.append("font-weight:\((nearest + 1) * 100)")
            } else if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                body.append("font-weight:bold")
            }
            if font.fontDescriptor.symbolicTraits.contains(.traitItalic) { body.append("font-style:italic") }
        }
        if let textColor, let color = Self.cssColor(textColor) { body.append("color:" + color) }
        if let linkColor, let color = Self.cssColor(linkColor) { link.append("color:" + color) }
        if let underlinesLinks { link.append("text-decoration:" + (underlinesLinks.boolValue ? "underline" : "none")) }
        return (body.isEmpty ? "" : ":where(body){\(body.joined(separator: ";"))}") +
            (link.isEmpty ? "" : ":where(a:link){\(link.joined(separator: ";"))}")
    }

    /// 将 UIKit 颜色转换成带透明度的 CSS 值，图案色等不可转换的颜色沿用文档。
    private static func cssColor(_ color: UIColor) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return "rgba(\(r * 255),\(g * 255),\(b * 255),\(a))"
    }
}
