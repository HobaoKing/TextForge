import CoreText
import UIKit

/// 排版用的值参数。路径在主线程复制后，可随后台任务整体交接。
struct TextForgeLayoutParameters {
    var size: CGSize
    var insets: UIEdgeInsets
    var maximumNumberOfRows: Int
    var lineBreakMode: NSLineBreakMode
    var minimumScaleFactor: CGFloat
    var fixedLineHeight: CGFloat = 0
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
    /// 自定义截断标记在内部排版串中的范围，nil 表示未使用；公开查询会换算为原文或标记的下标。
    let tokenRange: NSRange?
    private(set) var rasterOrigin: CGPoint = .zero
    private lazy var inkBounds = measureInkBounds()
    /// 仅在末行发生回流时插入的软换行位置，以排版串为坐标；原文与标记均不含此字符。
    private let insertedBreak: Int?
    private let sourceLength: Int
    /// 无界宽度下文字被排到远处时的横向平移量。对外的坐标都已减去它，传入的点会加回。
    private let shift: CGFloat
    private let storage: NSTextStorage
    private let manager: NSLayoutManager
    private let container: NSTextContainer
    private let clippedGlyphs: IndexSet
    private let glyphs: NSRange
    /// TextKit 未通过 truncatedGlyphRange 报告的头部或中部省略范围，包含替代省略号的字形位置。
    private let substitutedGlyphs: NSRange?
    private let lineLock: TextForgeLayoutDelegate?

