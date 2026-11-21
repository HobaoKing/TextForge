import CoreText
import UIKit

/// 排版用的值参数。路径在主线程复制后，可随后台任务整体交接。
struct TextForgeLayoutParameters {
    var size: CGSize
    var insets: UIEdgeInsets
    var maximumNumberOfRows: Int
    var lineBreakMode: NSLineBreakMode
    var exclusionPaths: [UIBezierPath]
}

/// 按压时临时叠加的样式，范围使用排版串的下标。
struct TextForgeActiveStyle {
    var range: NSRange
    var background: TextForgeBackground?
    var foreground: UIColor?
}

/// 命中的字符。text 为原文下标，token 为截断标记内部的下标。
enum TextForgeHit: Equatable {
    case text(Int)
    case token(Int)
}

/// 引擎内部的一行，坐标以排版区左上角为原点。
struct TextForgeEngineLine {
    var range: NSRange
    var rect: CGRect
    var baseline: CGFloat
    var row: Int
}

/// 独占一套 TextKit 对象。调用方在所属线程使用，后台任务完成后可一次性交给主线程。
final class TextForgeLayoutEngine {
    /// 包含内边距和文字起始偏移的尺寸，把标签设成这个尺寸可以完整显示布局。
    let textBoundingSize: CGSize
    /// 去除对齐留白但保留段落缩进的尺寸，供标签自适应时重新排版。
    let fittingSize: CGSize
    /// 文字在排版区内占用的矩形。
    let usedRect: CGRect
    /// 内容超出行数或高度限制。
    let isTruncated: Bool
    /// 自定义截断标记在排版串中的范围。排版串为原文前缀加标记，nil 表示未使用自定义标记。
    let tokenRange: NSRange?
    private let sourceLength: Int
    /// 无界宽度下文字被排到远处时的横向平移量。对外的坐标都已减去它，传入的点会加回。
    private let shift: CGFloat
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private let glyphs: NSRange
    /// TextKit 未通过 truncatedGlyphRange 报告的头部或中部省略范围，包含替代省略号的字形位置。
    private let substitutedGlyphs: NSRange?

    /// 创建独立的排版栈并计算实际字形区域，零尺寸保留空结果。
    /// text 与 truncationToken 须已去掉 `.link`，后台使用时还须已分离主线程对象。
    init(text: NSAttributedString, truncationToken: NSAttributedString?, parameters: TextForgeLayoutParameters) {
        let insets = parameters.insets
        let rows = max(0, parameters.maximumNumberOfRows)
        sourceLength = text.length
        storage = NSTextStorage(attributedString: Self.wrappingText(text, maximumNumberOfRows: rows))
        let width = Self.containerDimension(parameters.size.width, minus: insets.left + insets.right)
        let height = Self.containerDimension(parameters.size.height, minus: insets.top + insets.bottom)
        container = NSTextContainer(size: CGSize(width: width, height: height))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = rows
        container.exclusionPaths = parameters.exclusionPaths
        // UILabel 的不限行模式仍需折行。截断交给有行数或高度限制的容器处理。
        if rows == 0, parameters.size.height >= 1_000_000, Self.truncates(parameters.lineBreakMode) {
            container.lineBreakMode = .byWordWrapping
        } else {
            container.lineBreakMode = parameters.lineBreakMode
        }
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        guard width > 0, height > 0, text.length > 0 else {
            glyphs = NSRange(location: 0, length: 0)
            usedRect = .zero
            shift = 0
            textBoundingSize = .zero
            fittingSize = .zero
            isTruncated = false
            tokenRange = nil
            substitutedGlyphs = nil
            return
        }
        manager.ensureLayout(for: container)
        let overflowed = Self.overflows(manager: manager, container: container, length: storage.length)
        var appliedToken: NSRange?
        if overflowed, parameters.lineBreakMode == .byTruncatingTail, let truncationToken, truncationToken.length > 0 {
            appliedToken = Self.applyTruncationToken(
                truncationToken, source: text, maximumNumberOfRows: rows,
                storage: storage, manager: manager, container: container
            )
        }
        let raw = manager.usedRect(for: container)
        // 无界宽度下居中、右对齐或从右到左的文字会排到几十万点之外。保留排版结果，只把坐标整体平移回原点，
        // 折行不受影响。阈值远大于任何合理缩进，左对齐文本的首行缩进仍然保留。
        shift = width >= 1_000_000 && raw.minX > 10_000 ? raw.minX : 0
        let used = raw.offsetBy(dx: -shift, dy: 0)
        glyphs = manager.glyphRange(for: container)
        substitutedGlyphs = Self.unreportedTruncation(in: glyphs, storage: storage, manager: manager, container: container)
        usedRect = used
        isTruncated = overflowed || substitutedGlyphs != nil
        tokenRange = appliedToken
        let boundingHeight = ceil(used.maxY) + insets.top + insets.bottom
        textBoundingSize = CGSize(width: ceil(used.maxX) + insets.left + insets.right, height: boundingHeight)
        if parameters.exclusionPaths.isEmpty {
            let fittingWidth = Self.fittingWidth(used.width, glyphs: glyphs, storage: storage, manager: manager)
            fittingSize = CGSize(width: ceil(fittingWidth) + insets.left + insets.right, height: boundingHeight)
        } else {
            // 排除路径会把文字推离左缘，缩窄后排版结构不再相同，保留完整宽度。
            fittingSize = textBoundingSize
        }
    }

