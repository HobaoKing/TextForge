import UIKit

/// 一行的不可变内容版本。正文、交互、附件或排版样式变化时创建新项；跨宽度和 Cell 保留同一实例。
@MainActor
@objc(TextForgeListItem)
public final class TextForgeListItem: NSObject {
    @objc public let attributedText: NSAttributedString
    fileprivate let identity = NSObject()
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

    /// 普通布局只取影响几何的环境值；自定义附件和自动定尺寸的图片变体保留完整环境。
    fileprivate func cacheTraits(for traits: UITraitCollection) -> UITraitCollection {
        guard let input = lastSnapshot, input.text != nil, input.supportsToken, !input.paint.requiresExactGeometry else { return traits }
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

/// 列表拥有的缓存。尺寸与渲染结果独立淘汰，相同的预取和可见 Cell 请求共享一次排版。
@MainActor
@objc(TextForgeListLayoutCache)
public final class TextForgeListLayoutCache: NSObject {
    private final class Key: NSObject {
        // 保留轻量身份，避免条目释放后地址被下一行复用；尺寸缓存无需持有富文本或视图。
        let identity: NSObject
        let size: CGSize
        let scale: CGFloat
        let traits: UITraitCollection

        /// 将 NaN 所在轴按引擎规则归零，使测量、预取和取消能用同一把可比较的键找回请求。
        init(_ identity: NSObject, _ size: CGSize, _ scale: CGFloat, _ traits: UITraitCollection) {
            self.identity = identity
            self.size = CGSize(width: size.width.isNaN ? 0 : size.width, height: size.height.isNaN ? 0 : size.height)
            self.scale = scale
            self.traits = traits
        }

        /// 键区分内容版本、约束、预绘倍率与外观，防止跨行或跨宽误用结果。
        override var hash: Int {
            var h = Hasher()
            h.combine(ObjectIdentifier(identity))
            h.combine(size.width)
            h.combine(size.height)
            h.combine(scale)
            h.combine(traits.hash)
            return h.finalize()
        }

        /// 与哈希采用相同字段；等价的 UIKit 环境值可共享结果。
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return identity === other.identity && size == other.size && scale == other.scale && traits == other.traits
        }
    }

    @MainActor private final class Pending {
        var subscribers: [UUID: (Operation, (TextForgeLayout) -> Void)] = [:]
        var worker: TextForgeLayoutTask?
    }

    /// 首次分离前尚不清楚附件是否依赖完整外观；先按内容收集请求，确认后再按真正的几何键分发。
    @MainActor private final class ColdBatch {
        let operation = Operation()
        var start: [UUID: () -> Void] = [:]
    }

    @MainActor private final class ColdSubscriber {
        let operation = Operation()
        var request: TextForgeLayoutTask?
    }

    private var cold: [NSObject: ColdBatch] = [:]
    private let layouts = NSCache<Key, TextForgeLayout>()
    private let sizes = NSCache<Key, NSValue>()
    private let geometrySources = NSCache<Key, Key>()
    private let measuredAliases = NSCache<Key, Key>()
    private var pending: [Key: Pending] = [:]

    /// 渲染缓存的位图逻辑字节预算；系统也可提前淘汰。另有限制条数以覆盖纯排版结果。
    @objc public init(bitmapByteLimit: Int, layoutCountLimit: Int) {
        super.init()
        layouts.totalCostLimit = max(1, bitmapByteLimit)
        layouts.countLimit = max(1, layoutCountLimit)
        sizes.countLimit = 1024
        geometrySources.countLimit = 1024
        measuredAliases.countLimit = max(1, layoutCountLimit)
    }

    @objc public override convenience init() {
        self.init(bitmapByteLimit: 16 * 1024 * 1024, layoutCountLimit: 128)
    }

    /// 返回已完成的测量（含内边距），缺失时为 nil；渲染缓存被淘汰后尺寸仍可独立命中。
    @objc(cachedSizeForItem:size:traitCollection:)
    public func cachedSize(for item: TextForgeListItem, size: CGSize, traitCollection: UITraitCollection) -> NSValue? {
        guard item.lastSnapshot != nil else { return nil }
        return sizes.object(forKey: Key(item.identity, size, 0, item.cacheTraits(for: traitCollection)))
    }

    /// 同步取得已驻留、同宽同倍率的布局；已验证的自适应行高也可命中。未命中返回 nil，不启动排版。
    @objc(cachedLayoutForItem:size:renderScale:traitCollection:)
    public func cachedLayout(for item: TextForgeListItem, size: CGSize, renderScale: CGFloat,
                             traitCollection: UITraitCollection) -> TextForgeLayout? {
        let key = Key(item.identity, size, renderScale.isFinite && renderScale > 0 ? renderScale : 0,
                      item.cacheTraits(for: traitCollection))
        return residentLayout(for: key)
    }

    /// 同步取得可直接显示的几何结果，可在仅测高和不同预绘倍率之间使用；位图仍按显示环境校验。
    @objc(cachedLayoutForItem:size:traitCollection:)
    public func cachedLayout(for item: TextForgeListItem, size: CGSize, traitCollection: UITraitCollection) -> TextForgeLayout? {
        let key = Key(item.identity, size, 0, item.cacheTraits(for: traitCollection))
        guard let source = geometrySources.object(forKey: key), let layout = layouts.object(forKey: source) else { return nil }
        return layout.withSize(key.size, displayScale: traitCollection.displayScale)
    }

    /// 别名只指向原缓存键，真正的位图和排版仍受同一预算控制；公开结果保留调用方请求的尺寸。
    private func residentLayout(for key: Key) -> TextForgeLayout? {
        if let layout = layouts.object(forKey: key) { return layout }
        guard let source = measuredAliases.object(forKey: key), let layout = layouts.object(forKey: source) else { return nil }
        return layout.withSize(key.size)
    }

    /// 命中也异步回到主线程。每个调用方可独立取消，最后一位订阅者取消后撤销底层工作。
    @discardableResult
    @objc(prepareItem:size:renderScale:traitCollection:completion:)
    public func prepare(_ item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traitCollection: UITraitCollection,
                        completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        if item.lastSnapshot == nil {
            return prepareCold(item, size: size, renderScale: renderScale, traits: traitCollection, completion: completion)
        }
        let renderScale = renderScale.isFinite && renderScale > 0 ? renderScale : 0
        let geometry = item.cacheTraits(for: traitCollection)
        let key = Key(item.identity, size, renderScale, geometry)
        let operation = Operation()
        if let layout = residentLayout(for: key) {
            DispatchQueue.main.async { if !operation.isCancelled { completion(layout) } }
            return TextForgeLayoutTask(operation: operation)
        }
        let id = UUID()
        let entry = pending[key] ?? Pending()
        entry.subscribers[id] = (operation, completion)
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
        entry.worker = TextForgeLayout.prepare(item: item, size: key.size, renderScale: renderScale, traitCollection: traitCollection) { layout in
            guard self.pending[key] === entry else { return }
            self.pending[key] = nil
            guard entry.subscribers.values.contains(where: { !$0.0.isCancelled }) else { return }
            let traits = item.cacheTraits(for: traitCollection)
            let source = Key(item.identity, key.size, renderScale, traits)
            let measurement = NSValue(cgSize: layout.textBoundingSize)
            self.sizes.setObject(measurement, forKey: Key(item.identity, key.size, 0, traits))
            let measured = CGSize(width: key.size.width, height: layout.textBoundingSize.height)
            let reusableHeight = measured != key.size && measured.height > 0 && layout.canReuseAtMeasuredHeight(measured.height)
            if reusableHeight {
                self.sizes.setObject(measurement, forKey: Key(item.identity, measured, 0, traits))
            }
            if layout.bitmapCost <= self.layouts.totalCostLimit {
                self.layouts.setObject(layout, forKey: source, cost: layout.bitmapCost)
                self.geometrySources.setObject(source, forKey: Key(item.identity, key.size, 0, traits))
                if reusableHeight {
                    self.geometrySources.setObject(source, forKey: Key(item.identity, measured, 0, traits))
                    self.measuredAliases.setObject(source, forKey: Key(item.identity, measured, renderScale, traits))
                }
            }
            for (subscriber, callback) in entry.subscribers.values where !subscriber.isCancelled { callback(layout) }
        }
        return task
    }

    /// 同一列表项只冻结一次初始样式。等候者可独立取消，最后一位离开时停止尚未完成的分离。
    private func prepareCold(_ item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traits: UITraitCollection,
                             completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        let id = UUID(), subscriber = ColdSubscriber()
        let batch = cold[item.identity] ?? ColdBatch()
        batch.start[id] = {
            guard !subscriber.operation.isCancelled else { return }
            subscriber.request = self.prepare(item, size: size, renderScale: renderScale, traitCollection: traits) { result in
                if !subscriber.operation.isCancelled { completion(result) }
                subscriber.request = nil
            }
        }
        if cold[item.identity] == nil {
            cold[item.identity] = batch
            Task { @MainActor in
                _ = await item.snapshot(for: traits, operation: batch.operation)
                guard self.cold[item.identity] === batch else { return }
                self.cold[item.identity] = nil
                for start in batch.start.values { start() }
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
        sizes.removeAllObjects()
        measuredAliases.removeAllObjects()
        geometrySources.removeAllObjects()
    }
}
