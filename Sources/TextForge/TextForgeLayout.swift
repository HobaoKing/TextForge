import UIKit

/// 可在主线程复用的度量和绘制结果。输入宽高及内边距均使用点。
@MainActor
@objc(TextForgeLayout)
public final class TextForgeLayout: NSObject {
    @objc public let attributedText: NSAttributedString
    @objc public let textBoundingSize: CGSize

    let size: CGSize
    let insets: UIEdgeInsets
    let maximumNumberOfRows: Int
    let lineBreakMode: NSLineBreakMode
    private let engine: TextForgeLayoutEngine
    private let preparedImage: UIImage?
    private let preparedTraits: UITraitCollection?

    /// 按给定边界同步排版，行数为 0 表示不限行。返回的尺寸包含内边距。
    @objc public convenience init(
        attributedText: NSAttributedString,
        size: CGSize,
        insets: UIEdgeInsets,
        maximumNumberOfRows: Int,
        lineBreakMode: NSLineBreakMode
    ) {
        let engine = TextForgeLayoutEngine(
            attributedText: attributedText, size: size, insets: insets,
            maximumNumberOfRows: maximumNumberOfRows, lineBreakMode: lineBreakMode
        )
        self.init(
            attributedText: attributedText, size: size, insets: insets,
            maximumNumberOfRows: maximumNumberOfRows, lineBreakMode: lineBreakMode,
            engine: engine, preparedImage: nil, preparedTraits: nil
        )
    }

    /// 接管已排好的引擎，关联原始交互文本；可选位图仅用于常态绘制。
    init(
        attributedText: NSAttributedString, size: CGSize, insets: UIEdgeInsets,
        maximumNumberOfRows: Int, lineBreakMode: NSLineBreakMode,
        engine: TextForgeLayoutEngine, preparedImage: UIImage?, preparedTraits: UITraitCollection?
    ) {
        self.attributedText = NSAttributedString(attributedString: attributedText)
        self.size = size
        self.insets = insets
        self.maximumNumberOfRows = max(0, maximumNumberOfRows)
        self.lineBreakMode = lineBreakMode
        self.engine = engine
        self.preparedImage = preparedImage
        self.preparedTraits = preparedTraits
        textBoundingSize = engine.textBoundingSize
        super.init()
    }

    /// 后台结果中的动态色已解析，换外观时需要从原始富文本重新生成。
    func matchesAppearance(_ traits: UITraitCollection) -> Bool {
        guard let preparedTraits else { return true }
        return !traits.hasDifferentColorAppearance(comparedTo: preparedTraits)
    }

    /// 常态可直接贴用已准备的位图，高亮时用同一字形布局绘制状态样式。
    func draw(at origin: CGPoint, activeRange: NSRange?, activeBackground: UIColor?, activeForeground: UIColor?) {
        if activeRange == nil, let preparedImage {
            preparedImage.draw(at: CGPoint(x: origin.x - insets.left, y: origin.y - insets.top))
        } else {
            engine.draw(at: origin, activeRange: activeRange, activeBackground: activeBackground, activeForeground: activeForeground)
        }
    }

    func character(at point: CGPoint) -> Int? { engine.character(at: point) }

    func rect(for range: NSRange) -> CGRect { engine.rect(for: range) }

    var visibleCharacterRange: NSRange? { engine.visibleCharacterRange }

    func visibleCharacter(atOrAfter index: Int, in range: NSRange) -> Int? {
        engine.visibleCharacter(atOrAfter: index, in: range)
    }

