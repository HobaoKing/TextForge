import UIKit

/// 可取消一次预排版。取消后停止投递结果，已进入的单次 TextKit 调用会正常退出。
@objc(TextForgeLayoutTask)
public final class TextForgeLayoutTask: NSObject, Sendable {
    private let operation: Operation

    init(operation: Operation) {
        self.operation = operation
    }

    @objc public var isCancelled: Bool { operation.isCancelled }

    /// 取消尚未完成的请求，包括等待回到主线程的结果。
    @objc public func cancel() {
        operation.cancel()
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
        let original = NSAttributedString(attributedString: attributedText)
        let container = container.copy() as? TextForgeContainer ?? container
        let operation = Operation()
        let task = TextForgeLayoutTask(operation: operation)
        let detachedText = detachedTextForLayout(
            renderingText(original, linkTextAttributes: container.linkTextAttributes), traits: traitCollection
        )
        let detachedToken = container.truncationToken.map {
            detachedTextForLayout(
                renderingText($0, linkTextAttributes: container.linkTextAttributes), traits: traitCollection
            )
        }
        guard let detachedText, detachedToken.map({ $0 != nil }) ?? true else {
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                completion(TextForgeLayout(container: container, attributedText: original))
            }
            return task
        }
        let input = TextForgeRenderingInput(
            text: detachedText, token: detachedToken ?? nil,
            parameters: parameters(for: container), traits: traitCollection
        )
        Task { @MainActor in
            guard !operation.isCancelled else { return }
            // 原始富文本和回调保留在主线程任务中，工作队列只接收分离后的排版数据。
            let handoff = await withCheckedContinuation { (continuation: CheckedContinuation<TextForgeLayoutHandoff?, Never>) in
                preparationQueue.addOperation {
                    guard !operation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let engine = TextForgeLayoutEngine(
                        text: input.text, truncationToken: input.token, parameters: input.parameters
                    )
                    guard !operation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let image = engine.rasterize(
                        scale: renderScale, traits: input.traits,
                        viewport: input.parameters.size, insets: input.parameters.insets
                    )
                    continuation.resume(returning: TextForgeLayoutHandoff(engine: engine, image: image))
                }
            }
            guard !operation.isCancelled, let handoff else { return }
            completion(TextForgeLayout(
                attributedText: original, container: container,
                engine: handoff.engine, preparedImage: handoff.image, preparedTraits: traitCollection
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

    /// 在主线程分离绘制属性与交互对象。UIView 附件仅保留槽尺寸，动态颜色在当前外观下解析。
    /// 遇到无法安全复制的属性值时返回 nil，由调用方改走主线程同步排版。
    private static func detachedTextForLayout(_ text: NSAttributedString, traits: UITraitCollection) -> NSAttributedString? {
        let detached = NSMutableAttributedString(string: text.string)
        var supported = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, stop in
            for (key, value) in attributes where key != TextForgeHighlight.attributeName {
                let copied: Any
                switch value {
                case let color as UIColor:
                    copied = color.resolvedColor(with: traits)
                case let paragraph as NSParagraphStyle:
                    copied = paragraph.copy()
                case let shadow as NSShadow:
                    let copy = NSShadow()
                    copy.shadowOffset = shadow.shadowOffset
                    copy.shadowBlurRadius = shadow.shadowBlurRadius
                    if let color = shadow.shadowColor {
                        guard let uiColor = color as? UIColor else {
                            supported = false
                            stop.pointee = true
                            return
                        }
                        copy.shadowColor = uiColor.resolvedColor(with: traits)
                    }
                    copied = copy
                case let background as TextForgeBackground:
                    copied = background.resolved(with: traits)
                case let attachment as TextForgeViewAttachment:
                    let slot = NSTextAttachment()
                    slot.bounds = attachment.bounds
                    copied = slot
                case let attachment as NSTextAttachment where type(of: attachment) == NSTextAttachment.self:
                    let image = NSTextAttachment(data: attachment.contents, ofType: attachment.fileType)
                    image.image = attachment.image
                    image.bounds = attachment.bounds
                    copied = image
                case is UIFont, is NSNumber, is URL:
                    copied = value
                case let directions as [NSNumber]:
                    copied = directions
                case let string as NSString:
                    copied = string.copy()
                default:
                    supported = false
                    stop.pointee = true
                    return
                }
                detached.addAttribute(key, value: copied, range: range)
            }
        }
        return supported ? NSAttributedString(attributedString: detached) : nil
    }
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
