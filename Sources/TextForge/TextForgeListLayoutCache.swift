import UIKit

/// 一行的不可变内容版本。正文、交互、附件或排版样式变化时创建新项；跨宽度和 Cell 保留同一实例，等价内容也可跨实例命中缓存。
@MainActor
@objc(TextForgeListItem)
public final class TextForgeListItem: NSObject {
    @objc public let attributedText: NSAttributedString
    fileprivate lazy var identity = ContentKey(attributedText: attributedText, container: container)
    let container: TextForgeContainer

    struct Snapshot {
        let text: NSAttributedString?
        let token: NSAttributedString?
        let supportsToken: Bool
        let paint: TextForgePaintPalette
    }
    fileprivate var lastSnapshot: Snapshot?

    /// 复制富文本和容器；富文本内的视图、交互闭包与附件仍由宿主拥有，内容更新时须换项。
    @objc public init(attributedText: NSAttributedString, container: TextForgeContainer) {
        self.attributedText = attributedText.copy() as! NSAttributedString
        self.container = container.copy() as! TextForgeContainer
    }

    /// 冷、暖查询均按正文和标记的有效属性选取外观键；无法分离的样式和自动定尺寸的图片变体保留完整外观。
    fileprivate func cacheTraits(for traits: UITraitCollection) -> UITraitCollection {
        guard identity.usesReducedGeometryTraits else { return traits }
        return UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: traits.preferredContentSizeCategory),
            UITraitCollection(layoutDirection: traits.layoutDirection),
            UITraitCollection(legibilityWeight: traits.legibilityWeight)
        ])
    }

    /// 异步保留最近一种环境的完整快照，换宽可复用；取消丢弃部分结果，无法分离的输入标记为主线程回退。
    func snapshot(for traits: UITraitCollection, operation: Operation) async -> Snapshot? {
        if let lastSnapshot, lastSnapshot.paint.traits == traits { return lastSnapshot }
        let paint = TextForgePaintPalette(traits: traits)
        let text = await TextForgeLayout.detachedTextForLayout(attributedText, container: container, paint: paint, operation: operation)
        var token: NSAttributedString?
        if let originalToken = container.truncationToken, !operation.isCancelled {
            token = await TextForgeLayout.detachedTextForLayout(originalToken, container: container, paint: paint, operation: operation)
        }
        guard !operation.isCancelled else { return nil }
        let result = Snapshot(text: text, token: token, supportsToken: container.truncationToken == nil || token != nil, paint: paint)
        lastSnapshot = result
        return result
    }
}

