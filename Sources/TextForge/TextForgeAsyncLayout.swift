import UIKit

/// 可取消一次预排版。取消后停止投递结果，已进入的单次 TextKit 调用会正常退出。
@objc(TextForgeLayoutTask)
public final class TextForgeLayoutTask: NSObject, Sendable {
    private let operation: Operation

    private let onCancel: (@MainActor @Sendable () -> Void)?

    init(operation: Operation, onCancel: (@MainActor @Sendable () -> Void)? = nil) {
        self.onCancel = onCancel
        self.operation = operation
    }

    @objc public var isCancelled: Bool { operation.isCancelled }

    /// 立即阻止交付（可从任意线程调用），订阅表与共享任务的清理在主线程执行。
    @objc public func cancel() {
        operation.cancel()
        if let onCancel { Task { @MainActor in onCancel() } }
    }
}

extension TextForgeLayout {
    /// 以点为单位指定外部边界。renderScale 大于 0 时尝试预绘制；关闭时只排版。
    /// 回调在主线程执行，取消后不交付结果。自定义属性或附件需要时回退到主线程排版。
    @objc public static func prepare(
        attributedText: NSAttributedString,
        size: CGSize,
        insets: UIEdgeInsets,
        maximumNumberOfRows: Int,
        lineBreakMode: NSLineBreakMode,
        renderScale: CGFloat,
        traitCollection: UITraitCollection,
        completion: @escaping (TextForgeLayout) -> Void
    ) -> TextForgeLayoutTask {
        let container = TextForgeContainer(size: size, insets: insets)
        container.maximumNumberOfRows = maximumNumberOfRows
        container.lineBreakMode = lineBreakMode
        return prepare(
            attributedText: attributedText, container: container,
            renderScale: renderScale, traitCollection: traitCollection, completion: completion
        )
    }

    /// 按容器配置在后台预排版，支持截断标记、排除路径和链接外观。renderScale 大于 0 时尝试预绘制。
    /// 回调在主线程执行，取消后不交付结果。正文或截断标记含无法分离的自定义属性时回退到主线程同步排版。
    @objc public static func prepare(
        attributedText: NSAttributedString,
        container: TextForgeContainer,
        renderScale: CGFloat,
        traitCollection: UITraitCollection,
        completion: @escaping (TextForgeLayout) -> Void
    ) -> TextForgeLayoutTask {
        let item = TextForgeListItem(attributedText: attributedText, container: container)
        return prepare(item: item, size: container.size, renderScale: renderScale, traitCollection: traitCollection, completion: completion)
    }

    /// 同一列表项跨尺寸复用已分离的正文和标记，工作线程仍各自独占 TextKit 引擎。
    static func prepare(item: TextForgeListItem, size: CGSize, renderScale: CGFloat, traitCollection: UITraitCollection,
                        completion: @escaping (TextForgeLayout) -> Void) -> TextForgeLayoutTask {
        let original = item.attributedText
        let container = item.container.copy() as! TextForgeContainer
        container.size = size
        let operation = Operation()
        let task = TextForgeLayoutTask(operation: operation)
        Task { @MainActor in
            guard !operation.isCancelled, let snapshot = await item.snapshot(for: traitCollection, operation: operation),
                  !operation.isCancelled else { return }
            guard let detachedText = snapshot.text, snapshot.supportsToken else {
                completion(TextForgeLayout(container: container, attributedText: original, fallbackTraits: traitCollection))
                return
            }
            let input = TextForgeRenderingInput(text: detachedText, token: snapshot.token,
                                               parameters: parameters(for: container), traits: traitCollection)
            // 原始富文本和回调保留在主线程任务中，工作队列只接收分离后的排版数据。
            let handoff = await withCheckedContinuation { (continuation: CheckedContinuation<TextForgeLayoutHandoff?, Never>) in
                preparationQueue.addOperation {
                    guard !operation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    input.traits.performAsCurrent {
                        let engine = TextForgeLayoutEngine(
                            text: input.text, truncationToken: input.token, parameters: input.parameters
                        )
                        guard !operation.isCancelled else {
                            continuation.resume(returning: nil)
                            return
                        }
                        engine.prepareDrawingBounds()
                        guard !operation.isCancelled else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let image = engine.rasterize(
                            scale: renderScale, traits: input.traits
                        )
                        continuation.resume(returning: TextForgeLayoutHandoff(engine: engine, image: image))
                    }
                }
            }
            guard !operation.isCancelled, let handoff else { return }
            completion(TextForgeLayout(
                attributedText: original, container: container,
                engine: handoff.engine, preparedImage: handoff.image, preparedTraits: traitCollection, paint: snapshot.paint
            ))
        }
        return task
    }

