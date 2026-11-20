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
        let original = NSAttributedString(attributedString: attributedText)
        let operation = Operation()
        let task = TextForgeLayoutTask(operation: operation)
        guard let detachedText = detachedTextForLayout(original, traits: traitCollection) else {
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                completion(TextForgeLayout(
                    attributedText: original, size: size, insets: insets,
                    maximumNumberOfRows: maximumNumberOfRows, lineBreakMode: lineBreakMode
                ))
            }
            return task
        }
        let input = TextForgeRenderingInput(text: detachedText, traits: traitCollection)
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
                        attributedText: input.text, size: size, insets: insets,
                        maximumNumberOfRows: maximumNumberOfRows, lineBreakMode: lineBreakMode
                    )
                    guard !operation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let image = engine.rasterize(scale: renderScale, traits: input.traits, viewport: size, insets: insets)
                    continuation.resume(returning: TextForgeLayoutHandoff(engine: engine, image: image))
                }
            }
            guard !operation.isCancelled, let handoff else { return }
            completion(TextForgeLayout(
                attributedText: original, size: size, insets: insets,
                maximumNumberOfRows: maximumNumberOfRows, lineBreakMode: lineBreakMode,
                engine: handoff.engine, preparedImage: handoff.image, preparedTraits: traitCollection
            ))
        }
        return task
    }

    private static let preparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TextForge.prepare"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// 在主线程分离绘制属性与交互对象。UIView 附件仅保留槽尺寸，动态颜色在当前外观下解析。
    private static func detachedTextForLayout(_ text: NSAttributedString, traits: UITraitCollection) -> NSAttributedString? {
        let detached = NSMutableAttributedString(string: text.string)
        var supported = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, stop in
            for (key, value) in attributes where key != TextForgeHighlight.attribute {
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

/// 只承载分离后的文本和 UIKit 不可变环境值，由单个后台操作读取。
private struct TextForgeRenderingInput: @unchecked Sendable {
    let text: NSAttributedString
    let traits: UITraitCollection
}

/// 工作线程完成全部操作后交接独占的 TextKit 实例，只有主线程会再访问其中的对象。
private struct TextForgeLayoutHandoff: @unchecked Sendable {
    let engine: TextForgeLayoutEngine
    let image: UIImage?
}