/// 不持有 UIView、图片位图或交互闭包的值语义内容指纹，使相同内容与样式的不同 TextForgeListItem 实例可共享缓存。
private final class ContentKey: NSObject {
    // 键只保留轻量令牌；源对象释放后，即便新对象地址相同也会取得另一枚令牌。
    @MainActor private static let objectTokens = NSMapTable<AnyObject, NSObject>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory
    )

    private struct RunSignature: Equatable {
        let range: NSRange
        let attributes: NSDictionary

        /// 合并 UTF-16 范围和已冻结的属性签名，用于内容指纹的预计算哈希。
        func hash(into hasher: inout Hasher) {
            hasher.combine(range.location)
            hasher.combine(range.length)
            hasher.combine(attributes.hash)
        }
    }

    let usesReducedGeometryTraits: Bool
    private let string: String
    private let runs: [RunSignature]
    private let tokenString: String?
    private let tokenRuns: [RunSignature]?
    private let insets: UIEdgeInsets
    private let maximumNumberOfRows: Int
    private let lineBreakMode: NSLineBreakMode
    private let minimumScaleFactor: CGFloat
    private let fixedLineHeight: CGFloat
    private let exclusionPaths: [UIBezierPath]
    private let precomputedHash: Int

    /// 按最终参与排版的链接样式生成指纹，正文和标记中的附件只在同一内容版本内复用。
    @MainActor init(attributedText: NSAttributedString, container: TextForgeContainer) {
        let attachmentVersion = NSObject()
        let body = Self.analyze(TextForgeLayout.renderingText(attributedText, container: container), attachmentVersion: attachmentVersion)
        let token = container.truncationToken.map {
            Self.analyze(TextForgeLayout.renderingText($0, container: container), attachmentVersion: attachmentVersion)
        }
        usesReducedGeometryTraits = body.reduced && (token?.reduced ?? true)
        string = attributedText.string
        runs = body.runs
        tokenString = container.truncationToken?.string
        tokenRuns = token?.runs
        insets = container.insets
        maximumNumberOfRows = max(0, container.maximumNumberOfRows)
        lineBreakMode = container.lineBreakMode
        minimumScaleFactor = container.minimumScaleFactor
        fixedLineHeight = container.fixedLineHeight
        exclusionPaths = container.exclusionPaths.map { $0.copy() as? UIBezierPath ?? $0 }

        var h = Hasher()
        h.combine(string)
        for run in runs { run.hash(into: &h) }
        h.combine(tokenString)
        if let tokenRuns {
            for run in tokenRuns { run.hash(into: &h) }
        }
        h.combine(insets.top)
        h.combine(insets.left)
        h.combine(insets.bottom)
        h.combine(insets.right)
        h.combine(maximumNumberOfRows)
        h.combine(lineBreakMode.rawValue)
        h.combine(minimumScaleFactor)
        h.combine(fixedLineHeight)
        h.combine(exclusionPaths.count)
        precomputedHash = h.finalize()
        super.init()
    }

    override var hash: Int { precomputedHash }

    /// 比较正文、截断标记的有效样式和几何约束，允许等价内容共享缓存。
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ContentKey else { return false }
        if self === other { return true }
        return precomputedHash == other.precomputedHash
            && string == other.string
            && maximumNumberOfRows == other.maximumNumberOfRows
            && lineBreakMode == other.lineBreakMode
            && insets == other.insets
            && minimumScaleFactor == other.minimumScaleFactor
            && fixedLineHeight == other.fixedLineHeight
            && tokenString == other.tokenString
            && runs == other.runs
            && tokenRuns == other.tokenRuns
            && exclusionPaths == other.exclusionPaths
    }

    /// 用不可变值比较常规样式。附件按项隔离，未知属性按弱对象表分配的令牌比较，并使用完整外观键。
    @MainActor private static func analyze(_ text: NSAttributedString, attachmentVersion: NSObject) -> (runs: [RunSignature], reduced: Bool) {
        var runs: [RunSignature] = []
        var reduced = true
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: full) { attributes, range, _ in
            var clean: [NSAttributedString.Key: Any] = [:]
            for (key, value) in attributes {
                if key == TextForgeHighlight.attributeName { continue }
                switch value {
                case is TextForgeViewAttachment:
                    clean[key] = attachmentVersion
                case let att as NSTextAttachment:
                    clean[key] = attachmentVersion
                    if type(of: att) != NSTextAttachment.self { reduced = false }
                    else if let img = att.image {
                        if img.imageAsset != nil, att.bounds.size == .zero { reduced = false }
                    } else if att.contents == nil, let wrapper = att.fileWrapper,
                              !wrapper.isRegularFile || wrapper.regularFileContents == nil { reduced = false }
                case let shadow as NSShadow:
                    if shadow.shadowColor != nil, !(shadow.shadowColor is UIColor) {
                        reduced = false
                        clean[key] = attachmentVersion
                    } else { clean[key] = shadow.copy() }
                case let bg as TextForgeBackground:
                    clean[key] = bg.clone()
                case let p as NSParagraphStyle:
                    clean[key] = p.copy()
                case is UIColor, is UIFont, is NSNumber, is URL, is [NSNumber]:
                    clean[key] = value
                case let str as NSString:
                    clean[key] = str.copy()
                default:
                    reduced = false
                    let source = value as AnyObject
                    if let token = objectTokens.object(forKey: source) {
                        clean[key] = token
                    } else {
                        let token = NSObject()
                        objectTokens.setObject(token, forKey: source)
                        clean[key] = token
                    }
                }
            }
            runs.append(RunSignature(range: range, attributes: clean as NSDictionary))
        }
        return (runs, reduced)
    }
}

