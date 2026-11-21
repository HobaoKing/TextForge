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
        self.attributedText = NSAttributedString(attributedString: attributedText)
        self.container = container.copy() as! TextForgeContainer
    }

    /// 普通布局只取影响几何的环境值；自定义附件和自动定尺寸的图片变体保留完整环境。
    fileprivate func cacheTraits(for traits: UITraitCollection) -> UITraitCollection {
        let input = lastSnapshot ?? snapshot(for: traits)
        guard input.text != nil, input.supportsToken, !input.paint.requiresExactGeometry else { return traits }
        return UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: traits.preferredContentSizeCategory),
            UITraitCollection(layoutDirection: traits.layoutDirection),
            UITraitCollection(legibilityWeight: traits.legibilityWeight)
        ])
    }

    /// 保留最近一种环境的分离输入，换宽无需再扫描样式；无法分离的属性继续走主线程回退。
    func snapshot(for traits: UITraitCollection) -> Snapshot {
        if let lastSnapshot, lastSnapshot.paint.traits == traits { return lastSnapshot }
        let paint = TextForgePaintPalette(traits: traits)
        let text = TextForgeLayout.detachedTextForLayout(TextForgeLayout.renderingText(attributedText, container: container), paint: paint)
        let token = container.truncationToken.flatMap {
            TextForgeLayout.detachedTextForLayout(TextForgeLayout.renderingText($0, container: container), paint: paint)
        }
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

    private final class Pending {
        var subscribers: [UUID: (Operation, (TextForgeLayout) -> Void)] = [:]
        var worker: TextForgeLayoutTask?
    }

    private let layouts = NSCache<Key, TextForgeLayout>()
    private let sizes = NSCache<Key, NSValue>()
    private var pending: [Key: Pending] = [:]

    /// 渲染缓存的位图逻辑字节预算；系统也可提前淘汰。另有限制条数以覆盖纯排版结果。
    @objc public init(bitmapByteLimit: Int, layoutCountLimit: Int) {
        super.init()
        layouts.totalCostLimit = max(1, bitmapByteLimit)
        layouts.countLimit = max(1, layoutCountLimit)
        sizes.countLimit = 1024
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

    /// 命中也异步回到主线程。每个调用方可独立取消，最后一位订阅者取消后撤销底层工作。
    @discardableResult
    @objc(prepareItem:size:renderScale:traitCollection:completion:)
    public func prepare(_ item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traitCollection: UITraitCollection,
                        completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        let renderScale = renderScale.isFinite && renderScale > 0 ? renderScale : 0
        let geometry = item.cacheTraits(for: traitCollection)
        let key = Key(item.identity, size, renderScale, geometry)
        let operation = Operation()
        if let layout = layouts.object(forKey: key) {
            DispatchQueue.main.async { if !operation.isCancelled { completion(layout) } }
            return TextForgeLayoutTask(operation: operation)
        }
        let id = UUID()
        let entry = pending[key] ?? Pending()
        entry.subscribers[id] = (operation, completion)
        let task = TextForgeLayoutTask(operation: operation) { [weak self, weak entry] in
            Task { @MainActor in
                guard let self, let entry, self.pending[key] === entry else { return }
                entry.subscribers[id] = nil
                if entry.subscribers.isEmpty {
                    self.pending[key] = nil
                    entry.worker?.cancel()
                }
            }
        }
        guard pending[key] == nil else { return task }
        pending[key] = entry
        entry.worker = TextForgeLayout.prepare(item: item, size: key.size, renderScale: renderScale, traitCollection: traitCollection) { layout in
            guard self.pending[key] === entry else { return }
            self.pending[key] = nil
            guard entry.subscribers.values.contains(where: { !$0.0.isCancelled }) else { return }
            if layout.bitmapCost <= self.layouts.totalCostLimit {
                self.layouts.setObject(layout, forKey: key, cost: layout.bitmapCost)
            }
            self.sizes.setObject(NSValue(cgSize: layout.textBoundingSize), forKey: Key(item.identity, size, 0, geometry))
            for (subscriber, callback) in entry.subscribers.values where !subscriber.isCancelled { callback(layout) }
        }
        return task
    }

    /// 清除已完成的尺寸与渲染条目；已订阅任务继续正常交付。
    @objc public func removeAllCachedResults() {
        layouts.removeAllObjects()
        sizes.removeAllObjects()
    }
}