    /// 将当前字形的基线与原始 UIKit 附件配对，仅在主线程读取和挂载视图。
    func viewAttachments() -> [(UIView, CGRect)] {
        guard let range = engine.visibleCharacterRange else { return [] }
        var result: [(UIView, CGRect)] = []
        attributedText.enumerateAttribute(.attachment, in: range) { value, segment, _ in
            guard let attachment = value as? TextForgeViewAttachment,
                  let baseline = engine.baselineForAttachment(at: segment.location) else { return }
            let bounds = attachment.bounds
            let nativeSize = attachment.viewSize
            let contentSize = nativeSize.width > 0 && nativeSize.height > 0 ? nativeSize : bounds.size
            result.append((attachment.view, CGRect(
                x: baseline.x + bounds.midX - contentSize.width / 2,
                y: baseline.y - bounds.midY - contentSize.height / 2,
                width: contentSize.width,
                height: contentSize.height
            )))
        }
        return result
    }
}

/// 独占一套 TextKit 对象。调用方在所属线程使用，后台任务完成后可一次性交给主线程。
final class TextForgeLayoutEngine {
    let textBoundingSize: CGSize
    private let attributedText: NSAttributedString
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private let glyphs: NSRange

    /// 创建独立的排版栈并计算实际字形区域，零尺寸保留空结果。
    init(
        attributedText: NSAttributedString,
        size: CGSize,
        insets: UIEdgeInsets,
        maximumNumberOfRows: Int,
        lineBreakMode: NSLineBreakMode
    ) {
        self.attributedText = NSAttributedString(attributedString: attributedText)
        let layoutText = Self.wrappingText(attributedText, maximumNumberOfRows: maximumNumberOfRows)
        storage = NSTextStorage(attributedString: layoutText)
        let width = Self.containerDimension(size.width, minus: insets.left + insets.right)
        let height = Self.containerDimension(size.height, minus: insets.top + insets.bottom)
        container = NSTextContainer(size: CGSize(width: width, height: height))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = max(0, maximumNumberOfRows)
        // UILabel 的不限行模式仍需折行。截断交给有行数或高度限制的容器处理。
        if maximumNumberOfRows == 0, size.height >= 1_000_000, Self.truncates(lineBreakMode) {
            container.lineBreakMode = .byWordWrapping
        } else {
            container.lineBreakMode = lineBreakMode
        }
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        if width > 0, height > 0, attributedText.length > 0 {
            manager.ensureLayout(for: container)
            glyphs = manager.glyphRange(for: container)
            let usedRect = manager.usedRect(for: container)
            textBoundingSize = CGSize(
                width: ceil(usedRect.width) + insets.left + insets.right,
                height: ceil(usedRect.height) + insets.top + insets.bottom
            )
        } else {
            glyphs = NSRange(location: 0, length: 0)
            textBoundingSize = .zero
        }
    }

    /// 使用同一份排版对象绘制背景和字形，临时按压前景色在绘制后恢复。
    func draw(at origin: CGPoint, activeRange: NSRange?, activeBackground: UIColor?, activeForeground: UIColor?) {
        guard glyphs.length > 0 else { return }
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        if let activeRange, let activeBackground {
            activeBackground.setFill()
            let selectedGlyphs = manager.glyphRange(forCharacterRange: activeRange, actualCharacterRange: nil)
            let visibleSelection = NSIntersectionRange(selectedGlyphs, glyphs)
            if visibleSelection.length > 0 {
                manager.enumerateEnclosingRects(
                    forGlyphRange: visibleSelection,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    UIBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
                }
            }
        }
        if let activeRange, let activeForeground {
            storage.addAttribute(.foregroundColor, value: activeForeground, range: activeRange)
        }
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        if let activeRange, activeForeground != nil {
            storage.beginEditing()
            attributedText.enumerateAttribute(.foregroundColor, in: activeRange) { value, range, _ in
                if let value {
                    storage.addAttribute(.foregroundColor, value: value, range: range)
                } else {
                    storage.removeAttribute(.foregroundColor, range: range)
                }
            }
            storage.endEditing()
        }
    }

    /// 将 TextKit 的最近字形查找约束在实际字形中，排除行尾空白与被截断的原文字形。
    func character(at point: CGPoint) -> Int? {
        guard glyphs.length > 0 else { return nil }
        let glyph = manager.glyphIndex(for: point, in: container)
        guard isVisible(glyph),
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else {
            return nil
        }
        let index = manager.characterIndexForGlyph(at: glyph)
        return index < attributedText.length ? index : nil
    }