/// 列表拥有的缓存。尺寸与渲染结果独立淘汰，相同的预取和可见 Cell 请求共享一次排版。
@MainActor
@objc(TextForgeListLayoutCache)
public final class TextForgeListLayoutCache: NSObject {
    private final class Key: NSObject {
        // 使用不持有 UIView 与交互闭包的值指纹，既支持同实例指针快路径，又允许等价内容跨实例复用。
        let identity: ContentKey
        let size: CGSize
        let scale: CGFloat
        let traits: UITraitCollection

        /// 将 NaN 所在轴按引擎规则归零，使测量、预取和取消能用同一把可比较的键找回请求。
        init(_ identity: ContentKey, _ size: CGSize, _ scale: CGFloat, _ traits: UITraitCollection) {
            self.identity = identity
            self.size = CGSize(width: size.width.isNaN ? 0 : size.width, height: size.height.isNaN ? 0 : size.height)
            self.scale = scale
            self.traits = traits
        }

        /// 键区分内容指纹、约束、预绘倍率与外观，防止跨行或跨宽误用结果。
        override var hash: Int {
            var h = Hasher()
            h.combine(identity.hash)
            h.combine(size.width)
            h.combine(size.height)
            h.combine(scale)
            h.combine(traits.hash)
            return h.finalize()
        }

