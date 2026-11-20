import TextForge
import UIKit

@main
final class ExampleApp: UIResponder, UIApplicationDelegate {
    /// 为独立 Swift 示例配置 Scene，集中创建窗口。
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = ExampleScene.self
        return configuration
    }
}

final class ExampleScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// 用当前 Scene 的窗口显示示例控件，并保留窗口直到 Scene 结束。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ExampleViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ExampleViewController: UIViewController {
    private let label = TextForgeLabel()
    private let input = TextForgeTextView()
    private let status = UILabel()
    private var received: [String] = []
    private var verified = false

    /// 展示富文本和占位文案，将输入框的文本回调直接显示在状态标签。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.contentInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        label.backgroundColor = .secondarySystemBackground
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(
            string: "TextForge · Swift",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]
        )
        input.font = .preferredFont(forTextStyle: .body)
        input.placeholder = "输入文字，查看变化回调"
        input.backgroundColor = .secondarySystemBackground
        input.onTextChange = { [weak self] text in
            self?.received.append(text)
            self?.status.text = text
        }

        let stack = UIStackView(arrangedSubviews: [label, input, status])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            input.heightAnchor.constraint(equalToConstant: 80)
        ])
    }

    /// 窗口出现后验证尺寸、占位和输入法提交语义，将结果写给示例验证脚本。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.arguments.contains("--verify"), !verified else { return }
        verified = true

        let unpadded = UILabel()
        unpadded.numberOfLines = label.numberOfLines
        unpadded.attributedText = label.attributedText
        let size = label.intrinsicContentSize
        let baseSize = unpadded.intrinsicContentSize
        let fitted = label.sizeThatFits(CGSize(width: 120, height: 1_000))
        let baseFit = unpadded.sizeThatFits(CGSize(width: 96, height: 984))
        let textRect = label.textRect(forBounds: CGRect(x: 0, y: 0, width: 120, height: 1_000), limitedToNumberOfLines: 0)
        let plainRect = unpadded.textRect(forBounds: CGRect(x: 12, y: 8, width: 96, height: 984), limitedToNumberOfLines: 0)
        var failures: [String] = []
        if abs(size.width - baseSize.width - 24) > 1 || abs(size.height - baseSize.height - 16) > 1 {
            failures.append("intrinsic size: \(size), plain: \(baseSize)")
        }
        if abs(fitted.width - baseFit.width - 24) > 1 || abs(fitted.height - baseFit.height - 16) > 1 {
            failures.append("fitted size: \(fitted), plain: \(baseFit)")
        }
        if abs(textRect.width - plainRect.width - 24) > 1 || abs(textRect.height - plainRect.height - 16) > 1 {
            failures.append("text rect: \(textRect), plain: \(plainRect)")
        }
        failures.append(contentsOf: verifyRichText())
        input.placeholderFont = .systemFont(ofSize: 19, weight: .semibold)
        input.placeholderTextColor = .purple
        input.layoutIfNeeded()
        let placeholder = input.subviews.compactMap { $0 as? UILabel }.first { $0.text == input.placeholder }
        if placeholder?.isHidden != false { failures.append("placeholder missing on empty text") }
        if placeholder?.font.pointSize != 19 || placeholder?.textColor != .purple {
            failures.append("placeholder did not adopt the configured font and color")
        }
        let richPlaceholder = NSAttributedString(string: "富文本占位", attributes: [.foregroundColor: UIColor.orange])
        input.placeholderAttributedText = richPlaceholder
        input.layoutIfNeeded()
        if placeholder?.attributedText?.string != richPlaceholder.string { failures.append("rich placeholder missing") }

        if !input.becomeFirstResponder() { failures.append("cannot start editing") }
        input.insertText("A")
        if received != ["A"] { failures.append("insert callback: \(received)") }
        if placeholder?.isHidden != true { failures.append("placeholder remained visible after insertion") }
        input.text = ""
        if received != ["A"] { failures.append("programmatic assignment emitted a callback") }
        if placeholder?.isHidden != false { failures.append("placeholder did not reappear after clearing") }
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        if received != ["A"] { failures.append("composing text emitted a callback: \(received)") }
        input.unmarkText()
        if received != ["A", "ni"] { failures.append("composition commit callback: \(received)") }
        input.insertText("好")
        if received != ["A", "ni", "ni好"] { failures.append("multilingual input callback: \(received)") }

        verifyAsyncPreparation { asyncFailures in
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("result.txt")
            let allFailures = failures + asyncFailures
            let result = allFailures.isEmpty ? "PASS" : allFailures.joined(separator: "\n")
            do {
                try result.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("TextForge Swift example could not write its result: %@", String(describing: error))
            }
        }
    }

    /// 使用真实异步 API 验证取消、复用、绘制产物和 VoiceOver 操作与显示文本一致。
    private func verifyAsyncPreparation(completion: @escaping ([String]) -> Void) {
        var failures: [String] = []
        let size = CGSize(width: 220, height: 72)
        let insets = UIEdgeInsets(top: 4, left: 7, bottom: 5, right: 9)
        let font = UIFont.systemFont(ofSize: 16)
        let badge = UILabel(frame: CGRect(x: 0, y: 0, width: 26, height: 16))
        badge.text = "会员"
        let latest = NSMutableAttributedString(string: "查看协议", attributes: [.font: font, .foregroundColor: UIColor.label])
        let linkRange = NSRange(location: 0, length: latest.length)
        var accessedRange: NSRange?
        let highlight = TextForgeHighlight(color: .systemBlue, backgroundColor: nil)
        highlight.tapAction = { _, _, range, _ in accessedRange = range }
        highlight.apply(to: latest, range: linkRange)
        latest.append(TextForgeAttachment.view(badge, size: badge.bounds.size, font: font, alignment: .center))

        let label = TextForgeLabel(frame: .zero)
        label.text = "原来的内容"
        label.numberOfLines = 0
        label.contentInsets = insets
        label.textVerticalAlignment = .top
        label.lineBreakMode = .byWordWrapping
        let stale = label.setAttributedTextAsynchronously(
            NSAttributedString(string: String(repeating: "旧内容", count: 100)), size: size, rendersAsynchronously: true
        ) { failures.append("cancelled Cell request was delivered") }
        if !(label.text ?? "").isEmpty { failures.append("async request left previous content visible") }
        let cancelled = TextForgeLayout.prepare(
            attributedText: latest, size: size, insets: insets, maximumNumberOfRows: 0,
            lineBreakMode: .byWordWrapping, renderScale: 0,
            traitCollection: label.traitCollection
        ) { _ in failures.append("explicitly cancelled layout was delivered") }
        cancelled.cancel()

        let resizeLabel = TextForgeLabel(frame: CGRect(origin: .zero, size: size))
        let resizeTask = resizeLabel.setAttributedTextAsynchronously(latest, size: size, rendersAsynchronously: false)
        resizeLabel.bounds.size.width = 180
        if !resizeTask.isCancelled { failures.append("width change kept a pending request") }
        let manualUpdate = resizeLabel.setAttributedTextAsynchronously(latest, size: resizeLabel.bounds.size, rendersAsynchronously: false)
        resizeLabel.text = "同步更新"
        if !manualUpdate.isCancelled || resizeLabel.text != "同步更新" {
            failures.append("synchronous update did not replace a pending request")
        }
        let unmeasuredLabel = TextForgeLabel(frame: .zero)
        let wrongWidth = unmeasuredLabel.setAttributedTextAsynchronously(latest, size: size, rendersAsynchronously: false) {
            failures.append("a result prepared at the wrong initial width was delivered")
        }
        unmeasuredLabel.bounds = CGRect(x: 0, y: 0, width: 90, height: size.height)
        if !wrongWidth.isCancelled { failures.append("the first nonzero width did not cancel incompatible work") }

        var currentTask: TextForgeLayoutTask?
        currentTask = label.setAttributedTextAsynchronously(latest, size: size, rendersAsynchronously: true) {
            if !Thread.isMainThread { failures.append("prepared result delivered off the main thread") }
            if !stale.isCancelled || !cancelled.isCancelled || currentTask?.isCancelled != false {
                failures.append("cancellation state did not match the delivered request")
            }
            label.layoutIfNeeded()
            if label.text != latest.string || label.attributedText?.string != latest.string || label.accessibilityLabel != "查看协议" {
                failures.append("effective text or accessibility label was stale")
            }
            if badge.superview !== label { failures.append("prepared layout did not mount its original badge") }
            if let action = label.accessibilityCustomActions?.first {
                if action.name != "查看协议" || action.actionHandler?(action) != true || accessedRange != linkRange {
                    failures.append("VoiceOver action did not activate the visible highlight")
                }
                label.text = nil
                label.layoutIfNeeded()
                let activatedStaleAction = action.actionHandler?(action) == true
                if !(label.text ?? "").isEmpty || !(label.accessibilityLabel ?? "").isEmpty
                    || badge.superview != nil || activatedStaleAction {
                    failures.append("clearing completed async text kept stale content, an attachment or an accessibility action")
                }
                label.text = "下一条"
                if label.text != "下一条" || label.accessibilityLabel != "下一条" {
                    failures.append("plain text did not replace completed async content")
                }
            } else {
                failures.append("no accessibility action for the visible highlight")
            }

            _ = TextForgeLayout.prepare(
                attributedText: latest, size: size, insets: insets, maximumNumberOfRows: 0,
                lineBreakMode: .byWordWrapping, renderScale: 2,
                traitCollection: label.traitCollection
            ) { prepared in
                let sync = TextForgeLayout(
                    attributedText: latest, size: size, insets: insets,
                    maximumNumberOfRows: 0, lineBreakMode: .byWordWrapping
                )
                let image = Mirror(reflecting: prepared).children.first { $0.label == "preparedImage" }
                if prepared.textBoundingSize != sync.textBoundingSize
                    || image.flatMap({ Mirror(reflecting: $0.value).children.first }) == nil {
                    failures.append("background geometry or bitmap did not match expectations")
                }

                let annotation = NSObject()
                let key = NSAttributedString.Key("TextForge.ExampleAnnotation")
                let custom = NSAttributedString(string: "自定义属性", attributes: [key: annotation])
                _ = TextForgeLayout.prepare(
                    attributedText: custom, size: size, insets: insets, maximumNumberOfRows: 0,
                    lineBreakMode: .byWordWrapping, renderScale: 2, traitCollection: label.traitCollection
                ) { fallback in
                    if fallback.attributedText.attribute(key, at: 0, effectiveRange: nil) as? NSObject !== annotation
                        || !Thread.isMainThread {
                        failures.append("unsupported attribute fallback did not keep the original payload")
                    }
                    self.verifyAsyncRelayout { relayoutFailures in
                        completion(failures + relayoutFailures)
                    }
                }
            }
        }
        label.bounds = CGRect(origin: .zero, size: size)
    }

    /// 验证交付前后宽度变化的边界，以及保留原文后使用新样式排版的行为。
    private func verifyAsyncRelayout(completion: @escaping ([String]) -> Void) {
        var failures: [String] = []
        let wide = CGSize(width: 220, height: 100)
        let narrow = CGSize(width: 90, height: 100)
        let original = NSAttributedString(string: "这段文字在两百二十点内只占一行", attributes: [.font: UIFont.systemFont(ofSize: 13)])
        let label = TextForgeLabel(frame: .zero)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textVerticalAlignment = .top
        let stale = label.setAttributedTextAsynchronously(original, size: wide, rendersAsynchronously: true) {
            failures.append("frame change delivered a result for the old width")
        }
        label.frame.size = narrow
        label.setAttributedTextAsynchronously(original, size: narrow, rendersAsynchronously: true) {
            let narrowLayout = TextForgeLayout(
                attributedText: original, size: narrow, insets: .zero, maximumNumberOfRows: 0, lineBreakMode: .byWordWrapping
            )
            if !stale.isCancelled || label.sizeThatFits(narrow) != narrowLayout.textBoundingSize {
                failures.append("async preparation did not recover at the new width")
            }
            label.frame.size = wide
            let wideFit = label.sizeThatFits(wide)
            if label.text != original.string || wideFit.height >= narrowLayout.textBoundingSize.height {
                failures.append("resizing delivered text did not reflow the original content")
            }
            label.frame.size = narrow
            label.lineSpacing = 5
            if label.attributedText?.string != original.string || label.sizeThatFits(narrow).height <= narrowLayout.textBoundingSize.height {
                failures.append("changing line spacing discarded the async content or reused its old layout")
            }
            completion(failures)
        }
    }

    /// 对照 App 中的带间距评论、预排版弹幕和协议链接，验证真实测量、附件装卸、绘制和点击派发。
    private func verifyRichText() -> [String] {
        var failures: [String] = []
        let font = UIFont.systemFont(ofSize: 16)
        let styledLabel = TextForgeLabel()
        styledLabel.font = font
        styledLabel.numberOfLines = 0
        styledLabel.text = "创业圈评论"
        let constraint = CGSize(width: 200, height: 1_000)
        let baseWidth = styledLabel.sizeThatFits(constraint).width
        styledLabel.characterSpacing = 4
        if styledLabel.sizeThatFits(constraint).width <= baseWidth + 10 {
            failures.append("character spacing did not increase the measured width")
        }
        styledLabel.text = String(repeating: "这是会折行的评论", count: 3)
        let narrow = CGSize(width: 95, height: 1_000)
        let originalHeight = styledLabel.sizeThatFits(narrow).height
        styledLabel.lineSpacing = 8
        let spacedHeight = styledLabel.sizeThatFits(narrow).height
        if spacedHeight <= originalHeight + 8 {
            failures.append("line spacing did not increase the height of a wrapped paragraph: \(originalHeight) -> \(spacedHeight)")
        }
        styledLabel.text = "第一个评论\n第二个评论"
        let paragraphHeight = styledLabel.sizeThatFits(constraint).height
        styledLabel.paragraphSpacing = 6
        if styledLabel.sizeThatFits(constraint).height <= paragraphHeight + 5 {
            failures.append("paragraph spacing did not affect separated paragraphs")
        }

        let badge = UIView()
        badge.backgroundColor = .red
        let rich = NSMutableAttributedString(string: "用户甲：你好", attributes: [.font: font, .foregroundColor: UIColor.black])
        let highlightRange = NSRange(location: 0, length: 3)
        let highlight = TextForgeHighlight(color: .black, backgroundColor: .yellow)
        highlight.userInfo = ["id": "demo-user"]
        var tappedRange: NSRange?
        var tappedRect: CGRect?
        var clickedCharacter: NSRange?
        var pressOrder: [String] = []
        highlight.tapAction = { _, _, range, rect in
            tappedRange = range
            tappedRect = rect
        }
        highlight.apply(to: rich, range: highlightRange)
        rich.append(TextForgeAttachment.view(badge, size: CGSize(width: 30, height: 16), font: font, alignment: .center))

        let insets = UIEdgeInsets(top: 3, left: 5, bottom: 4, right: 6)
        let layout = TextForgeLayout(attributedText: rich, size: constraint, insets: insets, maximumNumberOfRows: 0, lineBreakMode: .byWordWrapping)
        let richLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        richLabel.textVerticalAlignment = .top
        richLabel.textTapAction = { _, _, range, _ in clickedCharacter = range }
        richLabel.textLongPressAction = { _, _, _, _ in pressOrder.append("text") }
        highlight.longPressAction = { _, _, _, _ in pressOrder.append("highlight") }
        richLabel.textLayout = layout
        richLabel.layoutIfNeeded()
        if richLabel.intrinsicContentSize != layout.textBoundingSize { failures.append("label ignored its precomputed size") }
        if badge.superview !== richLabel || badge.frame.size != CGSize(width: 30, height: 16) || badge.frame.minX <= insets.left {
            failures.append("visible badge was not placed after the text: \(badge.frame)")
        }
        let yAtTop = badge.frame.minY
        richLabel.textVerticalAlignment = .bottom
        richLabel.layoutIfNeeded()
        if abs(badge.frame.minY - yAtTop - (richLabel.bounds.height - layout.textBoundingSize.height)) > 1 {
            failures.append("vertical alignment did not move the attachment with the text")
        }
        richLabel.textVerticalAlignment = .top
        richLabel.layoutIfNeeded()
        let tap = ExampleTap()
        tap.point = CGPoint(x: insets.left + 5, y: insets.top + 8)
        _ = richLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        if tappedRange != highlightRange || tappedRect?.contains(tap.point) != true
            || TextForgeHighlight.highlight(in: rich, at: 0)?.userInfo?["id"] as? String != "demo-user"
            || clickedCharacter != NSRange(location: 0, length: 1) {
            failures.append("highlight did not return the original UTF-16 range and hit rect")
        }
        let press = ExamplePress()
        press.point = tap.point
        _ = richLabel.perform(NSSelectorFromString("handleLongPress:"), with: press)
        if pressOrder != ["text", "highlight"] { failures.append("long-press callbacks: \(pressOrder)") }
        tappedRange = nil
        tap.point = CGPoint(x: 190, y: 70)
        _ = richLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        if tappedRange != nil || clickedCharacter?.location != NSNotFound {
            failures.append("blank space triggered a character or highlight")
        }

        let tallText = NSMutableAttributedString(string: String(repeating: "中文内容", count: 15), attributes: [.font: font])
        tallText.append(TextForgeAttachment.view(badge, size: CGSize(width: 30, height: 16), font: font, alignment: .center))
        let oneLine = TextForgeLayout(attributedText: tallText, size: constraint, insets: insets, maximumNumberOfRows: 1, lineBreakMode: .byTruncatingTail)
        let allLines = TextForgeLayout(attributedText: tallText, size: constraint, insets: insets, maximumNumberOfRows: 0, lineBreakMode: .byWordWrapping)
        richLabel.textLayout = oneLine
        richLabel.text = "恢复原有文本"
        if richLabel.text != tallText.string { failures.append("ordinary text displaced a caller-supplied layout") }
        richLabel.layoutIfNeeded()
        if oneLine.textBoundingSize.height >= allLines.textBoundingSize.height || badge.superview != nil {
            failures.append("truncation retained old or hidden content")
        }

        let renderer = UIGraphicsImageRenderer(bounds: richLabel.bounds)
        let rendered = renderer.image { context in richLabel.layer.render(in: context.cgContext) }.pngData()
        let blank = renderer.image { _ in }.pngData()
        if rendered == nil || rendered == blank { failures.append("precomputed text rendered no pixels") }
        richLabel.textLayout = nil
        if richLabel.text != "恢复原有文本" { failures.append("clearing the explicit layout did not restore ordinary text") }

        let swatch = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let imageRun = TextForgeAttachment.image(swatch, size: CGSize(width: 24, height: 16), font: font, alignment: .center)
        let imageLayout = TextForgeLayout(attributedText: imageRun, size: constraint, insets: .zero, maximumNumberOfRows: 1, lineBreakMode: .byWordWrapping)
        if imageLayout.textBoundingSize.width < 24 { failures.append("inline image did not reserve its slot width") }
        richLabel.frame.size.height = 0
        richLabel.layoutIfNeeded()
        return failures
    }
}

private final class ExampleTap: UITapGestureRecognizer {
    var point = CGPoint.zero

    override func location(in view: UIView?) -> CGPoint { point }
}

private final class ExamplePress: UILongPressGestureRecognizer {
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { .began }
        set {}
    }

    override func location(in view: UIView?) -> CGPoint { point }
}