    /// 限制同时准备的 TextKit 排版栈数量，降低滚动期间的 CPU 和位图内存峰值。
    private static let preparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TextForge.prepare"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// 按属性段冻结主线程对象。长文分批让出主线程，后台仅接收已分离的值并组装排版串。
    static func detachedTextForLayout(_ text: NSAttributedString, container: TextForgeContainer,
                                      paint: TextForgePaintPalette, operation: Operation) async -> NSAttributedString? {
        var runs: [TextForgeFrozenRun] = []
        // 相同的属性字典在多段间常被复用；仅冻结一次，保留原字典防止自定义字符串临时对象地址复用。
        var styles: [ObjectIdentifier: (source: NSDictionary, frozen: [NSAttributedString.Key: Any])] = [:]
        var index = 0
        var sliceStart = CACurrentMediaTime()
        while index < text.length {
            guard !operation.isCancelled else { return nil }
            if CACurrentMediaTime() - sliceStart >= 0.00075 {
                await Task.yield()
                sliceStart = CACurrentMediaTime()
            }
            var effective = CFRange()
            let source = CFAttributedStringGetAttributes(text as CFAttributedString, index, &effective)! as NSDictionary
            let range = NSRange(location: effective.location, length: effective.length)
            index = NSMaxRange(range)
            let identity = ObjectIdentifier(source)
            if let cached = styles[identity] {
                runs.append(TextForgeFrozenRun(range: range, attributes: cached.frozen))
                continue
            }
            var attributes = text.attributes(at: range.location, effectiveRange: nil)
            if attributes.removeValue(forKey: .link) != nil,
               container.hasExplicitLinkStyle || attributes[TextForgeHTML.styledLink] == nil {
                attributes.merge(container.linkTextAttributes) { _, override in override }
            }
            attributes.removeValue(forKey: TextForgeHighlight.attributeName)
            var frozen = attributes
            for (key, value) in attributes {
                let copied: Any
                switch value {
                case is UIColor, is NSShadow, is TextForgeBackground:
                    guard let entry = paint.entry(for: value as! NSObject, key: key) else { return nil }
                    copied = entry.resolved
                    if let index = entry.index { frozen[TextForgePaintPalette.marker(for: key)] = index }
                case let paragraph as NSParagraphStyle:
                    copied = paragraph.copy()
                case let attachment as TextForgeViewAttachment:
                    let slot = NSTextAttachment()
                    slot.image = TextForgeViewAttachment.blankImage
                    slot.bounds = attachment.bounds
                    copied = slot
                case let attachment as NSTextAttachment where type(of: attachment) == NSTextAttachment.self:
                    paint.hasImages = true
                    let contents = attachment.contents
                    let image = NSTextAttachment(data: contents, ofType: attachment.fileType)
                    if let bitmap = attachment.image {
                        if bitmap.imageAsset != nil, attachment.bounds.size == .zero { paint.requiresExactGeometry = true }
                        image.image = bitmap
                    } else if contents == nil, let wrapper = attachment.fileWrapper {
                        guard wrapper.isRegularFile, let data = wrapper.regularFileContents else {
                            return nil
                        }
                        let file = FileWrapper(regularFileWithContents: data)
                        file.preferredFilename = wrapper.preferredFilename ?? wrapper.filename
                        image.fileWrapper = file
                    }
                    image.bounds = attachment.bounds
                    copied = image
                case is UIFont, is NSNumber, is URL:
                    continue
                case let directions as [NSNumber]:
                    copied = directions
                case let string as NSString:
                    copied = string.copy()
                default:
                    return nil
                }
                frozen[key] = copied
            }
            styles[identity] = (source, frozen)
            runs.append(TextForgeFrozenRun(range: range, attributes: frozen))
        }
        let string = text.string
        if runs.count <= 1 { return NSAttributedString(string: string, attributes: runs.first?.attributes) }
        let frozenRuns = runs
        let assembled = await withCheckedContinuation { (done: CheckedContinuation<TextForgeFrozenText?, Never>) in
            preparationQueue.addOperation {
                let result = NSMutableAttributedString(string: string)
                result.beginEditing()
                for run in frozenRuns {
                    if operation.isCancelled { break }
                    result.setAttributes(run.attributes, range: run.range)
                }
                result.endEditing()
                done.resume(returning: operation.isCancelled ? nil : TextForgeFrozenText(value: result.copy() as! NSAttributedString))
            }
        }
        return assembled?.value
    }
}

/// 只携带复制后的样式、附件槽及不可变 Foundation 值，后台组装时不访问宿主视图、颜色提供者或回调。
private struct TextForgeFrozenRun: @unchecked Sendable {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
}

/// 后台填充完毕才交接不可变富文本，属性遵循 FrozenRun 的同一隔离边界。
private struct TextForgeFrozenText: @unchecked Sendable {
    let value: NSAttributedString
}

/// 只承载分离后的文本、已复制的路径和 UIKit 不可变环境值，由单个后台操作读取。
private struct TextForgeRenderingInput: @unchecked Sendable {
    let text: NSAttributedString
    let token: NSAttributedString?
    let parameters: TextForgeLayoutParameters
    let traits: UITraitCollection
}

/// 工作线程完成全部操作后交接独占的 TextKit 实例，只有主线程会再访问其中的对象。
private struct TextForgeLayoutHandoff: @unchecked Sendable {
    let engine: TextForgeLayoutEngine
    let image: UIImage?
}