        /// 与哈希采用相同字段；等价内容与等价 UIKit 环境值可共享结果。
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return identity.isEqual(other.identity) && size == other.size && scale == other.scale && traits == other.traits
        }
    }

    @MainActor private final class Pending {
        var subscribers: [UUID: (Operation, TextForgeListItem, (TextForgeLayout) -> Void)] = [:]
        var worker: TextForgeLayoutTask?
    }

    /// 首次分离期间按内容收集请求；快照就绪后按尺寸、倍率和外观加入对应的排版任务。
    @MainActor private final class ColdBatch {
        let operation = Operation()
        var start: [UUID: (TextForgeListItem.Snapshot) -> Void] = [:]
    }

    @MainActor private final class ColdSubscriber {
        let operation = Operation()
        var request: TextForgeLayoutTask?
    }

    private var cold: [ContentKey: ColdBatch] = [:]
    private let layouts = NSCache<Key, TextForgeLayout>()
    private let geometryLayouts = NSCache<Key, TextForgeLayout>()
    private let sizes = NSCache<Key, NSValue>()
    private let geometrySources = NSCache<Key, Key>()
    private let measuredAliases = NSCache<Key, Key>()
    private var pending: [Key: Pending] = [:]

    /// 渲染缓存的位图逻辑字节预算；系统也可提前淘汰。另有限制条数以覆盖纯排版结果。
    @objc public init(bitmapByteLimit: Int, layoutCountLimit: Int) {
        super.init()
        layouts.totalCostLimit = max(1, bitmapByteLimit)
        layouts.countLimit = max(1, layoutCountLimit)
        geometryLayouts.countLimit = max(1, layoutCountLimit)
        sizes.countLimit = 1024
        geometrySources.countLimit = 1024
        measuredAliases.countLimit = max(1, layoutCountLimit)
    }

    @objc public override convenience init() {
        self.init(bitmapByteLimit: 16 * 1024 * 1024, layoutCountLimit: 128)
    }

    /// 返回已完成的测量（含内边距），缺失时为 nil；渲染缓存被淘汰后尺寸仍可独立命中，等价内容项也可直接命中。
    @objc(cachedSizeForItem:size:traitCollection:)
    public func cachedSize(for item: TextForgeListItem, size: CGSize, traitCollection: UITraitCollection) -> NSValue? {
        sizes.object(forKey: Key(item.identity, size, 0, item.cacheTraits(for: traitCollection)))
    }

    /// 同步取得已驻留、同宽同倍率的布局；已验证的自适应行高也可命中。未命中返回 nil，不启动排版。
    @objc(cachedLayoutForItem:size:renderScale:traitCollection:)
    public func cachedLayout(for item: TextForgeListItem, size: CGSize, renderScale: CGFloat,
                             traitCollection: UITraitCollection) -> TextForgeLayout? {
        let key = Key(item.identity, size, renderScale.isFinite && renderScale > 0 ? renderScale : 0,
                      item.cacheTraits(for: traitCollection))
        return residentLayout(for: key, item: item)
    }

    /// 同步取得可直接显示的几何结果，可在仅测高和不同预绘倍率之间使用；位图被淘汰后回退到纯几何布局。
    @objc(cachedLayoutForItem:size:traitCollection:)
    public func cachedLayout(for item: TextForgeListItem, size: CGSize, traitCollection: UITraitCollection) -> TextForgeLayout? {
        let key = Key(item.identity, size, 0, item.cacheTraits(for: traitCollection))
        if let source = geometrySources.object(forKey: key), let layout = layouts.object(forKey: source) {
            return layout.binding(attributedText: item.attributedText, container: item.container,
                                  size: key.size, displayScale: traitCollection.displayScale)
        }
        return residentLayout(for: key, item: item)?.binding(
            attributedText: item.attributedText, container: item.container,
            size: key.size, displayScale: traitCollection.displayScale
        )
    }

    /// 别名只指向原缓存键，预绘位图淘汰后纯几何查询仍可从 geometryLayouts 取回排版引擎并绑定当前项的交互文本。
    private func residentLayout(for key: Key, item: TextForgeListItem) -> TextForgeLayout? {
        if let layout = layouts.object(forKey: key) {
            return layout.binding(attributedText: item.attributedText, container: item.container, size: key.size)
        }
        if let source = measuredAliases.object(forKey: key), let layout = layouts.object(forKey: source) {
            return layout.binding(attributedText: item.attributedText, container: item.container, size: key.size)
        }
        if key.scale == 0, let geometry = geometryLayouts.object(forKey: key) {
            return geometry.binding(attributedText: item.attributedText, container: item.container, size: key.size)
        }
        return nil
    }

    /// 命中也异步回到主线程。等价冷项可直接订阅在途排版，最后一位取消时终止工作；几何结果独立于位图预算。
    @discardableResult
    @objc(prepareItem:size:renderScale:traitCollection:completion:)
    public func prepare(_ item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traitCollection: UITraitCollection,
                        completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        let normalizedScale = renderScale.isFinite && renderScale > 0 ? renderScale : 0
        let key = Key(item.identity, size, normalizedScale, item.cacheTraits(for: traitCollection))
        if let layout = residentLayout(for: key, item: item) {
            let operation = Operation()
            DispatchQueue.main.async { if !operation.isCancelled { completion(layout) } }
            return TextForgeLayoutTask(operation: operation)
        }
        if pending[key] == nil, item.lastSnapshot == nil {
            return prepareCold(item, size: size, renderScale: renderScale, traits: traitCollection, completion: completion)
        }
        let operation = Operation()
        let id = UUID()
        let entry = pending[key] ?? Pending()
        entry.subscribers[id] = (operation, item, completion)
        let task = TextForgeLayoutTask(operation: operation) { [weak self, weak entry] in
            guard let self, let entry, self.pending[key] === entry else { return }
            entry.subscribers[id] = nil
            if entry.subscribers.isEmpty {
                self.pending[key] = nil
                entry.worker?.cancel()
            }
        }
        guard pending[key] == nil else { return task }
        pending[key] = entry
        entry.worker = TextForgeLayout.prepare(item: item, size: key.size, renderScale: normalizedScale, traitCollection: traitCollection) { layout in
            guard self.pending[key] === entry else { return }
            self.pending[key] = nil
            guard entry.subscribers.values.contains(where: { !$0.0.isCancelled }) else { return }
            let geometryKey = Key(item.identity, key.size, 0, key.traits)
            let measurement = NSValue(cgSize: layout.textBoundingSize)
            let geometryOnly = layout.withoutBitmap
            self.sizes.setObject(measurement, forKey: geometryKey)
            self.geometryLayouts.setObject(geometryOnly, forKey: geometryKey)
            let measured = CGSize(width: key.size.width, height: layout.textBoundingSize.height)
            let reusableHeight = measured != key.size && measured.height > 0 && layout.canReuseAtMeasuredHeight(measured.height)
            let measuredGeometryKey = Key(item.identity, measured, 0, key.traits)
            if reusableHeight {
                self.sizes.setObject(measurement, forKey: measuredGeometryKey)
                self.geometryLayouts.setObject(geometryOnly, forKey: measuredGeometryKey)
            }
            if layout.bitmapCost <= self.layouts.totalCostLimit {
                self.layouts.setObject(layout, forKey: key, cost: layout.bitmapCost)
                self.geometrySources.setObject(key, forKey: geometryKey)
                if reusableHeight {
                    self.geometrySources.setObject(key, forKey: measuredGeometryKey)
                    self.measuredAliases.setObject(key, forKey: Key(item.identity, measured, normalizedScale, key.traits))
                }
            }
            for (subscriber, subscriberItem, callback) in entry.subscribers.values where !subscriber.isCancelled {
                if subscriberItem.lastSnapshot == nil { subscriberItem.lastSnapshot = item.lastSnapshot }
                callback(layout.binding(attributedText: subscriberItem.attributedText, container: subscriberItem.container, size: key.size))
            }
        }
        return task
    }

    /// 同批等价项共享一次冻结；异外观的独立排版由 snapshot 校验并重新分离。最后一位离开时取消。
    private func prepareCold(_ item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traits: UITraitCollection,
                             completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        let id = UUID(), subscriber = ColdSubscriber()
        let batch = cold[item.identity] ?? ColdBatch()
        batch.start[id] = { snapshot in
            guard !subscriber.operation.isCancelled else { return }
            if item.lastSnapshot == nil { item.lastSnapshot = snapshot }
            subscriber.request = self.prepare(item, size: size, renderScale: renderScale, traitCollection: traits) { result in
                if !subscriber.operation.isCancelled { completion(result) }
                subscriber.request = nil
            }
        }
        if cold[item.identity] == nil {
            cold[item.identity] = batch
            Task { @MainActor in
                guard let snapshot = await item.snapshot(for: traits, operation: batch.operation),
                      self.cold[item.identity] === batch else { return }
                self.cold[item.identity] = nil
                for start in batch.start.values { start(snapshot) }
                batch.start.removeAll()
            }
        }
        let identity = item.identity
        return TextForgeLayoutTask(operation: subscriber.operation) { [weak self, weak batch] in
            subscriber.request?.cancel()
            subscriber.request = nil
            guard let self, let batch, self.cold[identity] === batch else { return }
            batch.start[id] = nil
            if batch.start.isEmpty {
                self.cold[identity] = nil
                batch.operation.cancel()
            }
        }
    }

    /// 清除已完成的尺寸与渲染条目；已订阅任务继续正常交付。
    @objc public func removeAllCachedResults() {
        layouts.removeAllObjects()
        geometryLayouts.removeAllObjects()
        sizes.removeAllObjects()
        measuredAliases.removeAllObjects()
        geometrySources.removeAllObjects()
    }
}
