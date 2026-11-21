import UIKit

/// 在主线程请求一张图片，宿主可从任意线程返回图片或 nil（失败），并可返回撤销此次请求的闭包。
public typealias TextForgeHTMLImageLoader = @MainActor (URL, @escaping @Sendable (UIImage?) -> Void) -> (() -> Void)?
public typealias TextForgeHTMLCompletion = @MainActor @Sendable (NSAttributedString?, Error?) -> Void

/// 一批图片更新。位置为当前快照中的 UTF-16 附件下标，每个位置长度为 1。
@objc(TextForgeHTMLImageUpdate)
public final class TextForgeHTMLImageUpdate: NSObject {
    @objc public let attributedText: NSAttributedString
    @objc public let changedIndexes: IndexSet
    @objc public let didChangeSize: Bool
    @objc public let isInitial: Bool
    @objc public let isFinal: Bool

    init(text: NSAttributedString, indexes: IndexSet, resized: Bool, initial: Bool, final: Bool) {
        attributedText = text
        changedIndexes = indexes
        didChangeSize = resized
        isInitial = initial
        isFinal = final
    }
}

/// 一次 HTML 导入及其图片请求。取消会撤销尚未完成的宿主请求，之后不再投递快照或完成回调。
@MainActor
@objc(TextForgeHTMLImportTask)
public final class TextForgeHTMLImportTask: NSObject {
    @objc public private(set) var isCancelled = false
    private var cancellations: [URL: () -> Void] = [:]
    private var imageLoader: TextForgeHTMLImageLoader?
    private var preparation: Task<TextForgeHTMLDocument, Error>?
    private var text: NSMutableAttributedString?
    private var positions: [URL: [(NSRange, TextForgeHTMLImageSlot)]] = [:]
    private var update: (@MainActor (NSAttributedString) -> Void)?
    private var imageUpdate: (@MainActor (TextForgeHTMLImageUpdate) -> Void)?
    private var changedIndexes = IndexSet()
    private var didChangeSize = false
    private var flushScheduled = false
    private var completion: TextForgeHTMLCompletion?
    private let maximumWidth: CGFloat
    private let placeholderSize: CGSize
    private let placeholder: UIImage

    /// 在调用入口快照尺寸、样式和回调，调用端之后可继续修改和复用阅读配置。
    init(style: TextForgeHTMLReadingStyle, imageLoader: TextForgeHTMLImageLoader?, update: (@MainActor (NSAttributedString) -> Void)?,
         imageUpdate: (@MainActor (TextForgeHTMLImageUpdate) -> Void)?, completion: @escaping TextForgeHTMLCompletion) {
        maximumWidth = style.maximumImageWidth.isFinite ? max(0, style.maximumImageWidth) : 0
        let size = style.placeholderSize
        placeholderSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            ? size : CGSize(width: 24, height: 24)
        placeholder = style.placeholderImage ?? Self.transparentPixel
        self.imageLoader = imageLoader
        self.imageUpdate = imageUpdate
        self.update = update
        self.completion = completion
    }

    private static let transparentPixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// 可在更新回调内取消。先清理本地状态，再通知宿主，取消过程中的同步回调也不会重新投递。
    @objc public func cancel() {
        guard completion != nil else { return }
        isCancelled = true
        preparation?.cancel()
        let pending = Array(cancellations.values)
        finish(nil)
        for cancel in pending { cancel() }
    }

    /// DOM 解析由后台任务独占。保留句柄，使 Cell 在预处理期间复用时也能及时停止遍历。
    func prepare(_ html: String, baseURL: URL?, css: String, takesImages: Bool) async throws -> TextForgeHTMLDocument {
        guard !isCancelled else { throw CancellationError() }
        let worker = Task.detached(priority: .userInitiated) {
            try TextForgeHTMLDocument.prepare(html, baseURL: baseURL, css: css, takesImages: takesImages)
        }
        preparation = worker
        defer { preparation = nil }
        return try await worker.value
    }

    /// 只交付一次最终结果，并释放闭包与排版内容。取消后屏蔽所有交付。
    func finish(_ error: Error?, snapshot: NSAttributedString? = nil) {
        let callback = completion
        let result = isCancelled ? nil : snapshot ?? text.map { NSAttributedString(attributedString: $0) }
        completion = nil
        imageLoader = nil
        update = nil
        imageUpdate = nil
        changedIndexes.removeAll()
        text = nil
        positions.removeAll()
        cancellations.removeAll()
        if !isCancelled { callback?(result, error) }
    }

