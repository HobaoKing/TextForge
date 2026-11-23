import UIKit

/// 可在主线程复用的度量和绘制结果。输入宽高及内边距均使用点。
/// 公开查询的坐标以布局外部边界的左上角为原点，范围使用原文的 UTF-16 下标。
@MainActor
@objc(TextForgeLayout)
public final class TextForgeLayout: NSObject {
    @objc public let attributedText: NSAttributedString
    /// 包含内边距的尺寸。宽度从外部边界左缘量到文字右缘，把标签设成这个尺寸可以完整显示布局。
    @objc public let textBoundingSize: CGSize
    /// 创建布局时指定的外部边界。
    @objc public let size: CGSize
    @objc public let insets: UIEdgeInsets
    /// 最多显示的行数，0 表示不限行。
    @objc public let maximumNumberOfRows: Int
    @objc public let lineBreakMode: NSLineBreakMode

    let container: TextForgeContainer
    private let engine: TextForgeLayoutEngine
    private let preparedImage: UIImage?
    private let preparedTraits: UITraitCollection?
    let paint: TextForgePaintPalette?
    var bitmapCost: Int { preparedImage?.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
    private var cachedLines: [TextForgeLine]?

    /// 按给定边界同步排版，行数为 0 表示不限行。返回的尺寸包含内边距。
    @objc public convenience init(
        attributedText: NSAttributedString,
        size: CGSize,
        insets: UIEdgeInsets,
        maximumNumberOfRows: Int,
        lineBreakMode: NSLineBreakMode
    ) {
        let container = TextForgeContainer(size: size, insets: insets)
        container.maximumNumberOfRows = maximumNumberOfRows
        container.lineBreakMode = lineBreakMode
        self.init(container: container, attributedText: attributedText)
    }

    /// 按给定边界同步排版：无内边距、不限行、正常折行。
    @objc public convenience init(attributedText: NSAttributedString, size: CGSize) {
        self.init(container: TextForgeContainer(size: size), attributedText: attributedText)
    }

    /// 按容器配置同步排版。容器会被复制，之后修改不影响本布局。
    @objc public convenience init(container: TextForgeContainer, attributedText: NSAttributedString) {
        self.init(container: container, attributedText: attributedText, fallbackTraits: nil)
    }

    /// 可变附件被原地更改后，旧富文本与新富文本可能仍指向同一对象。排版时记录影响字形的版本。
    fileprivate struct AttachmentCheckpoint {
        let index: Int
        let attachment: NSTextAttachment
        let bounds: CGRect
        let image: UIImage?

        /// 自定义排版或文件附件无法只由公开尺寸判定，保守地从该段起重排。
        var needsLayout: Bool {
            if attachment is TextForgeViewAttachment { return attachment.bounds != bounds }
            return type(of: attachment) != NSTextAttachment.self || image == nil
                || attachment.bounds != bounds || attachment.image !== image
        }
    }
    private var attachmentCheckpoints: [AttachmentCheckpoint] = []

    /// 只为标签私有的不限行布局留存附件度量，列表共享布局和后台交付不增加主线程扫描。
    func captureAttachmentMetrics() {
        attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                let image = type(of: attachment) == NSTextAttachment.self ? attachment.image : nil
                attachmentCheckpoints.append(AttachmentCheckpoint(index: range.location, attachment: attachment,
                                                                  bounds: attachment.bounds, image: image))
            }
        }
    }

    /// 标签换文时暂存排版栈；只有旧布局真正释放后才可独占修改，外部保留的公开快照继续独立可读。
    @MainActor final class ParagraphCandidate {
        weak var owner: TextForgeLayout?
        let text: NSAttributedString
        let box: TextForgeContainer
        fileprivate let engine: TextForgeLayoutEngine
        fileprivate let attachments: [AttachmentCheckpoint]

        /// 截断或变换过的存储与原文范围不同，仅接管普通、不限行的同步正文。
        init?(_ layout: TextForgeLayout) {
            guard layout.preparedTraits == nil, layout.maximumNumberOfRows == 0, !layout.isTruncated,
                  layout.container.minimumScaleFactor == 1, layout.container.exclusionPaths.isEmpty,
                  layout.container.truncationToken == nil,
                  TextForgeLayoutEngine.hasStandardLineMetrics(layout.attributedText,
                      in: NSRange(location: 0, length: layout.attributedText.length)) else { return nil }
            owner = layout
            text = layout.attributedText
            box = layout.container
            engine = layout.engine
            attachments = layout.attachmentCheckpoints
        }
    }

    /// 自定义附件沿用宿主环境。标签独占的普通正文可接管旧栈，从变化段附近重排并重新计算度量。
    convenience init(container: TextForgeContainer, attributedText: NSAttributedString, fallbackTraits: UITraitCollection?,
                     reusing previous: ParagraphCandidate? = nil) {
        let container = container.copy() as? TextForgeContainer ?? container
        // 只有普通不限行布局才可保留原 TextKit 栈。截断、缩字及排除路径仍由完整布局处理。
        let rendered = Self.renderingText(attributedText, container: container)
        let parameters = Self.parameters(for: container)
        var prefix = 0
        if let previous, previous.owner == nil, previous.box.size == container.size,
           previous.box.insets == container.insets, previous.box.lineBreakMode == container.lineBreakMode,
           container.maximumNumberOfRows == 0, container.truncationToken == nil, container.exclusionPaths.isEmpty,
           container.minimumScaleFactor == 1,
           TextForgeLayoutEngine.hasStandardLineMetrics(rendered, in: NSRange(location: 0, length: rendered.length)) {
            let attachmentLimit = previous.attachments.first(where: \.needsLayout)?.index ?? attributedText.length
            prefix = Self.unchangedParagraphPrefix(previous.text, attributedText, before: attachmentLimit)
        }
        let token = container.truncationToken.map { Self.renderingText($0, container: container) }
        let build = {
            if prefix > rendered.length / 2, let previous {
                let updated = TextForgeLayoutEngine(text: rendered, truncationToken: token, parameters: parameters,
                                                    reusing: previous.engine, unchangedPrefix: prefix)
                if updated.matchesFreshTail(rendered, from: prefix, parameters: parameters) { return updated }
            }
            return TextForgeLayoutEngine(text: rendered, truncationToken: token, parameters: parameters)
        }
        let engine: TextForgeLayoutEngine
        if let fallbackTraits {
            var target: TextForgeLayoutEngine!
            fallbackTraits.performAsCurrent { target = build() }
            engine = target
        } else { engine = build() }
        self.init(attributedText: attributedText, container: container, engine: engine, preparedImage: nil, preparedTraits: fallbackTraits)
    }

    /// 逐段比较 UTF-16 原文和完整属性，将重排起点退到首个变化段的段首，保留 CRLF 和组合字符边界。
    private static func unchangedParagraphPrefix(_ old: NSAttributedString, _ new: NSAttributedString, before changedIndex: Int) -> Int {
        let original = old.string as NSString
        let string = new.string as NSString
        let limit = min(original.length, string.length, changedIndex)
        var left = [unichar](repeating: 0, count: 512)
        var right = left
        var offset = 0
        while offset < limit {
            var lhs = NSRange(), rhs = NSRange()
            let oldStyle = old.attributes(at: offset, effectiveRange: &lhs) as NSDictionary
            let newStyle = new.attributes(at: offset, effectiveRange: &rhs)
            guard oldStyle.isEqual(to: newStyle) else { break }
            let end = min(limit, NSMaxRange(lhs), NSMaxRange(rhs))
            // 逐块核对 UTF-16 码元，属性边界即使位于代理对中间也不会因桥接成替换字符而误判。
            while offset < end {
                let count = min(end - offset, left.count)
                let range = NSRange(location: offset, length: count)
                original.getCharacters(&left, range: range)
                string.getCharacters(&right, range: range)
                if memcmp(left, right, count * MemoryLayout<unichar>.stride) != 0 {
                    for i in 0..<count where left[i] != right[i] { offset += i; break }
                    break
                }
                offset += count
            }
            if offset != end { break }
        }
        guard offset > 0 else { return 0 }
        // 前一字符可能是被追加 LF 的 CR，或与后续文字共同组成一个字素，连同该段重排。
        let start = string.paragraphRange(for: NSRange(location: offset - 1, length: 0)).location
        // TextKit 的首行基线会受上一段末行的字体和段后距影响，一起试排这个相邻段。
        guard start > 0 else { return 0 }
        return string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
    }

    /// 接管已排好的引擎，关联原始交互文本；可选位图仅用于常态绘制。container 须为本布局独占的副本。
    init(
        attributedText: NSAttributedString, container: TextForgeContainer,
        engine: TextForgeLayoutEngine, preparedImage: UIImage?, preparedTraits: UITraitCollection?, paint: TextForgePaintPalette? = nil
    ) {
        self.attributedText = attributedText.copy() as! NSAttributedString
        self.container = container
        size = container.size
        insets = container.insets
        maximumNumberOfRows = max(0, container.maximumNumberOfRows)
        lineBreakMode = container.lineBreakMode
        self.engine = engine
        self.preparedImage = preparedImage
        self.preparedTraits = preparedTraits
        self.paint = paint
        textBoundingSize = engine.textBoundingSize
        super.init()
    }

    /// 复用已验证的几何结果。只请求几何时按显示倍率筛选位图，显式预绘的调用仍按指定倍率取用。
    func withSize(_ size: CGSize, displayScale: CGFloat? = nil) -> TextForgeLayout {
        let useBitmap = displayScale == nil || preparedImage == nil || preparedImage?.scale == displayScale
        if size == self.size && useBitmap { return self }
        let box = container.copy() as! TextForgeContainer
        box.size = size
        return TextForgeLayout(attributedText: attributedText, container: box, engine: engine, preparedImage: useBitmap ? preparedImage : nil,
                               preparedTraits: preparedTraits, paint: paint)
    }

    // MARK: 公开查询

    /// 创建布局时配置的截断标记，未配置时为 nil。实际显示情况见 `showsTruncationToken`。
    @objc public var truncationToken: NSAttributedString? { container.truncationToken }

    /// 内容超出行数或高度限制，末行显示了省略号或截断标记，或有内容被裁掉。
    @objc public var isTruncated: Bool { engine.isTruncated }

    /// 实际显示的视觉行数。
    @objc public var rowCount: Int { (lines.last?.row ?? -1) + 1 }

    /// 逐行的原文范围、占用矩形和基线。排除路径把一行切成多段时每段各占一项。
    @objc public var lines: [TextForgeLine] {
        if let cachedLines { return cachedLines }
        let result = engine.lines().map {
            TextForgeLine(range: $0.range, rect: outer($0.rect), baseline: $0.baseline + insets.top, row: $0.row)
        }
        cachedLines = result
        return result
    }

    /// 覆盖可见原文的最小 UTF-16 范围。头部和中部截断时范围内可能包含隐藏字形，几何查询会排除它们。
    /// 没有可见原文时 location 为 NSNotFound。
    @objc public var visibleRange: NSRange {
        engine.visibleCharacterRange ?? NSRange(location: NSNotFound, length: 0)
    }

    /// 文字实际占用的矩形，不含内边距。
    @objc public var textBoundingRect: CGRect { outer(engine.usedRect) }

    /// 返回该点所在字形对应的原文下标。落在空白、截断标记或被截断的内容上时返回 NSNotFound。
    @objc(characterIndexAtPoint:) public func characterIndex(at point: CGPoint) -> Int {
        if case .text(let index)? = engine.hit(at: CGPoint(x: point.x - insets.left, y: point.y - insets.top)) {
            return index
        }
        return NSNotFound
    }

    /// 原文范围内可见字形的外接矩形，高度取所在行的行片段。范围不可见时返回 `CGRect.null`。
    @objc(rectForRange:) public func rect(forRange range: NSRange) -> CGRect {
        outer(containerRect(for: range, inToken: false))
    }

    /// 原文范围在各行的视觉片段矩形，双向混排可在同一行返回多段；纵向按字体升部和降部计算。
    @nonobjc public func rects(forRange range: NSRange) -> [CGRect] {
        runRects(for: range, inToken: false).map(outer)
    }

    /// `rects(forRange:)` 的 Objective-C 形式，元素为包装 CGRect 的 NSValue。
    @objc(rectsForRange:) public func rectValues(forRange range: NSRange) -> [NSValue] {
        rects(forRange: range).map { NSValue(cgRect: $0) }
    }

    // MARK: 供标签使用，坐标以排版区左上角为原点

    /// 首次选择时才计算连续可见片段，拖动手柄复用同一份不可变布局。
    private(set) lazy var selectionSegments = engine.selectionSegments()

    /// 将拖选位置映射到最近字形，点相对于排版内容区。
    func nearestSelectionIndex(to point: CGPoint) -> Int { engine.nearestIndex(to: point) }

    /// 根据端点字形方向选择手柄位于字形框的左侧还是右侧。
    func isRightToLeft(at index: Int) -> Bool { engine.isRightToLeft(at: index) }

    /// 文字自身宽度加内边距，标签按内容自适应时使用。
    var fittingSize: CGSize { engine.fittingSize }

    /// 截断标记实际显示出来了。
    @objc public var showsTruncationToken: Bool { !truncationTokenRect.isNull }

    /// 自定义标记可见部分的外接矩形，使用布局外部坐标。未显示或完全被裁掉时返回 CGRect.null。
    @objc public var truncationTokenRect: CGRect {
        guard let range = engine.tokenRange else { return .null }
        return outer(engine.boundingRect(for: range))
    }

    /// 高度放宽时，只有全文或指定行数已完整放下才能沿用。裁切、缩字和排除路径采用原约束重新测量。
    func fitsHeight(_ height: CGFloat) -> Bool {
        if size.height == height { return true }
        guard textBoundingSize.height <= min(height, size.height), size.height > insets.top + insets.bottom else { return false }
        if size.height > height { return true }
        guard container.exclusionPaths.isEmpty, container.minimumScaleFactor >= 1 else { return false }
        return !isTruncated || (maximumNumberOfRows > 0 && rowCount == maximumNumberOfRows)
    }

    /// 复用到实际测量高度前核对末行完整片段，以及会改变 TextKit 高度行为的样式与截断配置。
    func canReuseAtMeasuredHeight(_ height: CGFloat) -> Bool {
        container.exclusionPaths.isEmpty && container.minimumScaleFactor >= 1 && fitsHeight(height)
            && (!isTruncated || (container.truncationToken == nil && maximumNumberOfRows > 0 && rowCount == maximumNumberOfRows))
            && engine.supportsMeasuredHeight(lineBreakMode: lineBreakMode, height: height - insets.top - insets.bottom)
    }

    /// 只有影响排版的环境变化才放弃几何结果；颜色在绘制时按目标标签解析。
    func matchesAppearance(_ traits: UITraitCollection) -> Bool {
        guard let preparedTraits else { return true }
        if paint == nil || paint?.requiresExactGeometry == true { return preparedTraits == traits }
        return traits.preferredContentSizeCategory == preparedTraits.preferredContentSizeCategory
            && traits.layoutDirection == preparedTraits.layoutDirection
            && traits.legibilityWeight == preparedTraits.legibilityWeight
    }

    /// 常态位图按裁剪原点贴回；整标签选中或局部按压时用同一布局绘制状态色。
    /// activeRange 为原文或截断标记内部的范围，由 activeInToken 区分。
    func draw(
        at origin: CGPoint, activeRange: NSRange?, activeInToken: Bool,
        activeBackground: TextForgeBackground?, activeForeground: UIColor?, highlightedColor: UIColor?,
        clip: CGRect, traits: UITraitCollection
    ) {
        let localClip = clip.offsetBy(dx: -origin.x, dy: -origin.y)
        if activeRange == nil, highlightedColor == nil, let preparedImage, paint?.matches(traits) != false,
           preparedTraits?.displayScale == traits.displayScale,
           paint?.hasImages != true || preparedTraits == traits {
            preparedImage.draw(at: CGPoint(x: origin.x + engine.rasterOrigin.x, y: origin.y + engine.rasterOrigin.y))
            return
        }
        traits.performAsCurrent {
            if let paint { engine.applyPaint(paint, traits: traits, clip: localClip, activeBackground: activeBackground) }
            engine.draw(at: origin, active: activeRange.map {
                TextForgeActiveStyle(
                    range: engine.storageRange(for: $0, inToken: activeInToken),
                    background: activeBackground, foreground: activeForeground
                )
            }, highlightedColor: highlightedColor, clip: localClip)
        }
    }

    /// 命中的字符下标及其是否位于截断标记内。
    func hit(at point: CGPoint) -> (index: Int, inToken: Bool)? {
        switch engine.hit(at: point) {
        case .text(let index): return (index, false)
        case .token(let index): return (index, true)
        case nil: return nil
        }
    }

    /// 获取范围内可见字形的外接矩形，坐标相对排版区。inToken 为 true 时用标记内部的下标。
    func containerRect(for range: NSRange, inToken: Bool) -> CGRect {
        engine.boundingRect(for: engine.storageRange(for: range, inToken: inToken))
    }

    /// 返回范围内各段可见文字的矩形，坐标相对排版区，用于热区和装饰绘制。
    func runRects(for range: NSRange, inToken: Bool) -> [CGRect] {
        engine.runRects(for: engine.storageRange(for: range, inToken: inToken))
    }

    var visibleCharacterRange: NSRange? { engine.visibleCharacterRange }

    /// 确认正文或标记中的链接至少有一个可见字符，再创建辅助操作或触摸热区。
    func firstVisibleCharacter(in range: NSRange, inToken: Bool) -> Int? {
        engine.firstVisibleCharacter(in: range, inToken: inToken)
    }

    private struct ViewSlot {
        let index: Int
        let attachment: TextForgeViewAttachment
    }

    /// 仅索引视图在排版串中的位置。视图大于槽时扩大候选行，避免视图中心滚出后提早卸载。
    private lazy var viewSlots: (entries: [ViewSlot], overhang: CGFloat) = {
        var entries: [ViewSlot] = []
        var overhang: CGFloat = 0
        // 只索引可见正文或截断标记；offset 把标记内部下标换算到引擎存储。
        func collect(_ text: NSAttributedString, range: NSRange, offset: Int) {
            text.enumerateAttribute(.attachment, in: range) { value, segment, _ in
                guard let attachment = value as? TextForgeViewAttachment else { return }
                overhang = max(overhang, abs(attachment.bounds.midY) + max(attachment.viewSize.height, attachment.bounds.height))
                entries.append(ViewSlot(index: segment.location + offset, attachment: attachment))
            }
        }
        if let range = engine.visibleCharacterRange { collect(attributedText, range: range, offset: 0) }
        if let token = truncationToken, let range = engine.tokenRange {
            collect(token, range: NSRange(location: 0, length: min(token.length, range.length)), offset: range.location)
        }
        return (entries, overhang)
    }()

    var hasViewAttachments: Bool { !viewSlots.entries.isEmpty }

    /// 二分找到落在可见行的第一个槽，只为候选附件读取实际字形基线，再按原生视图尺寸精确裁剪。
    func viewAttachments(in viewport: CGRect) -> [(UIView, CGRect)] {
        guard !viewport.isEmpty, let range = engine.characters(inVerticalBand: viewport.insetBy(dx: 0, dy: -viewSlots.overhang))
        else { return [] }
        let entries = viewSlots.entries
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if entries[mid].index < range.location { lower = mid + 1 } else { upper = mid }
        }
        var result: [(UIView, CGRect)] = []
        for slot in entries[lower...] {
            if slot.index >= NSMaxRange(range) { break }
            guard let baseline = engine.baselineForAttachment(at: slot.index) else { continue }
            let bounds = slot.attachment.bounds
            let native = slot.attachment.viewSize
            let size = native.width > 0 && native.height > 0 ? native : bounds.size
            let frame = CGRect(origin: CGPoint(x: baseline.x + bounds.midX - size.width / 2,
                                               y: baseline.y - bounds.midY - size.height / 2), size: size)
            if frame.intersects(viewport) { result.append((slot.attachment.view, frame)) }
        }
        return result
    }

    // MARK: 排版输入

    /// 复制排除路径并取出排版用的值参数，之后可交给后台线程。
    static func parameters(for container: TextForgeContainer) -> TextForgeLayoutParameters {
        TextForgeLayoutParameters(
            size: container.size, insets: container.insets,
            maximumNumberOfRows: container.maximumNumberOfRows, lineBreakMode: container.lineBreakMode,
            minimumScaleFactor: container.minimumScaleFactor,
            exclusionPaths: container.exclusionPaths.map { $0.copy() as? UIBezierPath ?? $0 }
        )
    }

    /// 生成只用于排版的文本，HTML 阅读样式保留链接外观，调用方显式指定的控件样式优先。
    /// TextKit 会给 `.link` 强制套用系统链接色，保留它就无法自定义外观；交互仍读取原文里的链接。
    static func renderingText(
        _ text: NSAttributedString, container: TextForgeContainer
    ) -> NSAttributedString {
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            let target = result ?? NSMutableAttributedString(attributedString: text)
            result = target
            target.removeAttribute(.link, range: range)
            if container.hasExplicitLinkStyle {
                target.addAttributes(container.linkTextAttributes, range: range)
            } else {
                text.enumerateAttribute(TextForgeHTML.styledLink, in: range) { styled, part, _ in
                    if styled == nil { target.addAttributes(container.linkTextAttributes, range: part) }
                }
            }
        }
        return result ?? text
    }

    /// 把排版区坐标换成以外部边界左上角为原点的坐标，null 保持不变。
    private func outer(_ rect: CGRect) -> CGRect {
        rect.isNull ? rect : rect.offsetBy(dx: insets.left, dy: insets.top)
    }
}