    /// 将 UTF-16 范围的字形边界换算成文本容器中的矩形。
    func rect(for range: NSRange) -> CGRect {
        let selected = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: NSIntersectionRange(selected, glyphs), in: container)
    }

    /// 字形覆盖的 UTF-16 范围，生成附件和可访问动作时仍须排除末行截断。
    var visibleCharacterRange: NSRange? {
        guard glyphs.length > 0 else { return nil }
        return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// 查找某段语义范围内第一个实际可见的字符，截断隐藏的链接不会获得辅助动作。
    func visibleCharacter(atOrAfter index: Int, in range: NSRange) -> Int? {
        guard let visibleCharacterRange else { return nil }
        let visible = NSIntersectionRange(visibleCharacterRange, range)
        guard max(index, visible.location) < NSMaxRange(visible) else { return nil }
        return (max(index, visible.location)..<NSMaxRange(visible)).first {
            isVisible(manager.glyphIndexForCharacter(at: $0))
        }
    }

    /// 返回可见附件对应的行基线坐标，不读取 UIKit 视图。
    func baselineForAttachment(at index: Int) -> CGPoint? {
        let glyph = manager.glyphIndexForCharacter(at: index)
        guard isVisible(glyph) else { return nil }
        let location = manager.location(forGlyphAt: glyph)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGPoint(x: fragment.minX + location.x, y: fragment.minY + location.y)
    }

    /// 按内容尺寸生成透明位图，像素超出单条文本预算时保留排版结果供同步绘制。
    func rasterize(scale: CGFloat, traits: UITraitCollection, viewport: CGSize, insets: UIEdgeInsets) -> UIImage? {
        guard glyphs.length > 0, scale.isFinite, scale > 0 else { return nil }
        let used = manager.usedRect(for: container)
        let naturalWidth = ceil(used.maxX) + insets.left + insets.right
        let naturalHeight = ceil(used.maxY) + insets.top + insets.bottom
        let size = CGSize(
            width: viewport.width < 1_000_000 ? viewport.width : naturalWidth,
            height: viewport.height < 1_000_000 ? viewport.height : naturalHeight
        )
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = ceil(size.width * scale) * ceil(size.height * scale)
        guard pixels <= 1_000_000 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var image: UIImage?
        traits.performAsCurrent {
            image = renderer.image { _ in
                draw(
                    at: CGPoint(x: insets.left, y: insets.top),
                    activeRange: nil, activeBackground: nil, activeForeground: nil
                )
            }
        }
        return image
    }

    /// 排除容器外或末行截断替换掉的字形。
    private func isVisible(_ glyph: Int) -> Bool {
        guard NSLocationInRange(glyph, glyphs) else { return false }
        let truncated = manager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)
        return truncated.location == NSNotFound || !NSLocationInRange(glyph, truncated)
    }

    /// 避免将无界尺寸直接交给 TextKit，零尺寸时也保持有效容器。
    private static func containerDimension(_ value: CGFloat, minus inset: CGFloat) -> CGFloat {
        if value.isNaN { return 0 }
        return max(0, min(value - inset, 1_000_000))
    }

    /// 富文本段落先正常折行，再由容器决定最后一行如何截断。
    private static func wrappingText(_ text: NSAttributedString, maximumNumberOfRows: Int) -> NSAttributedString {
        guard maximumNumberOfRows != 1 else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  truncates(style.lineBreakMode),
                  let wrapping = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            wrapping.lineBreakMode = .byWordWrapping
            result.addAttribute(.paragraphStyle, value: wrapping, range: range)
        }
        return result
    }

    /// 识别 Unicode 省略号策略，普通折行和裁切保留原行为。
    private static func truncates(_ mode: NSLineBreakMode) -> Bool {
        mode == .byTruncatingHead || mode == .byTruncatingMiddle || mode == .byTruncatingTail
    }
}