    /// 只为实际导入的可见附件发起请求。相同 URL 共用一次加载，各位置保留自己的尺寸与 alt。
    func load(_ source: NSAttributedString, slots: [String: TextForgeHTMLImageSlot]) {
        guard !isCancelled else { return }
        let body = NSMutableAttributedString(attributedString: source)
        text = body
        let full = NSRange(location: 0, length: body.length)
        source.enumerateAttribute(.link, in: full) { link, range, _ in
            if link != nil { body.addAttribute(TextForgeHTML.styledLink, value: true, range: range) }
        }
        source.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let key = attachment.accessibilityLabel, let slot = slots[key] {
                let copy = self.attachment(self.placeholder, slot: slot, intrinsic: self.placeholderSize)
                body.addAttribute(.attachment, value: copy, range: range)
                if let url = slot.url { self.positions[url, default: []].append((range, slot)) }
            } else if self.maximumWidth > 0 {
                // 系统导入的图片可能只保存在 fileWrapper 中；仅在需要限制尺寸时解析原始尺寸。
                let size = attachment.bounds.size
                let image = attachment.image ?? attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: range.location)
                let intrinsic = size.width > 0 && size.height > 0 ? size : image?.size ?? .zero
                if let image, intrinsic.width > self.maximumWidth {
                    let slot = TextForgeHTMLImageSlot(url: nil, alt: attachment.accessibilityLabel, width: nil, height: nil)
                    let copy = self.attachment(image, slot: slot, intrinsic: intrinsic)
                    copy.bounds.origin = attachment.bounds.origin
                    body.addAttribute(.attachment, value: copy, range: range)
                }
            }
        }
        let loader = imageLoader
        imageLoader = nil
        guard let loader, !positions.isEmpty else { finish(nil); return }
        if update != nil || imageUpdate != nil {
            let initial = NSAttributedString(attributedString: body)
            update?(initial)
            imageUpdate?(TextForgeHTMLImageUpdate(text: initial, indexes: [], resized: false, initial: true, final: false))
        }
        for url in Array(positions.keys) {
            guard !isCancelled else { return }
            let cancel = loader(url) { image in
                DispatchQueue.main.async { self.receive(image, for: url) }
            }
            if isCancelled { cancel?(); return }
            cancellations[url] = cancel
        }
    }

    /// 新建附件保证已投递快照的尺寸和图像不被后续结果修改。
    private func attachment(_ image: UIImage, slot: TextForgeHTMLImageSlot, intrinsic: CGSize) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: slot.size(for: intrinsic, maximumWidth: maximumWidth))
        attachment.accessibilityLabel = slot.alt
        return attachment
    }

    /// 已完成、重复或取消后的 URL 不再交付。成功时记录各位置的真实尺寸变化，失败保留原占位。
    private func receive(_ image: UIImage?, for url: URL) {
        guard let matches = positions.removeValue(forKey: url), let text else { return }
        cancellations[url] = nil
        if let image, image.size.width > 0, image.size.height > 0 {
            for (range, slot) in matches {
                let previous = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                let replacement = attachment(image, slot: slot, intrinsic: image.size)
                didChangeSize = didChangeSize || previous?.bounds.size != replacement.bounds.size
                changedIndexes.insert(integersIn: range.location..<NSMaxRange(range))
                text.addAttribute(.attachment, value: replacement, range: range)
            }
        }
        if positions.isEmpty {
            flushImages(final: true)
        } else if !flushScheduled, !changedIndexes.isEmpty, update != nil || imageUpdate != nil {
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushImages(final: false) }
        }
    }

    /// 同一主队列批次只复制一次文本。末批与 completion 共享快照，回调内取消会屏蔽后续交付。
    private func flushImages(final: Bool) {
        flushScheduled = false
        guard let text, final || !changedIndexes.isEmpty else { return }
        let snapshot = NSAttributedString(attributedString: text)
        let indexes = changedIndexes
        let resized = didChangeSize
        changedIndexes.removeAll()
        didChangeSize = false
        if !final { update?(snapshot) }
        imageUpdate?(TextForgeHTMLImageUpdate(text: snapshot, indexes: indexes, resized: resized, initial: false, final: final))
        if final { finish(nil, snapshot: snapshot) }
    }
}