    /// 计算去除对齐留白后的宽度。TextKit 的行片段起点不能区分缩进与对齐，按段落配置补回缩进。
    /// 只检查已排到容器内的文字。普通段落继续直接使用文字占用宽度。
    private static func fittingWidth(
        _ width: CGFloat, glyphs: NSRange, storage: NSTextStorage, manager: NSLayoutManager
    ) -> CGFloat {
        guard glyphs.length > 0 else { return width }
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var hasIndent = false
        storage.enumerateAttribute(.paragraphStyle, in: visible) { value, _, stop in
            if let style = value as? NSParagraphStyle,
               style.firstLineHeadIndent != 0 || style.headIndent != 0 || style.tailIndent < 0 {
                hasIndent = true
                stop.pointee = true
            }
        }
        guard hasIndent else { return width }
        let string = storage.string as NSString
        var fitting = width
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, line, _ in
            let index = manager.characterIndexForGlyph(at: line.location)
            guard index < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle else { return }
            let paragraphStart = string.paragraphRange(for: NSRange(location: index, length: 1)).location
            let leading = paragraphStart == index ? style.firstLineHeadIndent : style.headIndent
            fitting = max(fitting, used.width + max(0, leading) + max(0, -style.tailIndent))
        }
        return fitting
    }

    /// 依次绘制系统背景、圆角背景装饰、按压背景和字形。临时按压前景色在绘制后恢复。
    func draw(at origin: CGPoint, active: TextForgeActiveStyle?) {
        guard glyphs.length > 0 else { return }
        let glyphOrigin = CGPoint(x: origin.x - shift, y: origin.y)
        manager.drawBackground(forGlyphRange: glyphs, at: glyphOrigin)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(TextForgeBackground.attributeName, in: visible) { value, range, _ in
            guard let background = value as? TextForgeBackground else { return }
            for rect in runRects(for: range) { background.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        let activeRange = active.map { NSIntersectionRange($0.range, NSRange(location: 0, length: storage.length)) }
        if let active, let activeRange, let background = active.background {
            for rect in runRects(for: activeRange) { background.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        var original: NSAttributedString?
        if let active, let activeRange, activeRange.length > 0, let foreground = active.foreground {
            original = storage.attributedSubstring(from: activeRange)
            storage.addAttribute(.foregroundColor, value: foreground, range: activeRange)
        }
        manager.drawGlyphs(forGlyphRange: glyphs, at: glyphOrigin)
        if let original, let activeRange {
            storage.beginEditing()
            original.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                let target = NSRange(location: activeRange.location + range.location, length: range.length)
                if let value {
                    storage.addAttribute(.foregroundColor, value: value, range: target)
                } else {
                    storage.removeAttribute(.foregroundColor, range: target)
                }
            }
            storage.endEditing()
        }
    }

    /// 将 TextKit 的最近字形查找约束在实际字形中，排除行尾空白与被截断的原文字形。
    func hit(at point: CGPoint) -> TextForgeHit? {
        guard glyphs.length > 0 else { return nil }
        let point = CGPoint(x: point.x + shift, y: point.y)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard isVisible(glyph),
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else {
            return nil
        }
        let index = manager.characterIndexForGlyph(at: glyph)
        if let tokenRange, index >= tokenRange.location {
            return index < NSMaxRange(tokenRange) ? .token(index - tokenRange.location) : nil
        }
        return index < sourceLength ? .text(index) : nil
    }

    /// 把 UTF-16 查询范围裁到正文或标记可用的区间。无效位置返回空范围，长度先裁切再相加，避免整数溢出。
    func storageRange(for range: NSRange, inToken: Bool) -> NSRange {
        let available: NSRange
        if inToken {
            guard let tokenRange else { return NSRange(location: 0, length: 0) }
            available = tokenRange
        } else {
            available = NSRange(location: 0, length: tokenRange?.location ?? storage.length)
        }
        guard range.location >= 0, range.location < available.length, range.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(
            location: available.location + range.location,
            length: min(range.length, available.length - range.location)
        )
    }

    /// 排版串范围内可见字形的外接矩形，按行片段高度计算。范围不可见时返回 null。
    func boundingRect(for range: NSRange) -> CGRect {
        guard range.length > 0 else { return .null }
        let selected = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
        guard selected.length > 0 else { return .null }
        if !isTruncated {
            return manager.boundingRect(forGlyphRange: selected, in: container).offsetBy(dx: -shift, dy: 0)
        }
        var bounds = CGRect.null
        manager.enumerateLineFragments(forGlyphRange: selected) { _, _, _, line, _ in
            for part in self.visibleGlyphParts(of: NSIntersectionRange(line, selected)) {
                bounds = bounds.union(self.manager.boundingRect(forGlyphRange: part, in: self.container))
            }
        }
        return bounds.isNull ? .null : bounds.offsetBy(dx: -shift, dy: 0)
    }

    /// 排版串范围在每个行片段上的排版矩形：横向取字形外接范围，纵向取基线上下的字体升部与降部，
    /// 不含行距。背景装饰、按压反馈和触摸距离都使用这组矩形。
    func runRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let selected = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
        guard selected.length > 0 else { return [] }
        var result: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: selected) { fragment, _, _, lineGlyphs, _ in
            for part in self.visibleGlyphParts(of: NSIntersectionRange(lineGlyphs, selected)) {
                let bounds = self.manager.boundingRect(forGlyphRange: part, in: self.container).offsetBy(dx: -self.shift, dy: 0)
                let baseline = fragment.minY + self.manager.location(forGlyphAt: part.location).y
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let characters = self.manager.characterRange(forGlyphRange: part, actualGlyphRange: nil)
                self.storage.enumerateAttributes(in: characters) { attributes, _, _ in
                    if let attachment = attributes[.attachment] as? NSTextAttachment, !attachment.bounds.isEmpty {
                        ascent = max(ascent, attachment.bounds.maxY)
                        descent = min(descent, attachment.bounds.minY)
                    } else if let font = attributes[.font] as? UIFont {
                        ascent = max(ascent, font.ascender)
                        descent = min(descent, font.descender)
                    }
                }
                if ascent - descent > 0 {
                    result.append(CGRect(x: bounds.minX, y: baseline - ascent, width: bounds.width, height: ascent - descent))
                } else {
                    result.append(bounds)
                }
            }
        }
        return result
    }

    /// 可见原文的 UTF-16 外接范围，头部和中部截断的区间内部可能有隐藏字形。没有可见原文时为 nil。
    var visibleCharacterRange: NSRange? {
        guard glyphs.length > 0 else { return nil }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lower = characters.location
        var upper = min(NSMaxRange(characters), tokenRange?.location ?? sourceLength)
        if let hidden = omittedGlyphs(inLineAt: NSMaxRange(glyphs) - 1) {
            if NSMaxRange(hidden) >= NSMaxRange(glyphs) {
                upper = min(upper, manager.characterIndexForGlyph(at: hidden.location))
            }
            if hidden.location == glyphs.location, NSMaxRange(hidden) < NSMaxRange(glyphs) {
                lower = max(lower, manager.characterIndexForGlyph(at: NSMaxRange(hidden)))
            }
        }
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    /// 返回语义范围中第一个实际可见的 UTF-16 下标。inToken 为 true 时，入参与返回值均相对截断标记。
    func firstVisibleCharacter(in range: NSRange, inToken: Bool) -> Int? {
        guard glyphs.length > 0 else { return nil }
        let laidOut = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = NSIntersectionRange(storageRange(for: range, inToken: inToken), laidOut)
        let index = (visible.location..<NSMaxRange(visible)).first {
            isVisible(manager.glyphIndexForCharacter(at: $0))
        }
        let offset = inToken ? (tokenRange?.location ?? 0) : 0
        return index.map { $0 - offset }
    }

    /// 返回可见附件对应的行基线坐标，不读取 UIKit 视图。
    func baselineForAttachment(at index: Int) -> CGPoint? {
        let glyph = manager.glyphIndexForCharacter(at: index)
        guard isVisible(glyph) else { return nil }
        let location = manager.location(forGlyphAt: glyph)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGPoint(x: fragment.minX + location.x - shift, y: fragment.minY + location.y)
    }

    /// 逐个行片段给出可见原文的外接范围、占用矩形和基线，标记占用空间但不计入原文范围。
    func lines() -> [TextForgeEngineLine] {
        guard glyphs.length > 0 else { return [] }
        let limit = tokenRange?.location ?? sourceLength
        var result: [TextForgeEngineLine] = []
        var row = -1
        var previousY = -CGFloat.greatestFiniteMagnitude
        manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, self.glyphs)
            guard part.length > 0 else { return }
            if fragment.minY > previousY + 0.5 {
                row += 1
                previousY = fragment.minY
            }
            let visibleParts = self.visibleGlyphParts(of: part)
            var characters = NSRange(location: self.manager.characterIndexForGlyph(at: part.location), length: 0)
            if let first = visibleParts.first, let last = visibleParts.last {
                let lower = self.manager.characterRange(forGlyphRange: first, actualGlyphRange: nil)
                let upper = self.manager.characterRange(forGlyphRange: last, actualGlyphRange: nil)
                characters = NSUnionRange(lower, upper)
            }
            let upper = min(NSMaxRange(characters), limit)
            let lower = min(characters.location, upper)
            result.append(TextForgeEngineLine(
                range: NSRange(location: lower, length: upper - lower), rect: used.offsetBy(dx: -self.shift, dy: 0),
                baseline: fragment.minY + self.manager.location(forGlyphAt: part.location).y, row: row
            ))
        }
        return result
    }

    /// 按内容尺寸生成透明位图，像素超出单条文本预算时保留排版结果供同步绘制。
    func rasterize(scale: CGFloat, traits: UITraitCollection, viewport: CGSize, insets: UIEdgeInsets) -> UIImage? {
        guard glyphs.length > 0, scale.isFinite, scale > 0 else { return nil }
        let size = CGSize(
            width: viewport.width < 1_000_000 ? viewport.width : textBoundingSize.width,
            height: viewport.height < 1_000_000 ? viewport.height : textBoundingSize.height
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
                draw(at: CGPoint(x: insets.left, y: insets.top), active: nil)
            }
        }
        return image
    }

    /// 排除容器外或末行截断替换掉的字形。
    private func isVisible(_ glyph: Int) -> Bool {
        guard NSLocationInRange(glyph, glyphs) else { return false }
        guard let omitted = omittedGlyphs(inLineAt: glyph) else { return true }
        return !NSLocationInRange(glyph, omitted)
    }

    /// 从同一行片段中剔除 TextKit 以省略号代替的字形。中部截断可能留下前后两段。
    private func visibleGlyphParts(of range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [] }
        guard isTruncated, let hidden = omittedGlyphs(inLineAt: range.location) else { return [range] }
        let omitted = NSIntersectionRange(range, hidden)
        guard omitted.length > 0 else { return [range] }
        var parts: [NSRange] = []
        if range.location < omitted.location {
            parts.append(NSRange(location: range.location, length: omitted.location - range.location))
        }
        if NSMaxRange(omitted) < NSMaxRange(range) {
            parts.append(NSRange(location: NSMaxRange(omitted), length: NSMaxRange(range) - NSMaxRange(omitted)))
        }
        return parts
    }

    /// 优先使用 TextKit 公布的省略范围，只在系统没有报告时使用已识别的头部或中部省略范围。
    private func omittedGlyphs(inLineAt glyph: Int) -> NSRange? {
        let reported = manager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)
        return reported.location == NSNotFound ? substitutedGlyphs : reported
    }

    /// TextKit 可能用一个真实省略号字形加一串隐藏空字形表示头部或中部截断，却不报告截断范围。
    /// 仅扫描最后的行片段。按该处字体确认省略号，并要求后续隐藏字形覆盖其它字素，避免误判正常的组合字符。
    private static func unreportedTruncation(
        in glyphs: NSRange, storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer
    ) -> NSRange? {
        guard container.lineBreakMode == .byTruncatingHead || container.lineBreakMode == .byTruncatingMiddle,
              glyphs.length > 1 else { return nil }
        let last = NSMaxRange(glyphs) - 1
        guard manager.truncatedGlyphRange(inLineFragmentForGlyphAt: last).location == NSNotFound else { return nil }
        var fragment = NSRange()
        _ = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: &fragment)
        let line = NSIntersectionRange(glyphs, fragment)
        guard line.length > 1 else { return nil }
        let string = storage.string as NSString
        let limit = NSMaxRange(line)
        for glyph in line.location..<(limit - 1) where manager.glyph(at: glyph + 1) == 0 {
            guard !manager.notShownAttribute(forGlyphAt: glyph), manager.notShownAttribute(forGlyphAt: glyph + 1) else { continue }
            let index = manager.characterIndexForGlyph(at: glyph)
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: UIFont.systemFontSize)
            let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
            let fallbackFont = CTFontCreateForString(ctFont, "…" as CFString, CFRange(location: 0, length: 1))
            var ellipsis = UniChar(0x2026)
            var ellipsisGlyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(fallbackFont, &ellipsis, &ellipsisGlyph, 1),
                  manager.glyph(at: glyph) == ellipsisGlyph else { continue }
            var end = glyph + 1
            while end < limit, manager.glyph(at: end) == 0, manager.notShownAttribute(forGlyphAt: end) { end += 1 }
            let lastHidden = manager.characterIndexForGlyph(at: end - 1)
            if lastHidden >= NSMaxRange(string.rangeOfComposedCharacterSequence(at: index)) {
                return NSRange(location: glyph, length: end - glyph)
            }
        }
        return nil
    }

    /// 容器是否没能放下全部内容：后续段落整段落在容器外，或末行被系统省略号截断。
    private static func overflows(manager: NSLayoutManager, container: NSTextContainer, length: Int) -> Bool {
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return length > 0 }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if NSMaxRange(characters) < length { return true }
        return manager.truncatedGlyphRange(inLineFragmentForGlyphAt: NSMaxRange(glyphs) - 1).location != NSNotFound
    }

    /// 把末行尾部替换成自定义截断标记，返回标记在排版串中的范围。
    /// 先用单行试排在末行内二分出能容纳"正文 + 标记"的最长前缀，再用真实容器复核；
    /// 缩进或排除路径使复核仍溢出时逐字回退。标记比整行还宽时放在行首，由容器裁切。
    private static func applyTruncationToken(
        _ token: NSAttributedString, source: NSAttributedString, maximumNumberOfRows: Int,
        storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer
    ) -> NSRange? {
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let lastGlyph = NSMaxRange(glyphs) - 1
        var lineGlyphs = NSRange(location: 0, length: 0)
        let fragment = manager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &lineGlyphs)
        let lineCharacters = manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let hidden = manager.truncatedGlyphRange(inLineFragmentForGlyphAt: lastGlyph)
        let lineStart = lineCharacters.location
        let visibleEnd = min(
            hidden.location == NSNotFound ? NSMaxRange(lineCharacters) : manager.characterIndexForGlyph(at: hidden.location),
            source.length
        )
        let string = source.string as NSString
        // 只在字素边界截断，避免拆开表情或组合字符。
        var boundaries = [lineStart]
        var index = lineStart
        while index < visibleEnd {
            index = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
            if index <= visibleEnd { boundaries.append(index) }
        }
        let blanks = CharacterSet.whitespacesAndNewlines
        // 截断点前的空白和换行不保留，标记紧跟最后一个可见字。
        let trimmedEnd: (Int) -> Int = { boundary in
            var end = boundary
            while end > lineStart, let scalar = Unicode.Scalar(string.character(at: end - 1)), blanks.contains(scalar) {
                end -= 1
            }
            return end
        }
        // 标记缺少的字体、颜色和段落样式沿用紧邻的正文，保证与末行同一基线和对齐。
        let inheritedToken: (Int) -> NSAttributedString = { end in
            let base = end > lineStart ? end - 1 : min(end, source.length - 1)
            let attributes = source.attributes(at: base, effectiveRange: nil)
            let result = NSMutableAttributedString(attributedString: token)
            token.enumerateAttributes(in: NSRange(location: 0, length: token.length)) { existing, range, _ in
                for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] where existing[key] == nil {
                    if let value = attributes[key] { result.addAttribute(key, value: value, range: range) }
                }
            }
            return result
        }
        let probeStorage = NSTextStorage()
        let probeManager = NSLayoutManager()
        let probeContainer = NSTextContainer(size: CGSize(width: 1_000_000, height: 1_000_000))
        probeContainer.lineFragmentPadding = 0
        probeManager.addTextContainer(probeContainer)
        probeStorage.addLayoutManager(probeManager)
        let fits: (Int) -> Bool = { candidate in
            let end = trimmedEnd(boundaries[candidate])
            let piece = NSMutableAttributedString(
                attributedString: source.attributedSubstring(from: NSRange(location: lineStart, length: end - lineStart))
            )
            piece.append(inheritedToken(end))
            piece.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: piece.length))
            probeStorage.setAttributedString(piece)
            probeManager.ensureLayout(for: probeContainer)
            return probeManager.usedRect(for: probeContainer).width <= fragment.width + 0.01
        }
        var choice = 0
        var upper = boundaries.count - 1
        while choice < upper {
            let middle = (choice + upper + 1) / 2
            if fits(middle) { choice = middle } else { upper = middle - 1 }
        }
        while true {
            let end = trimmedEnd(boundaries[choice])
            let piece = wrappingText(inheritedToken(end), maximumNumberOfRows: maximumNumberOfRows)
            storage.replaceCharacters(in: NSRange(location: end, length: storage.length - end), with: piece)
            manager.ensureLayout(for: container)
            if choice == 0 || !overflows(manager: manager, container: container, length: storage.length) {
                return NSRange(location: end, length: piece.length)
            }
            choice -= 1
        }
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