    /// 创建独立的排版栈并计算实际字形区域，零尺寸保留空结果。
    /// 尾段更新只接管标签独占的旧栈，保留相同段落之前的字形和行缓存。
    /// text 与 truncationToken 须已去掉 `.link`，后台使用时还须已分离主线程对象。
    init(text: NSAttributedString, truncationToken: NSAttributedString?, parameters: TextForgeLayoutParameters,
         reusing previous: TextForgeLayoutEngine? = nil, unchangedPrefix: Int = 0) {
        let insets = parameters.insets
        let rows = max(0, parameters.maximumNumberOfRows)
        sourceLength = text.length
        let wrapped = Self.wrappingText(text, maximumNumberOfRows: rows, mode: parameters.lineBreakMode)
        let width = Self.containerDimension(parameters.size.width, minus: insets.left + insets.right)
        let height = Self.containerDimension(parameters.size.height, minus: insets.top + insets.bottom)
        var layoutDelegate: TextForgeLayoutDelegate?
        if parameters.fixedLineHeight > 0 {
            let delegate = TextForgeLayoutDelegate()
            delegate.fixedLineHeight = parameters.fixedLineHeight
            layoutDelegate = delegate
        }
        if let previous {
            storage = previous.storage
            manager = previous.manager
            container = previous.container
            manager.delegate = layoutDelegate
            container.size = CGSize(width: width, height: height)
            let oldRange = NSRange(location: unchangedPrefix, length: storage.length - unchangedPrefix)
            let newRange = NSRange(location: unchangedPrefix, length: wrapped.length - unchangedPrefix)
            if oldRange.length > 0 || newRange.length > 0 {
                storage.replaceCharacters(in: oldRange, with: wrapped.attributedSubstring(from: newRange))
            }
        } else {
            storage = NSTextStorage(attributedString: wrapped)
            manager = NSLayoutManager()
            manager.delegate = layoutDelegate
            container = NSTextContainer(size: CGSize(width: width, height: height))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = rows
            container.exclusionPaths = parameters.exclusionPaths
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }
        // 复用栈时可从有限高切换为无界高；两条路径均按新约束选择容器末行策略。
        container.lineBreakMode = rows == 0 && parameters.size.height >= 1_000_000 && Self.truncates(parameters.lineBreakMode)
            ? .byWordWrapping : parameters.lineBreakMode
        guard width > 0, height > 0, text.length > 0 else {
            clippedGlyphs = []
            glyphs = NSRange(location: 0, length: 0)
            usedRect = .zero
            shift = 0
            textBoundingSize = .zero
            fittingSize = .zero
            isTruncated = false
            tokenRange = nil
            insertedBreak = nil
            substitutedGlyphs = nil
            lineLock = nil
            return
        }
        if rows == 1, parameters.minimumScaleFactor < 1 {
            Self.fitFonts(in: storage, manager: manager, container: container, minimumScale: parameters.minimumScaleFactor)
        }
        manager.ensureLayout(for: container)
        let overflowed = Self.overflows(manager: manager, container: container, length: storage.length)
        var appliedToken: NSRange?
        var breakIndex: Int?
        if overflowed, parameters.lineBreakMode == .byTruncatingTail, let truncationToken, truncationToken.length > 0 {
            let applied = Self.applyTruncationToken(
                truncationToken, source: NSAttributedString(attributedString: storage), maximumNumberOfRows: rows,
                storage: storage, manager: manager, container: container, existingDelegate: layoutDelegate
            )
            appliedToken = applied?.range
            breakIndex = applied?.insertedBreak
            if let lock = applied?.lock { layoutDelegate = lock }
        }
        insertedBreak = breakIndex
        lineLock = layoutDelegate
        let raw = manager.usedRect(for: container)
        // 无界宽度下居中、右对齐或从右到左的文字会排到几十万点之外。保留排版结果，只把坐标整体平移回原点，
        // 折行不受影响。阈值远大于任何合理缩进，左对齐文本的首行缩进仍然保留。
        shift = width >= 1_000_000 && raw.minX > 10_000 ? raw.minX : 0
        let used = raw.offsetBy(dx: -shift, dy: 0)
        glyphs = manager.glyphRange(for: container)
        let clipping = Self.clippingInfo(manager: manager, container: container, storage: storage)
        clippedGlyphs = clipping.hidden
        substitutedGlyphs = Self.unreportedTruncation(in: glyphs, storage: storage, manager: manager, container: container)
        usedRect = used
        isTruncated = overflowed || substitutedGlyphs != nil || clipping.overflows
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

    /// 只在单行确实放不下时等比缩小各段字体。用同一容器试排，保留附件尺寸、字距、缩进与命中坐标。
    /// 强制换行后的内容仍按原策略截断，不能因为后续段落而把第一行缩到最小。
    private static func fitFonts(
        in storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, minimumScale: CGFloat
    ) {
        let source = NSAttributedString(attributedString: storage)
        let firstBreak = (source.string as NSString).rangeOfCharacter(from: .newlines)
        let sample = firstBreak.location == NSNotFound ? source :
            source.attributedSubstring(from: NSRange(location: 0, length: firstBreak.location))
        guard sample.length > 0 else { return }
        if firstBreak.location != NSNotFound { storage.setAttributedString(sample) }

        // 使用实际字形和系统报告的省略范围判定，兼容头部和中部截断。
        func fits() -> Bool {
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            return !overflows(manager: manager, container: container, length: storage.length)
                && manager.usedRect(for: container).width <= container.size.width + 0.01
                && !clippingInfo(manager: manager, container: container, storage: storage).overflows
                && unreportedTruncation(in: glyphs, storage: storage, manager: manager, container: container) == nil
        }
        // 每次从原始字体计算，避免多轮试排把字号累乘。
        func apply(_ factor: CGFloat, to original: NSAttributedString) {
            storage.setAttributedString(original)
            guard factor < 1 else { return }
            storage.beginEditing()
            original.enumerateAttribute(.font, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                let font = value as? UIFont ?? UIFont.systemFont(ofSize: 12)
                storage.addAttribute(.font, value: font.withSize(font.pointSize * factor), range: range)
            }
            storage.endEditing()
        }
        if fits() {
            if firstBreak.location != NSNotFound { storage.setAttributedString(source) }
            return
        }
        var low = max(1.0 / 1024, minimumScale)
        var high: CGFloat = 1
        apply(low, to: sample)
        if fits() {
            for _ in 0..<8 {
                let mid = (low + high) / 2
                apply(mid, to: sample)
                if fits() { low = mid } else { high = mid }
            }
        }
        apply(low, to: source)
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

    private var livePaintCharacters = IndexSet()

    /// 后台位图使用冻结颜色。引擎移交主线程后，仅当实际配色不符才把可见段换回动态绘制值。
    /// 每个范围最多安装一次，此后的绘制由当前 traits 解析，换肤无需反复编辑 NSTextStorage 或重排整段。
    @MainActor func applyPaint(_ paint: TextForgePaintPalette, traits: UITraitCollection, clip: CGRect,
                               activeBackground: TextForgeBackground?) {
        guard !paint.variants.isEmpty, !paint.matches(traits) else { return }
        let visibleGlyphs = drawingGlyphs(in: clip, activeBackground: activeBackground)
        guard visibleGlyphs.length > 0 else { return }
        let range = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let needed = range.location..<NSMaxRange(range)
        guard !livePaintCharacters.contains(integersIn: needed) else { return }
        let missing = IndexSet(integersIn: needed).subtracting(livePaintCharacters)
        storage.beginEditing()
        for part in missing.rangeView {
            for key in paint.variantKeys {
                storage.enumerateAttribute(TextForgePaintPalette.marker(for: key), in: NSRange(part)) { marker, run, _ in
                    guard let index = marker as? Int, paint.variants.indices.contains(index),
                          paint.variants[index].key == key else { return }
                    self.storage.addAttribute(key, value: paint.variants[index].liveValue, range: run)
                }
            }
        }
        storage.endEditing()
        livePaintCharacters.insert(integersIn: needed)
    }

    /// 用独立 TextKit 栈核对变化段的字形和基线；字体回退可能让增量结果的末行度量不同。
    func matchesFreshTail(_ text: NSAttributedString, from offset: Int, parameters: TextForgeLayoutParameters) -> Bool {
        guard !isTruncated, shift == 0, offset < text.length else { return false }
        let range = NSRange(location: offset, length: text.length - offset)
        let tailGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard tailGlyphs.length > 0, NSMaxRange(tailGlyphs) <= NSMaxRange(glyphs) else { return false }
        let first = manager.lineFragmentRect(forGlyphAt: tailGlyphs.location, effectiveRange: nil)
        var tailParameters = parameters
        tailParameters.size.height -= first.minY
        let fresh = TextForgeLayoutEngine(text: text.attributedSubstring(from: range), truncationToken: nil, parameters: tailParameters)
        guard !fresh.isTruncated, fresh.shift == 0, fresh.glyphs.length == tailGlyphs.length,
              ceil(first.minY + fresh.usedRect.maxY) == ceil(usedRect.maxY) else { return false }
        let expected = fresh.lines()
        var index = 0
        var matches = true
        manager.enumerateLineFragments(forGlyphRange: tailGlyphs) { fragment, used, _, glyphs, stop in
            let line = self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let baseline = self.baseline(forGlyphAt: glyphs.location, in: fragment)
            if index < expected.count {
                let target = expected[index]
                // 两个栈的纵向原点不同，消除浮点累计误差后比较局部几何。
                let delta: [CGFloat] = [used.minX - target.rect.minX, used.width - target.rect.width,
                                       used.height - target.rect.height, used.minY - first.minY - target.rect.minY,
                                       baseline - first.minY - target.baseline]
                matches = line.location == offset + target.range.location && line.length == target.range.length
                    && delta.allSatisfy { abs($0) < 0.01 }
            } else {
                matches = false
            }
            if !matches { stop.pointee = true }
            index += 1
        }
        return matches && index == expected.count
    }

    /// 默认垂直行距才能在高度别名和独立尾段校验中保持一致的段落边界。
    static func hasStandardLineMetrics(_ text: NSAttributedString, in range: NSRange) -> Bool {
        var standard = true
        text.enumerateAttribute(.paragraphStyle, in: range) { value, _, stop in
            guard let style = value as? NSParagraphStyle else { return }
            standard = style.lineSpacing == 0 && style.paragraphSpacing == 0 && style.paragraphSpacingBefore == 0
                && style.minimumLineHeight == 0 && style.maximumLineHeight == 0 && style.lineHeightMultiple == 0
            if !standard { stop.pointee = true }
        }
        return standard
    }

    /// 使用已排版文字核对缩短容器的边界。按段间距、定制行高或省略位置排版时交给目标约束重新测量。
    func supportsMeasuredHeight(lineBreakMode: NSLineBreakMode, height: CGFloat) -> Bool {
        guard glyphs.length > 0, lineBreakMode == .byWordWrapping || lineBreakMode == .byCharWrapping
                || lineBreakMode == .byTruncatingTail,
              container.lineBreakMode == lineBreakMode else { return false }
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard Self.hasStandardLineMetrics(storage, in: visible) else { return false }
        for key in [NSAttributedString.Key.attachment, .baselineOffset] {
            var hasOverride = false
            storage.enumerateAttribute(key, in: visible) { value, _, stop in
                if value != nil { hasOverride = true; stop.pointee = true }
            }
            if hasOverride { return false }
        }
        let last = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return last.maxY <= height
    }

    /// 后台提前计算局部绘制所需的外伸量，让从不预绘位图的长文也能直接绘制首屏。
    func prepareDrawingBounds() { if glyphs.length > 0 { _ = inkBounds } }

    /// 合并字形、斜体、偏移、阴影与圆角背景的墨迹范围；仅在实际存在装饰或斜体时按需外扩，避免普通文本预绘位图膨胀。
    private func measureInkBounds() -> CGRect {
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let base = usedRect.union(manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: -shift, dy: 0))
        var ink = base
        storage.enumerateAttributes(in: visible) { attributes, _, _ in
            let font = attributes[.font] as? UIFont
            let pointSize = font?.pointSize ?? 12
            let stroke = abs((attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) * pointSize / 100
            let isItalic = font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true
                || ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) != 0
            let horizontalOverhang = (isItalic ? pointSize * 0.5 : 0) + stroke
            let baseline = abs((attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0)
            let attachmentOverhang = (attributes[.attachment] as? NSTextAttachment).map { max(0, $0.bounds.height - pointSize) } ?? 0
            let verticalOverhang = stroke + baseline + attachmentOverhang
            var area = base.insetBy(dx: -horizontalOverhang, dy: -verticalOverhang)
            if let shadow = attributes[.shadow] as? NSShadow {
                let blur = 3 * max(0, shadow.shadowBlurRadius)
                area = area.union(area.offsetBy(dx: shadow.shadowOffset.width, dy: shadow.shadowOffset.height)
                    .insetBy(dx: -blur, dy: -blur))
            }
            if let background = attributes[TextForgeBackground.attributeName] as? TextForgeBackground {
                let insets = background.insets
                let strokeHalf = background.strokeColor != nil ? max(0, background.strokeWidth / 2) : 0
                let bgRect = base.inset(by: UIEdgeInsets(
                    top: min(0, insets.top) - strokeHalf,
                    left: min(0, insets.left) - strokeHalf,
                    bottom: min(0, insets.bottom) - strokeHalf,
                    right: min(0, insets.right) - strokeHalf
                ))
                area = area.union(bgRect)
            }
            ink = ink.union(area)
        }
        return ink
    }

    /// 绘制只取与脏区及其外伸墨迹相交的完整行，避免切断同一行的双向文字、圆角或截断标记。
    private func drawingGlyphs(in clip: CGRect?, activeBackground: TextForgeBackground?) -> NSRange {
        guard let clip, !clip.contains(usedRect) else { return glyphs }
        guard !clip.isEmpty else { return NSRange() }
        let insets = activeBackground?.insets ?? .zero
        let margin = max(4, usedRect.minY - inkBounds.minY, inkBounds.maxY - usedRect.maxY) + max(0, -insets.top, -insets.bottom)
        let band = CGRect(x: 0, y: clip.minY - margin, width: container.size.width, height: clip.height + 2 * margin)
        return NSIntersectionRange(glyphs, manager.glyphRange(forBoundingRectWithoutAdditionalLayout: band, in: container))
    }

    /// 依次绘制系统背景、圆角背景装饰、按压背景和字形。选中色作用于可见正文和标记，局部按压色优先，绘制后恢复原色。
    func draw(at origin: CGPoint, active: TextForgeActiveStyle?, highlightedColor: UIColor? = nil, clip: CGRect? = nil) {
        let glyphs = drawingGlyphs(in: clip, activeBackground: active?.background)
        guard glyphs.length > 0 else { return }
        let glyphOrigin = CGPoint(x: origin.x - shift, y: origin.y)
        manager.drawBackground(forGlyphRange: glyphs, at: glyphOrigin)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(TextForgeBackground.attributeName, in: visible) { value, range, _ in
            guard let background = value as? TextForgeBackground else { return }
            for rect in runRects(for: range) {
                background.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        let activeRange = active.map { NSIntersectionRange($0.range, visible) }
        if let active, let activeRange, let background = active.background {
            for rect in runRects(for: activeRange) { background.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        let tintedRange = highlightedColor != nil ? visible : (active?.foreground == nil ? nil : activeRange)
        let original = tintedRange.map { storage.attributedSubstring(from: $0) }
        if let highlightedColor { storage.addAttribute(.foregroundColor, value: highlightedColor, range: visible) }
        if let active, let activeRange, activeRange.length > 0, let foreground = active.foreground {
            storage.addAttribute(.foregroundColor, value: foreground, range: activeRange)
        }
        manager.drawGlyphs(forGlyphRange: glyphs, at: glyphOrigin)
        if let original, let tintedRange {
            storage.beginEditing()
            original.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                let target = NSRange(location: tintedRange.location + range.location, length: range.length)
                if let value {
                    storage.addAttribute(.foregroundColor, value: value, range: target)
                } else {
                    storage.removeAttribute(.foregroundColor, range: target)
                }
            }
            storage.endEditing()
        }
    }

    /// 将最近字形限制到可见内容，排除行尾空白、标签间隙及截断字形。
    func hit(at point: CGPoint) -> TextForgeHit? {
        guard glyphs.length > 0 else { return nil }
        let point = CGPoint(x: point.x + shift, y: point.y)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard isVisible(glyph),
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else {
            return nil
        }
        let index = manager.characterIndexForGlyph(at: glyph)
        if storage.attribute(TextForgeBackground.marginKern, at: index, effectiveRange: nil) != nil {
            let cluster = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
            let content = boundingRect(for: cluster).offsetBy(dx: shift, dy: 0)
            guard content.contains(point) else { return nil }
        }
        if let tokenRange, index >= tokenRange.location {
            return index < NSMaxRange(tokenRange) ? .token(index - tokenRange.location) : nil
        }
        return .text(sourceOffset(index))
    }

    /// 选词只允许在连续可见的原文中扩展。按行排除系统省略和自定义标记，合并跨行相邻的 UTF-16 范围。
    func selectionSegments() -> [NSRange] {
        guard glyphs.length > 0 else { return [] }
        if !isTruncated { return [NSRange(location: 0, length: sourceLength)] }
        let source = NSRange(location: 0, length: tokenRange?.location ?? sourceLength)
        var indices = IndexSet()
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
            for part in self.visibleGlyphParts(of: NSIntersectionRange(line, self.glyphs)) {
                let range = NSIntersectionRange(source, self.manager.characterRange(forGlyphRange: part, actualGlyphRange: nil))
                if range.length > 0 { indices.insert(integersIn: self.sourceOffset(range.location)..<self.sourceOffset(NSMaxRange(range))) }
            }
        }
        return indices.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
    }

    /// 只在拖动已存在的手柄时使用最近字形；行尾和行间留白也能延伸选区，结果随后限制到起点所在片段。
    func nearestIndex(to point: CGPoint) -> Int {
        guard glyphs.length > 0 else { return NSNotFound }
        let local = CGPoint(x: point.x + shift, y: point.y)
        let glyph = min(max(glyphs.location, manager.glyphIndex(for: local, in: container)), NSMaxRange(glyphs) - 1)
        return sourceOffset(manager.characterIndexForGlyph(at: glyph))
    }

    /// 使用字形的双向嵌入层级定位选区端点；同一行的 RTL 和 LTR 段分别选择正确的一侧。
    func isRightToLeft(atStorageIndex index: Int) -> Bool {
        var level: UInt8 = 0
        let glyph = manager.glyphIndexForCharacter(at: index)
        manager.getGlyphs(in: NSRange(location: glyph, length: 1), glyphs: nil, properties: nil,
                          characterIndexes: nil, bidiLevels: &level)
        return !level.isMultiple(of: 2)
    }

    /// 将排版串的边界还原到原文前缀；额外的软换行在原文中占零个码元。
    private func sourceOffset(_ offset: Int) -> Int {
        if let insertedBreak, offset > insertedBreak { return offset - 1 }
        return offset
    }

    /// 原文字符的实际存储下标，用于查询方向、字形和附件槽。
    func storageIndex(forSource index: Int) -> Int {
        if let insertedBreak, index >= insertedBreak { return index + 1 }
        return index
    }

    /// 把 UTF-16 查询范围裁到正文或标记可用的区间。无效位置返回空范围，长度先裁切再相加，避免整数溢出。
    func storageRange(for range: NSRange, inToken: Bool) -> NSRange {
        let available: NSRange
        if inToken {
            guard let tokenRange else { return NSRange(location: 0, length: 0) }
            available = tokenRange
        } else {
            available = NSRange(location: 0, length: sourceOffset(tokenRange?.location ?? storage.length))
        }
        guard range.location >= 0, range.location < available.length, range.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let start = available.location + range.location
        let length = min(range.length, available.length - range.location)
        if inToken { return NSRange(location: start, length: length) }
        let lower = storageIndex(forSource: start)
        return NSRange(location: lower, length: storageIndex(forSource: start + length - 1) - lower + 1)
    }

    /// 逐个交付可见片段的内容区，保持行片段高度，去掉视觉右缘字素为下一个字预留的间距。
    /// TextKit 的字形选择框包含这部分 advance；绘制、选区和命中共用同一条边界。
    private func enumerateContentRects(for part: NSRange, _ visit: @escaping (CGRect) -> Void) {
        manager.enumerateEnclosingRects(forGlyphRange: part, withinSelectedGlyphRange: part, in: container) { rect, _ in
            guard !rect.isEmpty else { return }
            let edge = CGPoint(x: rect.maxX - min(0.01, rect.width / 2), y: rect.midY)
            let glyph = self.manager.glyphIndex(for: edge, in: self.container)
            var content = rect
            if NSLocationInRange(glyph, part) {
                let index = self.manager.characterIndexForGlyph(at: glyph)
                if let margin = self.storage.attribute(TextForgeBackground.marginKern, at: index, effectiveRange: nil) as? NSNumber {
                    content.size.width = max(0, rect.width - CGFloat(margin.doubleValue))
                }
            }
            if !content.isEmpty { visit(content) }
        }
    }

    /// 合并剔除标签留白后的可见内容矩形，纵向保留行片段高度；范围不可见时返回 null。
    func boundingRect(for range: NSRange) -> CGRect {
        guard range.length > 0 else { return .null }
        let selected = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
        guard selected.length > 0 else { return .null }
        var bounds = CGRect.null
        manager.enumerateLineFragments(forGlyphRange: selected) { _, _, _, line, _ in
            for part in self.visibleGlyphParts(of: NSIntersectionRange(line, selected)) {
                self.enumerateContentRects(for: part) { bounds = bounds.union($0) }
            }
        }
        return bounds.isNull ? .null : bounds.offsetBy(dx: -shift, dy: 0)
    }

    /// 排版串范围在每个行片段上的排版矩形：横向取字形外接范围，纵向取基线上下的字体升部与降部，
    /// 不含行距。按视觉片段的实际右缘剔除预留间隔，背景、按压和触摸距离共用结果。
    func runRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let selected = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
        guard selected.length > 0 else { return [] }
        var result: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: selected) { fragment, _, _, lineGlyphs, _ in
            for part in self.visibleGlyphParts(of: NSIntersectionRange(lineGlyphs, selected)) {
                let baseline = self.baseline(forGlyphAt: part.location, in: fragment)
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
                self.enumerateContentRects(for: part) { rect in
                    var bounds = rect
                    if ascent > descent {
                        bounds.origin.y = baseline - ascent
                        bounds.size.height = ascent - descent
                    }
                    if !bounds.isEmpty { result.append(bounds.offsetBy(dx: -self.shift, dy: 0)) }
                }
            }
        }
        return result
    }

    /// 可见原文的 UTF-16 外接范围，头部和中部截断的区间内部可能有隐藏字形。没有可见原文时为 nil。
    var visibleCharacterRange: NSRange? {
        guard glyphs.length > 0 else { return nil }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if !clippedGlyphs.isEmpty {
            let parts = visibleGlyphParts(of: glyphs)
            guard let first = parts.first, let last = parts.last else { return nil }
            return NSUnionRange(manager.characterRange(forGlyphRange: first, actualGlyphRange: nil),
                                manager.characterRange(forGlyphRange: last, actualGlyphRange: nil))
        }
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
        return upper > lower ? NSRange(location: sourceOffset(lower), length: sourceOffset(upper) - sourceOffset(lower)) : nil
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
        return index.map { inToken ? $0 - offset : sourceOffset($0) }
    }

    /// 由垂直视口查询已排版的字符范围，保留整行以覆盖双向文字及横向偏移的附件。
    func characters(inVerticalBand rect: CGRect) -> NSRange? {
        let band = CGRect(x: 0, y: rect.minY, width: container.size.width, height: rect.height)
        let visible = NSIntersectionRange(glyphs, manager.glyphRange(forBoundingRectWithoutAdditionalLayout: band, in: container))
        return visible.length > 0 ? manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil) : nil
    }

    /// 返回字形所在行片段的真实文本基线纵坐标。TextKit 将附件字形的 location.y 置于附件底边（即基线减去 bounds.minY），
    /// 此处加回 bounds.minY 以还原统一的行文本基线。
    private func baseline(forGlyphAt glyph: Int, in fragment: CGRect) -> CGFloat {
        var y = fragment.minY + manager.location(forGlyphAt: glyph).y
        if storage.length > 0 {
            let index = min(manager.characterIndexForGlyph(at: glyph), storage.length - 1)
            if let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment {
                y += attachment.bounds.minY
            }
        }
        return y
    }

    /// 返回可见附件对应的行基线坐标，不读取 UIKit 视图。
    func baselineForAttachment(at index: Int) -> CGPoint? {
        let glyph = manager.glyphIndexForCharacter(at: index)
        guard isVisible(glyph) else { return nil }
        let location = manager.location(forGlyphAt: glyph)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGPoint(x: fragment.minX + location.x - shift, y: baseline(forGlyphAt: glyph, in: fragment))
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
                range: NSRange(location: self.sourceOffset(lower), length: self.sourceOffset(upper) - self.sourceOffset(lower)), rect: used.offsetBy(dx: -self.shift, dy: 0),
                baseline: self.baseline(forGlyphAt: part.location, in: fragment), row: row
            ))
        }
        return result
    }

    /// 按完整墨迹尺寸生成透明位图，像素超出单条文本预算时保留排版结果供同步绘制。
    func rasterize(scale: CGFloat, traits: UITraitCollection) -> UIImage? {
        guard glyphs.length > 0, scale.isFinite, scale > 0 else { return nil }
        // 位图坐标跟随文字原点；完整保留外伸装饰，最终由宿主视口裁剪。
        let clip = inkBounds
        guard !clip.isNull, !clip.isEmpty else { return nil }
        let x = floor(clip.minX * scale) / scale, y = floor(clip.minY * scale) / scale
        let size = CGSize(width: ceil(clip.maxX * scale) / scale - x, height: ceil(clip.maxY * scale) / scale - y)
        let pixels = ceil(size.width * scale) * ceil(size.height * scale)
        guard pixels <= 1_000_000 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var image: UIImage?
        traits.performAsCurrent {
            image = renderer.image { _ in
                draw(at: CGPoint(x: -x, y: -y), active: nil)
            }
        }
        rasterOrigin = CGPoint(x: x, y: y)
        return image
    }

    /// 排除容器外、被截断以及仅用于固定末行的软换行字形。
    private func isVisible(_ glyph: Int) -> Bool {
        guard NSLocationInRange(glyph, glyphs), !clippedGlyphs.contains(glyph) else { return false }
        if let insertedBreak, manager.characterIndexForGlyph(at: glyph) == insertedBreak { return false }
        guard let omitted = omittedGlyphs(inLineAt: glyph) else { return true }
        return !NSLocationInRange(glyph, omitted)
    }

    /// 从行片段中剔除排版用软换行及 TextKit 以省略号代替的字形。中部截断可能留下前后两段。
    private func visibleGlyphParts(of range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [] }
        if !clippedGlyphs.isEmpty {
            let selected = IndexSet(integersIn: range.location..<NSMaxRange(range))
            return selected.subtracting(clippedGlyphs).rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
        }
        guard isTruncated else { return [range] }
        var hidden = IndexSet()
        if let omitted = omittedGlyphs(inLineAt: range.location) {
            hidden.insert(integersIn: omitted.location..<NSMaxRange(omitted))
        }
        if let insertedBreak { hidden.insert(manager.glyphIndexForCharacter(at: insertedBreak)) }
        guard !hidden.isEmpty else { return [range] }
        return IndexSet(integersIn: range.location..<NSMaxRange(range)).subtracting(hidden).rangeView.map(NSRange.init)
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
            // 系统字体的私有名称重新查找可能变成 Times；直接桥接排版用的实例才能比较同一字体的字形编号。
            let fallbackFont = CTFontCreateForString(font as CTFont, "…" as CFString, CFRange(location: 0, length: 1))
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

    /// clipping 行可能保留整段字形，并把不可见部分压到行边缘的零宽矩形。
    /// 只检查排满的片段，按完整字素确认，以免误删表情内部的零宽字形或普通换行。
    /// 最后一个字也可能只裁掉一部分：仍可命中，但需要报告溢出。
    private static func clippingInfo(
        manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage
    ) -> (hidden: IndexSet, overflows: Bool) {
        guard container.lineBreakMode == .byClipping else { return ([], false) }
        var overflows = false
        let string = storage.string as NSString
        var hidden = IndexSet()
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { fragment, used, _, glyphs, _ in
            guard used.width + 0.5 >= fragment.width else { return }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var lineClipped = false
            var index = characters.location
            while index < NSMaxRange(characters) {
                let cluster = string.rangeOfComposedCharacterSequence(at: index)
                let part = NSIntersectionRange(glyphs, manager.glyphRange(forCharacterRange: cluster, actualCharacterRange: nil))
                index = NSMaxRange(cluster)
                guard part.length > 0 else { continue }
                let box = manager.boundingRect(forGlyphRange: part, in: container)
                if box.width == 0, (box.minX >= fragment.maxX - 0.01 || box.maxX <= fragment.minX + 0.01),
                   (lineClipped || string.rangeOfCharacter(from: .controlCharacters.inverted, options: [], range: cluster).location != NSNotFound) {
                    lineClipped = true
                    hidden.insert(integersIn: part.location..<NSMaxRange(part))
                }
            }
            if lineClipped { overflows = true }
            else if !overflows {
                // TextKit 会把部分可见字形的矩形宽度裁平。使用同一行内容在宽容器中的自然宽度辨别恰好放下。
                let sample = storage.attributedSubstring(from: characters)
                let probe = NSTextContainer(size: CGSize(width: fragment.width + 1024, height: 1_000_000))
                probe.lineFragmentPadding = 0
                probe.maximumNumberOfLines = 1
                let manager = NSLayoutManager()
                let storage = NSTextStorage(attributedString: sample)
                storage.addLayoutManager(manager)
                manager.addTextContainer(probe)
                manager.ensureLayout(for: probe)
                overflows = manager.usedRect(for: probe).width > fragment.width + 0.01
            }
        }
        return (hidden, overflows)
    }

    /// 容器是否没能放下全部内容：后续段落整段落在容器外，或末行被系统省略号截断。
    private static func overflows(manager: NSLayoutManager, container: NSTextContainer, length: Int) -> Bool {
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return length > 0 }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if NSMaxRange(characters) < length { return true }
        return manager.truncatedGlyphRange(inLineFragmentForGlyphAt: NSMaxRange(glyphs) - 1).location != NSNotFound
    }

    /// 把末行尾部替换成自定义截断标记，返回标记在排版串中的范围与末行断行锁。
    /// 先用单行试排在末行内二分出能容纳“正文 + 标记”的最长前缀，再用真实容器复核。
    /// 原末行被吸回上行时在排版串加入软换行并记录映射；真实容器仍溢出时逐字回退，过宽标记交给末行裁切。
    private static func applyTruncationToken(
        _ token: NSAttributedString, source: NSAttributedString, maximumNumberOfRows: Int,
        storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer,
        existingDelegate: TextForgeLayoutDelegate?
    ) -> (range: NSRange, lock: TextForgeLayoutDelegate?, insertedBreak: Int?)? {
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
                    if key == .foregroundColor {
                        let marker = TextForgePaintPalette.marker(for: key)
                        if let index = attributes[marker] { result.addAttribute(marker, value: index, range: range) }
                    }
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
        let lock = existingDelegate ?? (lineStart > 0 ? TextForgeLayoutDelegate() : nil)
        manager.delegate = lock
        var insertedBreak: Int?
        while true {
            let end = trimmedEnd(boundaries[choice])
            let offset = insertedBreak == nil ? 0 : 1
            let piece = wrappingText(inheritedToken(end), maximumNumberOfRows: maximumNumberOfRows, mode: container.lineBreakMode)
            if lineStart > 0 {
                lock?.lockedRange = NSRange(location: lineStart + offset, length: end - lineStart + piece.length)
            }
            let tokenStart = end + offset
            storage.replaceCharacters(in: NSRange(location: tokenStart, length: storage.length - tokenStart), with: piece)
            manager.ensureLayout(for: container)
            if insertedBreak == nil, lineStart > 0 {
                let first = manager.glyphIndexForCharacter(at: lineStart)
                if NSLocationInRange(first, manager.glyphRange(for: container)),
                   manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY < fragment.minY - 0.5 {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    for key in [NSAttributedString.Key.font, .paragraphStyle] {
                        attributes[key] = source.attribute(key, at: lineStart - 1, effectiveRange: nil)
                    }
                    storage.insert(NSAttributedString(string: "\u{2028}", attributes: attributes), at: lineStart)
                    insertedBreak = lineStart
                    continue
                }
            }
            if choice == 0 || !overflows(manager: manager, container: container, length: storage.length) {
                return (NSRange(location: tokenStart, length: piece.length), lock, insertedBreak)
            }
            choice -= 1
        }
    }

    /// 避免将无界尺寸直接交给 TextKit，零尺寸时也保持有效容器。
    private static func containerDimension(_ value: CGFloat, minus inset: CGFloat) -> CGFloat {
        if value.isNaN { return 0 }
        return max(0, min(value - inset, 1_000_000))
    }

    /// 缺少段落样式或仅由 TextForgeTypography 合成间距时采用容器的逐字换行。多行文本先折行，末行由容器决定如何截断。
    private static func wrappingText(_ text: NSAttributedString, maximumNumberOfRows: Int, mode: NSLineBreakMode) -> NSAttributedString {
        guard maximumNumberOfRows != 1 || mode == .byCharWrapping else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let value = attributes[.paragraphStyle] as? NSParagraphStyle
            let synthesized = attributes[TextForgeTypography.synthesizedParagraphStyle] != nil
            if (value == nil || synthesized), mode == .byCharWrapping {
                let style = (value?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.lineBreakMode = .byCharWrapping
                result.addAttribute(.paragraphStyle, value: style, range: range)
                return
            }
            guard maximumNumberOfRows != 1, let style = value,
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

/// 统一承载固定行高基线规整与末行截断防跨行回流。
private final class TextForgeLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    var fixedLineHeight: CGFloat = 0
    var lockedRange = NSRange(location: NSNotFound, length: 0)

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        if lockedRange.location != NSNotFound, charIndex > lockedRange.location, charIndex < NSMaxRange(lockedRange) {
            return false
        }
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int) -> Bool {
        if lockedRange.location != NSNotFound, charIndex > lockedRange.location, charIndex < NSMaxRange(lockedRange) {
            return false
        }
        return true
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard fixedLineHeight > 0, glyphRange.length > 0 else { return false }
        var maxAscender: CGFloat = 0
        var minDescender: CGFloat = 0
        if let storage = layoutManager.textStorage, storage.length > 0 {
            let startChar = min(layoutManager.characterIndexForGlyph(at: glyphRange.location), storage.length - 1)
            let endChar = min(layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphRange) - 1), storage.length - 1)
            let chars = NSRange(location: min(startChar, endChar), length: abs(endChar - startChar) + 1)
            storage.enumerateAttribute(.font, in: chars) { value, _, _ in
                if let font = value as? UIFont {
                    maxAscender = max(maxAscender, font.ascender)
                    minDescender = min(minDescender, font.descender)
                }
            }
        }
        if maxAscender == 0, minDescender == 0 {
            let fallback = UIFont.systemFont(ofSize: 16)
            maxAscender = fallback.ascender
            minDescender = fallback.descender
        }
        let naturalHeight = maxAscender - minDescender
        let leading = (fixedLineHeight - naturalHeight) / 2
        lineFragmentRect.pointee.size.height = fixedLineHeight
        lineFragmentUsedRect.pointee.size.height = fixedLineHeight
        baselineOffset.pointee = max(0, leading + maxAscender)
        return true
    }
}
