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

        let article = TextForgeLabel()
        article.isSelectable = true
        article.numberOfLines = 2
        article.lineBreakMode = .byTruncatingTail
        article.truncationToken = TextForgeContainer.readMoreToken { [weak article] _, _, _, _ in article?.numberOfLines = 0 }
        article.highlightTapAction = { [weak self] _, text, range, _ in
            self?.status.text = (text.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString
        }
        let html = "<p><b>HTML 富文本</b></p><p>这段示例可以展开阅读全文，包含 <a href='https://example.com/help'>帮助链接</a>。</p>"
        TextForgeHTML.attributedString(from: html) { text, error in
            article.attributedText = text
            if let error { article.text = error.localizedDescription }
        }
        let stack = UIStackView(arrangedSubviews: [label, article, input, status])
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
        failures.append(contentsOf: verifyLayoutFeatures())
        failures.append(contentsOf: verifyTruncationEdges())
        failures.append(contentsOf: verifyWrappingAndInteraction())
        failures.append(contentsOf: verifyLabelSelection())
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

        input.text = ""
        received.removeAll()
        input.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ABC")
        if placeholder?.isHidden != true || !received.isEmpty { failures.append("storage edit placeholder or callback") }
        input.selectedRange = NSRange(location: 0, length: 3)
        input.deleteBackward()
        if received != [""] || placeholder?.isHidden != false { failures.append("missing user deletion after storage edit") }
        input.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText()
        if received != ["", "ni"] { failures.append("repeated marked edits: callbacks=\(received), text=\(input.text ?? "")") }

        failures.append(contentsOf: verifyCompositionTransactions())
        failures.append(contentsOf: verifyViewportRendering())

        verifyAsyncPreparation { asyncResults in
            self.verifyExplicitLayoutAppearance { appearanceFailures in
                self.verifyCopyMenu { copyFailures in
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let url = directory.appendingPathComponent("result.txt")
                    let allFailures = failures + asyncResults + appearanceFailures + copyFailures
                    let result = allFailures.isEmpty ? "PASS" : allFailures.joined(separator: "\n")
                    do {
                        try result.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        NSLog("TextForge Swift example could not write its result: %@", String(describing: error))
                    }
                }
            }
        }
    }

    /// 模拟替换已有选区的拼音、候选上屏、取消和重复通知。每次 UIKit 操作只允许交付返回时已提交的最终正文。
    private func verifyCompositionTransactions() -> [String] {
        var failures: [String] = []
        for i in 0..<18 {
            input.text = "前X后"
            input.selectedRange = NSRange(location: 1, length: 1)
            received.removeAll()
            var committed = "前X后"
            var expected: [String] = []
            // 某些系统输入模式会在 setMarkedText 返回前自行结束标记，按实际原生状态核对。
            func edit(_ operation: () -> Void) {
                operation()
                if input.markedTextRange == nil, let final = input.text, final != committed {
                    expected.append(final)
                    committed = final
                }
                if received != expected { failures.append("IME step \(i): expected \(expected), got \(received)") }
            }
            edit { input.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0)) }
            edit { input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0)) }
            switch i % 6 {
            case 0: edit { input.insertText("你") }
            case 1: edit { input.setMarkedText("", selectedRange: NSRange(location: 0, length: 0)) }
            case 2: edit { if let range = input.markedTextRange { input.replace(range, withText: "你") } }
            case 3: edit { input.deleteBackward() }
            case 4: edit { input.unmarkText() }
            default: break
            }
            edit { input.unmarkText() }
            edit { NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: input) }
            if !failures.isEmpty { break }
        }
        return failures
    }

    /// 从触点选词，并验证局部复制、附件替代、字素边界、隐藏正文和换文清理。
    private func verifyLabelSelection() -> [String] {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 18)
        view.addSubview(label)
        defer { label.removeFromSuperview() }
        let source = NSMutableAttributedString(string: "条款 contract 👨‍👩‍👧‍👦 ")
        let slot = TextForgeAttachment.view(UIView(), size: CGSize(width: 14, height: 12), font: label.font, alignment: .center)
        source.append(TextForgeAttachment.withTextAlternatives(slot, copyText: "[会员]", accessibilityText: "会员"))
        source.append(NSAttributedString(string: " 后文"))
        label.attributedText = source
        let ns = source.string as NSString
        let word = ns.range(of: "contract")
        let pointRect = label.rect(forRange: NSRange(location: word.location + 2, length: 1))
        let point = CGPoint(x: pointRect.midX, y: pointRect.midY)
        if label.selectWord(at: point) { return ["selection unexpectedly enabled by default"] }
        label.isSelectable = true
        let press = ExamplePress()
        let actual = label.rect(forRange: NSRange(location: word.location + 2, length: 1))
        press.point = CGPoint(x: actual.midX, y: actual.midY)
        _ = label.perform(NSSelectorFromString("handleLongPress:"), with: press)
        guard label.selectedRange == word, label.selectedText == "contract" else { return ["long press failed to select word"] }
        label.copy(nil)
        guard UIPasteboard.general.string == "contract" else { return ["copy did not use selected word"] }
        let emoji = ns.range(of: "👨‍👩‍👧‍👦")
        guard label.selectText(in: NSRange(location: emoji.location + 1, length: 1)), label.selectedRange == emoji else {
            return ["selection split grapheme cluster"]
        }
        let badge = ns.range(of: "\u{fffc}")
        guard label.selectText(in: badge), label.selectedText == "[会员]" else { return ["selection lost attachment alternative"] }
        guard !label.selectText(in: NSRange(location: Int.max - 1, length: 10)), label.selectedRange == badge else {
            return ["invalid selection replaced previous selection"]
        }
        label.text = String(repeating: "ABCDEFG ", count: 20)
        guard label.selectedRange.location == NSNotFound else { return ["selection survived content reuse"] }
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.bounds.size.width = 95
        let length = (label.text! as NSString).length
        guard label.isTruncated, !label.selectText(in: NSRange(location: 0, length: length)),
              !label.selectText(in: NSRange(location: length / 2, length: 1)),
              label.selectText(in: NSRange(location: 0, length: 1)),
              label.selectText(in: NSRange(location: length - 2, length: 1))
            else { return ["middle truncation selection did not isolate visible prefix and suffix"] }
        label.isSelectable = false
        label.allowsCopy = true
        label.copy(nil)
        return UIPasteboard.general.string == label.text ? [] : ["whole-label copy regressed"]
    }

    /// 对照真实命中对象、逐字换行和双向片段；缩字号后核对最后一个字符的几何与点击。
    private func verifyWrappingAndInteraction() -> [String] {
        var failures: [String] = []
        let font = UIFont.systemFont(ofSize: 20)
        let box = TextForgeContainer(size: CGSize(width: 95, height: 200))
        let word = NSMutableAttributedString(string: "1234 abcdefg 1234", attributes: [.font: font])
        let words = TextForgeLayout(container: box, attributedText: word)
        box.lineBreakMode = .byCharWrapping
        let chars = TextForgeLayout(container: box, attributedText: word)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        word.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: word.length))
        let explicit = TextForgeLayout(container: box, attributedText: word)
        if chars.lines.first?.range == words.lines.first?.range || explicit.lines.first?.range != words.lines.first?.range {
            failures.append("character wrap or explicit paragraph override")
        }

        let clipped = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        clipped.numberOfLines = 1
        clipped.lineBreakMode = .byClipping
        clipped.highlightTapAction = { _, _, _, _ in }
        let long = NSMutableAttributedString(string: String(repeating: "Sample ", count: 20), attributes: [.font: font])
        let tail = NSRange(location: long.length - 6, length: 5)
        long.addAttribute(.link, value: URL(string: "https://example.invalid/")!, range: tail)
        clipped.attributedText = long
        if !clipped.isTruncated || NSMaxRange(clipped.displayedTextLayout!.visibleRange) >= long.length ||
            !clipped.rect(forRange: tail).isNull || !(clipped.accessibilityCustomActions ?? []).isEmpty {
            failures.append("clipping exposed invisible link")
        }
        clipped.bounds.size.width = 4
        clipped.attributedText = NSAttributedString(string: "W", attributes: [.font: font])
        if !clipped.isTruncated || clipped.displayedTextLayout?.visibleRange.length != 1 {
            failures.append("partially visible glyph lost clipping or hit range")
        }
        clipped.bounds.size.width = 80
        clipped.text = "短"
        if clipped.isTruncated { failures.append("short clipping text misreported overflow") }

        clipped.attributedText = NSAttributedString(string: "שלום שלום שלום שלום", attributes: [.font: font])
        if !clipped.isTruncated || clipped.displayedTextLayout!.visibleRange.length >= clipped.attributedText!.length {
            failures.append("RTL clipping retained full range")
        }

        let bidi = TextForgeLayout(attributedText: NSAttributedString(string: "ABC אבג DEF", attributes: [.font: font]),
                                   size: CGSize(width: 260, height: 60))
        let rects = bidi.rects(forRange: NSRange(location: 0, length: 5))
        let gap = bidi.rect(forRange: NSRange(location: 5, length: 1))
        if rects.count != 2 || rects.contains(where: { $0.contains(CGPoint(x: gap.midX, y: gap.midY)) }) {
            failures.append("bidi highlights crossed an unselected glyph")
        }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).image { _ in }
        let attachment = TextForgeAttachment.image(image, size: image.size, font: font, alignment: .center)
        let copy = TextForgeAttachment.withTextAlternatives(attachment, copyText: "[星]", accessibilityText: "星星")
        let muted = TextForgeAttachment.withTextAlternatives(attachment, copyText: "★", accessibilityText: "")
        let icons = NSMutableAttributedString(string: "🌟")
        icons.append(copy)
        icons.append(muted)
        if TextForgeAttachment.copyText(for: icons) != "🌟[星]★" || TextForgeAttachment.accessibilityText(for: icons) != "🌟星星" {
            failures.append("Swift image attachment copy/speech alternatives")
        }

        let button = UIButton(frame: CGRect(x: 0, y: 0, width: 110, height: 40))
        let label = TextForgeLabel(frame: button.bounds)
        button.addSubview(label)
        label.font = .systemFont(ofSize: 24)
        label.text = "0123456789"
        let point = CGPoint(x: 5, y: 5)
        if button.hitTest(point, with: nil) !== button { failures.append("plain label intercepted button") }
        let custom = UITapGestureRecognizer()
        label.addGestureRecognizer(custom)
        if button.hitTest(point, with: nil) !== label { failures.append("host gesture lost its hit target") }
        label.removeGestureRecognizer(custom)
        var tapped = NSRange(location: NSNotFound, length: 0)
        label.textTapAction = { _, _, range, _ in tapped = range }
        label.minimumScaleFactor = 0.4
        label.adjustsFontSizeToFitWidth = true
        let last = NSRange(location: 9, length: 1)
        let rect = label.rect(forRange: last)
        let tap = ExampleTap()
        if !rect.isNull {
            tap.point = CGPoint(x: rect.midX, y: rect.midY)
            _ = label.perform(NSSelectorFromString("handleTap:"), with: tap)
        }
        if label.isTruncated || tapped != last { failures.append("last scaled glyph missing or untappable") }
        label.adjustsFontSizeToFitWidth = false
        if !label.isTruncated { failures.append("disabling shrink reused the scaled layout") }
        label.lineSpacing = 2
        label.textColor = .blue
        label.highlightedTextColor = .red
        label.isHighlighted = true
        if pixels(of: label).red == 0 { failures.append("custom layout ignored UILabel highlighted color") }
        label.isHighlighted = false
        if pixels(of: label).blue == 0 { failures.append("normal color not restored") }
        return failures
    }

    /// 同一份 HTML 验证内联样式、实体、相对链接和 data 图片，并检查异步预排版交付后的自适应高度。
    private func verifyHTMLAndIntrinsicSize(completion: @escaping ([String]) -> Void) {
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.base64EncodedString()
        let html = """
        <html><body><p><strong style="color:#f00">标题</strong> &amp; <a href="help">帮助</a></p>
        <ul><li>列表项目</li></ul><img width="4" height="4" alt="红花" src="data:image/png;base64,\(icon)"></body></html>
        """
        let base = URL(string: "https://example.com/guide/")!
        TextForgeHTML.attributedString(from: html, baseURL: base) { text, error in
            guard let text, error == nil else { completion(["HTML import: \(String(describing: error))"]); return }
            var failures: [String] = []
            let string = text.string as NSString
            let title = string.range(of: "标题")
            let help = string.range(of: "帮助")
            let font = title.location == NSNotFound ? nil : text.attribute(.font, at: title.location, effectiveRange: nil) as? UIFont
            let color = title.location == NSNotFound ? nil : text.attribute(.foregroundColor, at: title.location, effectiveRange: nil) as? UIColor
            let link = help.location == NSNotFound ? nil : text.attribute(.link, at: help.location, effectiveRange: nil) as? URL
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            var attachment: NSTextAttachment?
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let image = value as? NSTextAttachment { attachment = image }
            }
            if !Thread.isMainThread || !text.string.contains("&") || !text.string.contains("列表项目") || attachment == nil ||
                font?.fontDescriptor.symbolicTraits.contains(.traitBold) != true ||
                color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) != true || red < 0.9 || green > 0.1 ||
                link?.absoluteString != "https://example.com/guide/help" {
                failures.append("HTML style/image/link: \(text.string) \(String(describing: link)), image=\(attachment != nil)")
            }
            if !TextForgeAttachment.copyText(for: text).contains("红花") ||
                !TextForgeAttachment.accessibilityText(for: text).contains("红花") {
                failures.append("HTML image alt lost from copy or speech")
            }
            let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 130, height: 30))
            label.numberOfLines = 0
            label.preferredMaxLayoutWidth = 130
            let body = NSAttributedString(string: String(repeating: "排版测量。", count: 15), attributes: [.font: UIFont.systemFont(ofSize: 20)])
            label.setAttributedTextAsynchronously(body, size: label.bounds.size, rendersAsynchronously: true) {
                label.bounds.size.height = 400
                let fit = label.sizeThatFits(CGSize(width: 130, height: CGFloat.greatestFiniteMagnitude))
                if fit.height <= 30 || label.intrinsicContentSize.height != fit.height {
                    failures.append("intrinsic height after finite async layout")
                }
                guard let attachment else { completion(failures); return }
                self.verifyImportedImage(attachment) { imageFailures in
                    self.verifyHTMLReadingStyle { completion(failures + imageFailures + $0) }
                }
            }
        }
    }

    /// 验证旧编码声明下的 Unicode 正文、作者 CSS 优先级、图片去重、独立快照与尺寸回流。
    private func verifyHTMLReadingStyle(completion: @escaping ([String]) -> Void) {
        let style = TextForgeHTMLReadingStyle()
        style.defaultFont = .systemFont(ofSize: 19)
        style.textColor = .red
        style.linkColor = .green
        style.underlinesLinks = false
        style.maximumImageWidth = 60
        style.placeholderSize = CGSize(width: 16, height: 8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 30)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 30))
        }
        let embedded = image.pngData()!.base64EncodedString()
        let html = """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=GB18030"><base href="/cdn/"><style>.author { color: #0000ff; font-size: 11px }</style></head>
        <body>中文 café 😄 默认<a href="link">链接</a><b class="author">指定</b>
        <picture><source srcset="ignored.png"><img src='ok?a=1&amp;b=2' width=100 alt='首图'></picture>
        <img src='ok?a=1&amp;b=2' style='width:20px' alt='小图'><img src=missing alt='缺图'><img src='data:image/png;base64,\(embedded)' alt='内嵌图'><img style='display:none' src='hidden'></body></html>
        """
        var initial: NSAttributedString?
        var urls: [URL] = []
        var failures: [String] = []
        // 直接读取用户所见附件的排版尺寸，比较两个快照并确认旧快照没有被修改。
        func sizes(_ text: NSAttributedString) -> [CGSize] {
            var result: [CGSize] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { result.append(attachment.bounds.size) }
            }
            return result
        }
        var changed = IndexSet()
        var imageSizesChanged = false
        var lastBatch: NSAttributedString?
        _ = TextForgeHTML.importHTML(html, baseURL: URL(string: "https://example.invalid/docs/"),
            readingStyle: style, imageLoader: { url, reply in
                urls.append(url)
                let loaded = url.lastPathComponent == "ok" ? image : nil
                DispatchQueue.global().async { reply(loaded); reply(nil) }
                return nil
            }, imageUpdate: { batch in
                if batch.isInitial { initial = batch.attributedText }
                changed.formUnion(batch.changedIndexes)
                imageSizesChanged = imageSizesChanged || batch.didChangeSize
                if batch.isFinal { lastBatch = batch.attributedText }
            }) { result, error in
                guard let result, let initial, error == nil else { completion(["HTML host import: "+String(describing: error)]); return }
                if lastBatch !== result || changed.count != 2 || !imageSizesChanged {
                    failures.append("HTML image change indexes, geometry or final snapshot")
                }
                if !result.string.contains("中文 café 😄 默认") {
                    failures.append("HTML legacy charset corrupted Unicode text: " + result.string)
                }
                let expected = ["https://example.invalid/cdn/missing", "https://example.invalid/cdn/ok?a=1&b=2"]
                if urls.map(\.absoluteString).sorted() != expected ||
                    sizes(initial) != [CGSize(width: 60, height: 30), CGSize(width: 20, height: 10), style.placeholderSize, CGSize(width: 60, height: 15)] ||
                    sizes(result) != [CGSize(width: 60, height: 15), CGSize(width: 20, height: 5), style.placeholderSize, CGSize(width: 60, height: 15)] ||
                    !TextForgeAttachment.copyText(for: result).contains("首图") {
                    failures.append("HTML URLs or image sizes: \(urls), \(sizes(initial)), \(sizes(result))")
                }
                // 从实际导入的颜色通道、字号与链接属性断言，包括作者的 CSS 类。
                for (word, size, component) in [("默认", 19.0, 0), ("链接", 19.0, 1), ("指定", 11.0, 2)] {
                    let i = (result.string as NSString).range(of: word).location
                    guard i != NSNotFound else { failures.append("missing " + word); continue }
                    let attrs = result.attributes(at: i, effectiveRange: nil)
                    let font = attrs[.font] as? UIFont
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    let rgb = (attrs[.foregroundColor] as? UIColor)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                    if rgb != true || [r,g,b][component] < 0.95 || abs((font?.pointSize ?? 0) - size) > 0.1 ||
                        (component == 1 && (attrs[.link] == nil || (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0)) {
                        failures.append("HTML reading style \(word) \(attrs)")
                    }
                }
                let linkRange = (result.string as NSString).range(of: "链接")
                if linkRange.location != NSNotFound {
                    let link = result.attributedSubstring(from: linkRange)
                    let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 120, height: 45))
                    self.view.addSubview(label)
                    label.attributedText = link
                    if self.pixels(of: label).green == 0 { failures.append("HTML link color lost on label") }
                    label.linkTextAttributes = [.foregroundColor: UIColor.blue]
                    if self.pixels(of: label).blue == 0 { failures.append("explicit label link style lost") }
                    label.removeFromSuperview()
                    let input = TextForgeTextView(frame: label.bounds)
                    input.isEditable = false
                    input.backgroundColor = .clear
                    self.view.addSubview(input)
                    input.attributedText = link
                    input.layoutIfNeeded()
                    if self.pixels(of: input).green == 0 { failures.append("HTML link color lost on editor: \(self.pixels(of: input)) \(String(describing: input.linkTextAttributes))") }
                    input.linkTextAttributes = [.foregroundColor: UIColor.blue]
                    input.attributedText = link
                    input.layoutIfNeeded()
                    if self.pixels(of: input).blue == 0 { failures.append("explicit editor link style lost") }
                    input.linkTextAttributes = nil
                    input.text = "普通文本"
                    input.attributedText = NSAttributedString(string: "默认链接", attributes: [.link: URL(string: "https://example.invalid")!])
                    if input.linkTextAttributes?.isEmpty == true { failures.append("editor did not restore system link style") }
                    input.removeFromSuperview()
                }
                self.verifyHTMLCellReuse { reuseFailures in
                    self.verifyDecoratedBitmap { completion(failures + reuseFailures + $0) }
                }
            }
    }

    /// 在真正的 UITableView 重用队列中换绑同一 Cell，两篇文章共用 URL，并强制旧图在新图之后抵达。
    private func verifyHTMLCellReuse(completion: @escaping ([String]) -> Void) {
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: 230, height: 64), style: .plain)
        let source = HTMLReuseSource()
        table.register(HTMLReuseCell.self, forCellReuseIdentifier: "article")
        table.dataSource = source
        table.isPrefetchingEnabled = false
        table.rowHeight = 64
        view.addSubview(table)
        table.reloadData()
        table.layoutIfNeeded()
        let path = IndexPath(row: 0, section: 0)
        guard let cell = table.cellForRow(at: path) as? HTMLReuseCell else {
            table.removeFromSuperview(); completion(["missing original article cell"]); return
        }

        var failures: [String] = []
        let base = URL(string: "https://example.invalid/article/")!
        let oldHTML = "旧文章<img src='first' alt='旧首图'><img src='shared' alt='旧尾图'>"
        let newHTML = "新文章<img src='shared' alt='新封面'>"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 13, height: 7)).image { _ in }
        let style = TextForgeHTMLReadingStyle()
        weak var loaderOwner: NSObject?
        // 从独立作用域创建任务，确保返回后只有库持有加载器捕获的对象。
        func pendingImport() -> TextForgeHTMLImportTask {
            let owner = NSObject()
            loaderOwner = owner
            return TextForgeHTML.importHTML(oldHTML, baseURL: base, readingStyle: style, imageLoader: { [owner] _, _ in
                withExtendedLifetime(owner) { failures.append("loader started after immediate cancel") }
                return nil
            }, completion: { _, _ in failures.append("immediately cancelled import delivered") })
        }
        let pending = pendingImport()
        pending.cancel()
        pending.cancel()
        if loaderOwner != nil || !pending.isCancelled { failures.append("cancel retained loader before parsing") }

        var firstSnapshotCancelled = false
        var placeholderTask: TextForgeHTMLImportTask?
        placeholderTask = TextForgeHTML.importHTML(oldHTML, baseURL: base, readingStyle: style, imageLoader: { _, _ in
            failures.append("loader started after placeholder cancellation"); return nil
        }, update: { _ in
            firstSnapshotCancelled = true
            placeholderTask?.cancel()
        }, completion: { _, _ in failures.append("placeholder cancellation delivered final text") })
        var cancelledInsideLoader = 0
        var reentrant: TextForgeHTMLImportTask?
        reentrant = TextForgeHTML.importHTML(newHTML, baseURL: base, readingStyle: style, imageLoader: { _, reply in
            reentrant?.cancel()
            reply(image)
            return { cancelledInsideLoader += 1 }
        }, completion: { _, _ in failures.append("reentrant cancellation delivered final text") })

        var oldReplies: [String: @Sendable (UIImage?) -> Void] = [:]
        var cancelled: [String] = []
        var oldUpdates = 0, newUpdates = 0, newFinishes = 0
        var articleFinished = false
        var attempts = 0
        // 在三个独立导入都到达断言点后读取当前 Cell，不假设 WebKit 的完成顺序。
        func finishWhenReady() {
            if (articleFinished && firstSnapshotCancelled && cancelledInsideLoader == 1) || attempts >= 100 {
                if !firstSnapshotCancelled || cancelledInsideLoader != 1 || !articleFinished { failures.append("HTML cancellation boundary timeout") }
                if oldUpdates != 2 || newUpdates != 1 || newFinishes != 1 || cancelled != ["shared"] {
                    failures.append("article lifecycle counts: \(oldUpdates), \(newUpdates), \(newFinishes), \(cancelled)")
                }
                let current = cell.body.attributedText ?? NSAttributedString(string: "")
                let alt = TextForgeAttachment.copyText(for: current)
                let slot = (current.string as NSString).range(of: "\u{fffc}")
                let attachment = slot.location == NSNotFound ? nil : current.attribute(.attachment, at: slot.location, effectiveRange: nil) as? NSTextAttachment
                if !alt.contains("新文章新封面") || alt.contains("旧") || attachment?.bounds.size != image.size {
                    failures.append("stale article image/text after reuse: " + alt)
                }
                table.removeFromSuperview()
                completion(failures)
            } else {
                attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { finishWhenReady() }
            }
        }

        cell.task = TextForgeHTML.importHTML(oldHTML, baseURL: base, readingStyle: style, imageLoader: { url, reply in
            oldReplies[url.lastPathComponent] = reply
            if oldReplies.count == 2 { oldReplies["first"]?(image) }
            return { cancelled.append(url.lastPathComponent) }
        }, imageUpdate: { batch in
            oldUpdates += 1
            cell.body.attributedText = batch.attributedText
            if oldUpdates == 1 {
                if !batch.isInitial || batch.isFinal || !batch.changedIndexes.isEmpty { failures.append("old article placeholder batch") }
                return
            }
            let firstSlot = (batch.attributedText.string as NSString).range(of: "\u{fffc}").location
            if batch.isInitial || batch.isFinal || !batch.didChangeSize ||
                firstSlot == NSNotFound || batch.changedIndexes != IndexSet(integer: firstSlot) {
                failures.append("old article partial image batch before reuse")
            }
            guard oldUpdates == 2 else { return }
            source.count = 0
            table.reloadData()
            table.layoutIfNeeded()
            source.count = 1
            table.reloadData()
            table.layoutIfNeeded()
            guard let reused = table.cellForRow(at: path) as? HTMLReuseCell, reused === cell, cell.reuses > 0 else {
                failures.append("UITableView did not reuse original cell"); return
            }
            reused.task = TextForgeHTML.importHTML(newHTML, baseURL: base, readingStyle: style, imageLoader: { _, reply in
                reply(image); reply(nil)
                oldReplies["shared"]?(nil); oldReplies["shared"]?(image)
                return nil
            }, update: { snapshot in
                newUpdates += 1
                reused.body.attributedText = snapshot
            }, completion: { final, error in
                newFinishes += 1
                reused.body.attributedText = final
                if error != nil { failures.append("rebound article import failed") }
                DispatchQueue.main.async { articleFinished = true }
            })
        }, completion: { stale, _ in
            cell.body.attributedText = stale
            failures.append("old completion reached reused cell")
        })
        finishWhenReady()
    }

    /// 右对齐、外扩背景和阴影共用有限大容器。核对预绘的颜色位置、选中态与恢复后的常态。
    private func verifyDecoratedBitmap(completion: @escaping ([String]) -> Void) {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 340, height: 520))
        view.addSubview(label)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: -12, height: 6)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = UIColor.red
        let text = NSMutableAttributedString(string: "ABC", attributes: [
            .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.blue, .shadow: shadow, .paragraphStyle: style
        ])
        let decoration = TextForgeBackground(fillColor: .green, cornerRadius: 2)
        decoration.insets = UIEdgeInsets(top: -7, left: -23, bottom: -8, right: -3)
        decoration.apply(to: text, range: NSRange(location: 0, length: text.length))
        let box = TextForgeContainer(size: label.bounds.size, insets: UIEdgeInsets(top: 14, left: 7, bottom: 4, right: 12))
        label.textLayout = TextForgeLayout(container: box, attributedText: text)
        let expected = pixels(of: label)
        _ = TextForgeLayout.prepare(attributedText: text, container: box, renderScale: max(1, label.traitCollection.displayScale),
                                    traitCollection: label.traitCollection) { prepared in
            label.textLayout = prepared
            let normal = self.pixels(of: label)
            label.highlightedTextColor = .red
            label.isHighlighted = true
            let highlighted = self.pixels(of: label)
            label.isHighlighted = false
            let restored = self.pixels(of: label)
            label.removeFromSuperview()
            let bitmap = Mirror(reflecting: prepared).children.first { $0.label == "preparedImage" }?.value as? UIImage
            // 位图经设备像素再采样后边缘有抗锯齿差异，背景主体、原色和选中色都应保留。
            guard let bitmap, bitmap.size.width < 170, normal.green > 0, normal.blue > 0,
                  abs(normal.green - expected.green) <= 20, highlighted.red > normal.red,
                  highlighted.blue == 0, restored == normal else {
                completion(["decorated/selected bitmap: \(expected), \(normal), \(highlighted), \(restored), \(String(describing: bitmap?.size))"])
                return
            }
            completion([])
        }
    }

    /// 先后台预绘首次展示的 HTML 图片，再同步绘制对照，核对真实可见像素与占位尺寸。
    private func verifyImportedImage(_ attachment: NSTextAttachment, completion: @escaping ([String]) -> Void) {
        let source = NSAttributedString(attachment: attachment)
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.addSubview(label)
        let size = CGSize(width: 340, height: 600)
        label.bounds.size = size
        _ = TextForgeLayout.prepare(attributedText: source, size: size, insets: .zero, maximumNumberOfRows: 0,
                                    lineBreakMode: .byWordWrapping, renderScale: 3, traitCollection: label.traitCollection) { prepared in
            label.textLayout = prepared
            label.layoutIfNeeded()
            let usedPreparedLayout = label.displayedTextLayout === prepared
            let preparedRed = self.pixels(of: label).red
            let sync = TextForgeLayout(attributedText: source, size: size)
            label.textLayout = sync
            label.layoutIfNeeded()
            let syncRed = self.pixels(of: label).red
            label.removeFromSuperview()
            let bitmap = Mirror(reflecting: prepared).children.first { $0.label == "preparedImage" }?.value as? UIImage
            let matches = bitmap != nil && bitmap!.size.width < 100 && bitmap!.size.height < 100 && usedPreparedLayout && syncRed > 0 && syncRed == preparedRed && sync.textBoundingSize == prepared.textBoundingSize
            completion(matches ? [] : ["HTML image: async \(preparedRed) red pixels, \(prepared.textBoundingSize); sync \(syncRed), \(sync.textBoundingSize)"])
        }
    }

    /// 统计视图渲染结果中偏红、偏蓝、偏绿和全部不透明像素的数量，用于判断文字和底色是否真的画出来。
    private func pixels(of view: UIView) -> (red: Int, blue: Int, green: Int, any: Int) {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard width > 0, height > 0 else { return (0, 0, 0, 0) }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0, 0) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        view.layer.render(in: context)
        var red = 0, blue = 0, green = 0, any = 0
        for offset in stride(from: 0, to: data.count, by: 4) where data[offset + 3] > 120 {
            any += 1
            if data[offset] > 170, data[offset + 1] < 90, data[offset + 2] < 90 { red += 1 }
            if data[offset + 2] > 170, data[offset] < 90 { blue += 1 }
            if data[offset + 1] > 150, data[offset] < 90, data[offset + 2] < 90 { green += 1 }
        }
        return (red, blue, green, any)
    }

    /// 验证链接外观、无界宽度对齐、截断标记及其点击、逐行信息、排除路径、圆角背景、热区扩展和附件内容模式。
    private func verifyLayoutFeatures() -> [String] {
        var failures: [String] = []
        let font = UIFont.systemFont(ofSize: 16)
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // 链接默认使用系统链接色，清空 linkTextAttributes 后保留文本自己的颜色。
        let link = NSMutableAttributedString(
            string: "链接文字链接文字", attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.red]
        )
        link.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: link.length))
        let linkLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
        linkLabel.attributedText = link
        view.addSubview(linkLabel)
        linkLabel.layoutIfNeeded()
        let defaultLink = pixels(of: linkLabel)
        linkLabel.linkTextAttributes = [:]
        linkLabel.layoutIfNeeded()
        let ownColorLink = pixels(of: linkLabel)
        if defaultLink.red != 0 || defaultLink.any < 500 || ownColorLink.red < 500 {
            failures.append("link appearance: default \(defaultLink), own color \(ownColorLink)")
        }
        var linkRange: NSRange?
        linkLabel.highlightTapAction = { _, text, range, _ in
            if text.attribute(.link, at: range.location, effectiveRange: nil) != nil { linkRange = range }
        }
        let tap = ExampleTap()
        tap.point = CGPoint(x: 20, y: 25)
        _ = linkLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        if linkRange != NSRange(location: 0, length: link.length) { failures.append("link tap range: \(String(describing: linkRange))") }
        linkLabel.removeFromSuperview()

        // 无界宽度的预排版在居中和右对齐时也要画在标签范围内，且尺寸与左对齐一致。
        var widths: [CGFloat] = []
        for alignment in [NSTextAlignment.left, .center, .right] {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            let text = NSAttributedString(string: "弹幕提示文字", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.red, .paragraphStyle: style
            ])
            let container = TextForgeContainer(size: unbounded, insets: UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))
            container.maximumNumberOfRows = 1
            container.lineBreakMode = .byTruncatingTail
            let layout = TextForgeLayout(container: container, attributedText: text)
            let label = TextForgeLabel(frame: CGRect(origin: .zero, size: layout.textBoundingSize))
            label.textLayout = layout
            view.addSubview(label)
            label.layoutIfNeeded()
            widths.append(layout.textBoundingSize.width)
            let drawn = pixels(of: label)
            let hit = layout.characterIndex(at: CGPoint(x: 10 + 4, y: 5 + 10))
            if drawn.red < 300 || hit != 0 || layout.rowCount != 1 || layout.isTruncated {
                failures.append("unbounded alignment \(alignment.rawValue): \(drawn), hit \(hit), rows \(layout.rowCount)")
            }
            label.removeFromSuperview()
        }
        if Set(widths).count != 1 { failures.append("unbounded widths differ by alignment: \(widths)") }
        // 左对齐时首行缩进不能被当成需要平移的偏移。
        let indented = NSMutableParagraphStyle()
        indented.firstLineHeadIndent = 20
        let indentLayout = TextForgeLayout(
            attributedText: NSAttributedString(string: "缩进", attributes: [.font: font, .paragraphStyle: indented]), size: unbounded
        )
        if indentLayout.textBoundingRect.minX < 19 { failures.append("first-line indent lost: \(indentLayout.textBoundingRect)") }

        // 逐行信息和行数：范围首尾相接并覆盖全文，基线落在各自行内。
        let paragraph = String(repeating: "这是一段需要折行的富文本内容", count: 4)
        let body = NSAttributedString(string: paragraph, attributes: [.font: font, .foregroundColor: UIColor.black])
        let full = TextForgeLayout(attributedText: body, size: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        let lines = full.lines
        var expectedLocation = 0
        for line in lines {
            if line.range.location != expectedLocation || line.baseline <= line.rect.minY || line.baseline >= line.rect.maxY {
                failures.append("line geometry: \(line.range) \(line.rect) baseline \(line.baseline)")
            }
            expectedLocation = NSMaxRange(line.range)
        }
        if full.rowCount < 3 || lines.count != full.rowCount || expectedLocation != body.length
            || full.isTruncated || full.visibleRange != NSRange(location: 0, length: body.length) {
            failures.append("line info: rows \(full.rowCount), lines \(lines.count), end \(expectedLocation), visible \(full.visibleRange)")
        }
        let secondLine = lines.count > 1 ? lines[1] : nil
        if let secondLine {
            let rects = full.rects(forRange: NSRange(location: secondLine.range.location - 1, length: 2))
            let probe = full.characterIndex(at: CGPoint(x: secondLine.rect.minX + 3, y: secondLine.rect.midY))
            if rects.count != 2 || probe != secondLine.range.location
                || full.rectValues(forRange: secondLine.range).count != 1 {
                failures.append("range rects across lines: \(rects), probe \(probe)")
            }
        }
        if !full.rect(forRange: NSRange(location: body.length + 5, length: 3)).isNull
            || full.characterIndex(at: CGPoint(x: 199, y: 5_000)) != NSNotFound {
            failures.append("out-of-range queries did not report empty results")
        }

        // 自定义截断标记：限两行，标记在末行可见且可点击，原文在标记前截断，行数和高度不变。
        let token = NSMutableAttributedString(string: "…全文")
        var tokenTapped: (String, NSRange)?
        let tokenHighlight = TextForgeHighlight(color: .systemGreen, backgroundColor: .yellow)
        tokenHighlight.cornerRadius = 3
        tokenHighlight.tapAction = { _, text, range, _ in tokenTapped = (text.string, range) }
        tokenHighlight.apply(to: token, range: NSRange(location: 1, length: 2))
        let limited = TextForgeContainer(size: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        limited.maximumNumberOfRows = 2
        limited.lineBreakMode = .byTruncatingTail
        let plainTruncated = TextForgeLayout(container: limited, attributedText: body)
        limited.truncationToken = token
        let tokenLayout = TextForgeLayout(container: limited, attributedText: body)
        let tokenLines = tokenLayout.lines
        if !plainTruncated.isTruncated || !tokenLayout.isTruncated || tokenLayout.rowCount != 2
            || tokenLayout.textBoundingSize.height != plainTruncated.textBoundingSize.height
            || tokenLayout.textBoundingSize.width > 200
            || tokenLayout.visibleRange.location != 0 || NSMaxRange(tokenLayout.visibleRange) >= body.length
            || tokenLines.last.map({ NSMaxRange($0.range) }) != NSMaxRange(tokenLayout.visibleRange)
            || tokenLayout.attributedText.string != paragraph {
            failures.append("truncation token layout: rows \(tokenLayout.rowCount), size \(tokenLayout.textBoundingSize), visible \(tokenLayout.visibleRange)")
        }
        // 容器在创建布局后再改不影响已有布局。
        limited.maximumNumberOfRows = 0
        if tokenLayout.maximumNumberOfRows != 2 || tokenLayout.truncationToken?.string != "…全文" {
            failures.append("layout shared its container with the caller")
        }
        let tokenLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        tokenLabel.font = font
        tokenLabel.textColor = .black
        tokenLabel.numberOfLines = 2
        tokenLabel.textVerticalAlignment = .top
        tokenLabel.text = paragraph
        tokenLabel.truncationToken = token
        view.addSubview(tokenLabel)
        tokenLabel.layoutIfNeeded()
        let tokenPixels = pixels(of: tokenLabel)
        var tokenPoint: CGPoint?
        if let last = tokenLabel.displayedTextLayout?.lines.last {
            // 标记紧跟在末行原文之后，取"全文"两个字的中间位置。
            let endOfText = tokenLabel.rect(forRange: NSRange(location: NSMaxRange(last.range) - 1, length: 1))
            tokenPoint = CGPoint(x: endOfText.maxX + 30, y: endOfText.midY)
        }
        if let tokenPoint {
            if tokenLabel.characterIndex(at: tokenPoint) != NSNotFound { failures.append("token point resolved to source text") }
            tap.point = tokenPoint
            _ = tokenLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        }
        if !tokenLabel.isTruncated || tokenPixels.green < 20 || tokenTapped?.0 != "…全文"
            || tokenTapped?.1 != NSRange(location: 1, length: 2) {
            failures.append("truncation token on label: \(tokenPixels), tapped \(String(describing: tokenTapped)), point \(String(describing: tokenPoint))")
        }
        let tokenActions = tokenLabel.accessibilityCustomActions ?? []
        if !tokenActions.contains(where: { $0.name == "全文" }) { failures.append("token highlight has no accessibility action") }
        tokenLabel.numberOfLines = 0
        tokenLabel.frame.size.height = 200
        tokenLabel.layoutIfNeeded()
        if tokenLabel.isTruncated || pixels(of: tokenLabel).green != 0 {
            failures.append("token stayed visible after the text was expanded")
        }
        tokenLabel.removeFromSuperview()
        // 标记比整行还宽时仍能完成排版，不会死循环或越界。
        let narrowBox = TextForgeContainer(size: CGSize(width: 30, height: CGFloat.greatestFiniteMagnitude))
        narrowBox.maximumNumberOfRows = 1
        narrowBox.lineBreakMode = .byTruncatingTail
        narrowBox.truncationToken = NSAttributedString(string: "……展开查看全部内容")
        let cramped = TextForgeLayout(container: narrowBox, attributedText: body)
        if !cramped.isTruncated || cramped.rowCount != 1 { failures.append("oversized token: rows \(cramped.rowCount)") }
        // 表情不会被截断标记拆成半个。
        let emoji = NSAttributedString(string: String(repeating: "👨‍👩‍👧‍👦", count: 12), attributes: [.font: font])
        let emojiBox = TextForgeContainer(size: CGSize(width: 150, height: CGFloat.greatestFiniteMagnitude))
        emojiBox.maximumNumberOfRows = 1
        emojiBox.lineBreakMode = .byTruncatingTail
        emojiBox.truncationToken = NSAttributedString(string: "…更多")
        let emojiVisible = TextForgeLayout(container: emojiBox, attributedText: emoji).visibleRange
        let family = ("👨‍👩‍👧‍👦" as NSString).length
        if emojiVisible.location != 0 || emojiVisible.length == 0 || emojiVisible.length % family != 0 {
            failures.append("token split a grapheme cluster: \(emojiVisible)")
        }

        // 排除路径：左上角挖掉一块后，首行从路径右侧开始，高度增加。
        let exclusion = TextForgeContainer(size: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        exclusion.exclusionPaths = [UIBezierPath(rect: CGRect(x: 0, y: 0, width: 80, height: 30))]
        let wrapped = TextForgeLayout(container: exclusion, attributedText: body)
        if wrapped.lines.first.map({ $0.rect.minX < 79 }) != false || wrapped.textBoundingSize.height <= full.textBoundingSize.height {
            failures.append("exclusion path ignored: first line \(String(describing: wrapped.lines.first?.rect)), height \(wrapped.textBoundingSize.height)")
        }
        let exclusionLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        exclusionLabel.numberOfLines = 0
        exclusionLabel.attributedText = body
        let unobstructed = exclusionLabel.sizeThatFits(CGSize(width: 200, height: 1_000)).height
        exclusionLabel.exclusionPaths = exclusion.exclusionPaths
        if exclusionLabel.sizeThatFits(CGSize(width: 200, height: 1_000)).height <= unobstructed {
            failures.append("label ignored exclusion paths")
        }

        // 圆角背景画在文字下方，跨行时每行各一段。
        let tagged = NSMutableAttributedString(attributedString: body)
        let background = TextForgeBackground(fillColor: .red, cornerRadius: 4)
        background.insets = UIEdgeInsets(top: -1, left: -2, bottom: -1, right: -2)
        background.apply(to: tagged, range: NSRange(location: 0, length: 4))
        let taggedLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        taggedLabel.numberOfLines = 0
        taggedLabel.attributedText = tagged
        view.addSubview(taggedLabel)
        taggedLabel.layoutIfNeeded()
        let taggedPixels = pixels(of: taggedLabel)
        if taggedPixels.red < 600 || taggedPixels.red > 2_500 { failures.append("text background: \(taggedPixels)") }
        taggedLabel.removeFromSuperview()

        // 热区扩展：紧贴高亮下方的空白在半径内算命中，半径之外不算。
        let agreement = NSMutableAttributedString(string: "同意《协议》", attributes: [.font: font])
        var extendedTaps = 0
        let agreementHighlight = TextForgeHighlight(color: .systemBlue, backgroundColor: nil)
        agreementHighlight.tapAction = { _, _, _, _ in extendedTaps += 1 }
        agreementHighlight.apply(to: agreement, range: NSRange(location: 2, length: 4))
        let agreementLabel = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        agreementLabel.textVerticalAlignment = .top
        agreementLabel.attributedText = agreement
        let target = agreementLabel.rect(forRange: NSRange(location: 2, length: 4))
        tap.point = CGPoint(x: target.midX, y: target.maxY + 8)
        _ = agreementLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        if extendedTaps != 0 { failures.append("blank space hit a highlight without an extension radius") }
        agreementLabel.highlightTouchExtensionRadius = 10
        _ = agreementLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        tap.point = CGPoint(x: target.midX, y: target.maxY + 30)
        _ = agreementLabel.perform(NSSelectorFromString("handleTap:"), with: tap)
        if extendedTaps != 1 || target.isNull { failures.append("touch extension radius: taps \(extendedTaps), target \(target)") }
        if agreementLabel.hitTest(CGPoint(x: target.midX, y: target.midY), with: nil) !== agreementLabel ||
            agreementLabel.hitTest(CGPoint(x: 190, y: 75), with: nil) != nil {
            failures.append("interactive and passive parts of the label must hit different targets")
        }

        // 附件内容模式：等比缩放后填满槽高，居中模式保持原尺寸。
        let swatch = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var filled: [Int] = []
        for mode in [UIView.ContentMode.center, .scaleAspectFit, .scaleToFill] {
            let run = TextForgeAttachment.image(swatch, contentMode: mode, size: CGSize(width: 32, height: 16), font: font, alignment: .center)
            let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 40, height: 24))
            label.textVerticalAlignment = .top
            label.attributedText = run
            view.addSubview(label)
            label.layoutIfNeeded()
            filled.append(pixels(of: label).red)
            label.removeFromSuperview()
        }
        if !(filled[0] < filled[1] && filled[1] < filled[2]) { failures.append("attachment content modes: \(filled)") }
        return failures
    }

    /// 验证截断后的几何、标记交互和附件，以及测量后重排仍保留段落缩进。
    private func verifyTruncationEdges() -> [String] {
        var failures: [String] = []
        let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let text = NSAttributedString(string: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", attributes: [.font: font])
        let hidden = NSRange(location: 14, length: 1)
        for mode in [NSLineBreakMode.byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail] {
            let container = TextForgeContainer(size: CGSize(width: 90, height: 40))
            container.maximumNumberOfRows = 1
            container.lineBreakMode = mode
            let layout = TextForgeLayout(container: container, attributedText: text)
            if !layout.isTruncated || !layout.rect(forRange: hidden).isNull || !layout.rects(forRange: hidden).isEmpty {
                failures.append("native truncation returned geometry for hidden glyphs: \(mode.rawValue)")
            }
            if !layout.rect(forRange: NSRange(location: -1, length: 1)).isNull
                || layout.rect(forRange: NSRange(location: 0, length: Int.max)).isNull {
                failures.append("geometry did not handle negative locations or oversized lengths")
            }
        }

        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 45, height: 40))
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.attributedText = text
        let longToken = NSMutableAttributedString(string: "PREFIXPREFIXHIDDEN", attributes: [.font: font])
        let action = TextForgeHighlight(backgroundColor: nil)
        action.tapAction = { _, _, _, _ in }
        action.apply(to: longToken, range: NSRange(location: 12, length: 6))
        label.truncationToken = longToken
        if label.accessibilityCustomActions?.isEmpty == false {
            failures.append("oversized token exposed a hidden accessibility action")
        }

        let badge = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 12))
        label.truncationToken = TextForgeAttachment.view(badge, size: badge.bounds.size, font: font, alignment: .center)
        label.layoutIfNeeded()
        if badge.superview !== label || badge.frame.maxX > label.bounds.maxX {
            failures.append("visible truncation attachment was not mounted at the token's position")
        }
        label.truncationToken = nil
        if badge.superview != nil { failures.append("replacing the token left its attachment mounted") }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 24
        let indented = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
        indented.numberOfLines = 1
        indented.lineBreakMode = .byTruncatingTail
        indented.textVerticalAlignment = .top
        indented.attributedText = NSAttributedString(string: "ABCDEF", attributes: [.font: font, .paragraphStyle: style])
        let fitted = indented.sizeThatFits(indented.bounds.size)
        indented.bounds.size.width = fitted.width
        if indented.isTruncated { failures.append("fitting dropped the first-line indent and clipped the text: \(fitted)") }
        return failures
    }

    /// 同一份含动态色的预排在浅、深、浅三种绑定中共享几何，并用实际像素核对轮换后的颜色。
    private func verifyExplicitLayoutAppearance(completion: @escaping ([String]) -> Void) {
        let size = CGSize(width: 200, height: 40)
        let label = TextForgeLabel(frame: CGRect(origin: .zero, size: size))
        label.overrideUserInterfaceStyle = .dark
        view.addSubview(label)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let color = UIColor { $0.userInterfaceStyle == .dark ? .blue : .red }
        let text = NSAttributedString(string: "右对齐", attributes: [
            .font: UIFont.systemFont(ofSize: 18), .foregroundColor: color, .paragraphStyle: style
        ])
        let box = TextForgeContainer(size: size)
        let item = TextForgeListItem(attributedText: text, container: box)
        let cache = TextForgeListLayoutCache()
        let traits = label.traitCollection
        var failures: [String] = []
        let stale = cache.prepare(item, size: size, renderScale: 3, traitCollection: traits) { _ in
            failures.append("cancelled cache subscriber received a layout")
        }
        stale.cancel()
        var delivered: [TextForgeLayout] = []
        // 两个仍然有效的订阅应得到同一个对象，Dictionary 的回调次序无关。
        func received(_ layout: TextForgeLayout) {
            delivered.append(layout)
            guard delivered.count == 2 else { return }
            if delivered[0] !== layout { failures.append("prefetch and cell performed different layouts") }
            label.textLayout = layout
            for appearance in [UIUserInterfaceStyle.light, .dark, .light] {
                label.overrideUserInterfaceStyle = appearance
                label.setNeedsDisplay()
                let pixels = self.pixels(of: label)
                if label.displayedTextLayout !== layout || label.sizeThatFits(size) != layout.textBoundingSize ||
                    (appearance == .light ? pixels.red == 0 || pixels.blue > 0 : pixels.blue == 0 || pixels.red > 0) {
                    failures.append("shared layout appearance \(appearance.rawValue): \(pixels)")
                }
            }
            let narrow = CGSize(width: 80, height: 40)
            if cache.cachedSize(for: item, size: size, traitCollection: traits)?.cgSizeValue != layout.textBoundingSize ||
                cache.cachedSize(for: item, size: narrow, traitCollection: traits) != nil {
                failures.append("list size cache mixed constraints")
            }
            let oldBinding = cache.prepare(item, size: size, renderScale: 3, traitCollection: label.traitCollection) { _ in
                failures.append("cancelled cache hit reached a rebound Cell")
            }
            oldBinding.cancel()
            cache.prepare(item, size: size, renderScale: 3, traitCollection: label.traitCollection) { hit in
                if hit !== layout { failures.append("list cache missed resident layout") }
                cache.removeAllCachedResults()
                if cache.cachedSize(for: item, size: size, traitCollection: traits) != nil { failures.append("stale cached size") }
                let tiny = TextForgeListLayoutCache(bitmapByteLimit: 1, layoutCountLimit: 2)
                tiny.prepare(item, size: size, renderScale: 3, traitCollection: traits) { first in
                    if tiny.cachedSize(for: item, size: size, traitCollection: traits) == nil {
                        failures.append("oversized bitmap lost its independent measurement")
                    }
                    tiny.prepare(item, size: size, renderScale: 3, traitCollection: traits) { second in
                        if first === second { failures.append("oversized bitmap was retained") }
                        label.removeFromSuperview()
                        self.verifyInvalidCacheSize { invalidSizeFailures in
                            self.verifyAdaptiveAttachment { completion(failures + invalidSizeFailures + $0) }
                        }
                    }
                }
            }
        }
        cache.prepare(item, size: size, renderScale: 3, traitCollection: traits, completion: received)
        cache.prepare(item, size: size, renderScale: 3, traitCollection: traits, completion: received)
    }

    /// 非法宽高应与同轴为零的请求共享空布局；分别验证回调到达、尺寸查询和复用身份。
    private func verifyInvalidCacheSize(completion: @escaping ([String]) -> Void) {
        let item = TextForgeListItem(attributedText: NSAttributedString(string: "等待测量"),
                                     container: TextForgeContainer(size: .zero))
        let cache = TextForgeListLayoutCache()
        let traits = view.traitCollection
        let cases = [(CGSize(width: CGFloat.nan, height: 40), CGSize(width: 0, height: 40)),
                     (CGSize(width: 80, height: CGFloat.nan), CGSize(width: 80, height: 0))]
        var completed = 0
        var failures: [String] = []
        var finished = false
        for (invalid, zero) in cases {
            cache.prepare(item, size: invalid, renderScale: 0, traitCollection: traits) { layout in
                if cache.cachedSize(for: item, size: invalid, traitCollection: traits)?.cgSizeValue != CGSize.zero {
                    failures.append("invalid dimension lost its empty measurement")
                }
                cache.prepare(item, size: zero, renderScale: 0, traitCollection: traits) { hit in
                    if hit !== layout || hit.size != zero { failures.append("invalid dimension used a different layout key") }
                    completed += 1
                    if completed == cases.count, !finished { finished = true; completion(failures) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !finished { finished = true; completion(failures + ["invalid dimension lost cache callback: \(completed)/2"]) }
        }
    }

    /// 自定义附件按外观返回不同高度，缓存与显式标签均须在目标外观下重新查询附件尺寸。
    private func verifyAdaptiveAttachment(completion: @escaping ([String]) -> Void) {
        let size = CGSize(width: 120, height: 120)
        let item = TextForgeListItem(attributedText: NSAttributedString(attachment: AdaptiveAttachment()),
                                     container: TextForgeContainer(size: size))
        let cache = TextForgeListLayoutCache()
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        cache.prepare(item, size: size, renderScale: 0, traitCollection: dark) { darkLayout in
            cache.prepare(item, size: size, renderScale: 0, traitCollection: light) { lightLayout in
                let label = TextForgeLabel(frame: CGRect(origin: .zero, size: size))
                label.overrideUserInterfaceStyle = .light
                self.view.addSubview(label)
                label.textLayout = darkLayout
                let displayed = label.displayedTextLayout
                let measured = label.intrinsicContentSize
                label.removeFromSuperview()
                completion(darkLayout !== lightLayout && darkLayout.textBoundingSize.height > lightLayout.textBoundingSize.height &&
                           displayed?.textBoundingSize == lightLayout.textBoundingSize && measured == lightLayout.textBoundingSize ? [] : ["trait-dependent attachment metrics"])
            }
        }
    }

    /// 在滚动容器中核对附件移出、重新挂载，并逐像素比较带阴影和外扩背景的长文局部绘制。
    private func verifyViewportRendering() -> [String] {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        view.addSubview(scroll)
        defer { scroll.removeFromSuperview() }
        let text = NSMutableAttributedString()
        let font = UIFont.italicSystemFont(ofSize: 16)
        let views = (0..<12).map { _ in UIView() }
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: 12)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = UIColor.blue
        let background = TextForgeBackground(fillColor: .yellow, cornerRadius: 3)
        background.insets = UIEdgeInsets(top: -4, left: -2, bottom: -6, right: -2)
        for badge in views {
            text.append(TextForgeAttachment.view(badge, size: CGSize(width: 16, height: 20), font: font, alignment: .center))
            text.append(NSAttributedString(string: "段落 abc שלום\n", attributes: [
                .font: font, .shadow: shadow, TextForgeBackground.attributeName: background
            ]))
        }
        let layout = TextForgeLayout(attributedText: text, size: CGSize(width: 160, height: 1000))
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 160, height: layout.textBoundingSize.height))
        label.textLayout = layout
        scroll.addSubview(label)
        scroll.contentSize = label.frame.size
        label.layoutIfNeeded()
        let initial = views.filter { $0.superview === label }
        scroll.contentOffset.y = label.bounds.height - scroll.bounds.height
        label.layoutIfNeeded()
        if initial.isEmpty || views.last?.superview !== label || initial.first?.superview === label {
            return ["viewport attachment mounting after scroll"]
        }
        scroll.contentOffset = .zero
        label.layoutIfNeeded()
        if initial.first?.superview !== label || views.last?.superview === label { return ["attachment remount after scrolling back"] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: label.bounds.size, format: format)
        let slice = CGRect(x: 22, y: 112, width: 74, height: 21)
        let full = renderer.image { _ in label.drawText(in: label.bounds) }
        let partial = renderer.image { ctx in ctx.cgContext.clip(to: slice); label.drawText(in: slice) }
        // 相同颜色空间重新取样，排除底层 CGImage 行对齐差异。
        let patch = UIGraphicsImageRenderer(size: slice.size, format: format)
        let a = patch.pngData { _ in full.draw(at: CGPoint(x: -slice.minX, y: -slice.minY)) }
        let b = patch.pngData { _ in partial.draw(at: CGPoint(x: -slice.minX, y: -slice.minY)) }
        return a == b ? [] : ["clipped text pixels differ from full draw"]
    }

    /// 验证长按拷贝及剪贴板文本，同时覆盖未开启、系统拒绝第一响应者和成功呈现三种路径。
    private func verifyCopyMenu(completion: @escaping ([String]) -> Void) {
        var failures: [String] = []
        let font = UIFont.systemFont(ofSize: 16)
        let content = NSMutableAttributedString(string: "可拷贝的评论", attributes: [.font: font])
        content.append(TextForgeAttachment.view(UIView(), size: CGSize(width: 10, height: 10), font: font, alignment: .center))
        let label = TextForgeLabel(frame: CGRect(x: 20, y: 300, width: 200, height: 30))
        label.attributedText = content
        view.addSubview(label)
        label.layoutIfNeeded()
        if label.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) {
            failures.append("copy offered while disabled")
        }
        var visibility: [Bool] = []
        label.allowsCopy = true
        label.copyMenuVisibilityHandler = { visibility.append($0) }
        if !label.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) {
            failures.append("copy not offered while enabled")
        }
        UIPasteboard.general.string = "旧内容"
        label.copy(nil)
        if UIPasteboard.general.string != "可拷贝的评论" {
            failures.append("copied text: \(String(describing: UIPasteboard.general.string))")
        }
        let press = ExamplePress()
        press.point = CGPoint(x: 30, y: 15)
        if #available(iOS 16.0, *) {
            let rejected = RejectingCopyLabel(frame: label.frame)
            rejected.text = label.text
            rejected.allowsCopy = true
            view.addSubview(rejected)
            _ = rejected.perform(NSSelectorFromString("handleLongPress:"), with: press)
            if rejected.interactions.contains(where: { $0 is UIEditMenuInteraction }) {
                failures.append("copy attempted to present without first-responder ownership")
            }
            rejected.removeFromSuperview()
        }
        if !label.gestureRecognizerShouldBegin(label.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer } ?? press) {
            failures.append("long press refused although copying is enabled")
        }
        _ = label.perform(NSSelectorFromString("handleLongPress:"), with: press)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if visibility.first != true { failures.append("copy menu was not presented: \(visibility)") }
            label.removeFromSuperview()
            completion(failures)
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
            self.verifyHTMLAndIntrinsicSize { completion(failures + $0) }
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

/// 文章行示例通过 prepareForReuse 撤销旧文章并清空显示。
private final class HTMLReuseCell: UITableViewCell {
    let body = TextForgeLabel()
    var task: TextForgeHTMLImportTask?
    private(set) var reuses = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(body)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        body.frame = contentView.bounds
    }

    /// 先取消，再清空，确保旧回调无法覆盖下一篇文章。
    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        body.attributedText = nil
        reuses += 1
    }
}

private final class HTMLReuseSource: NSObject, UITableViewDataSource {
    var count = 1
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "article", for: indexPath)
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

/// 模拟系统拒绝切换第一响应者时的标签。
private final class RejectingCopyLabel: TextForgeLabel {
    override func becomeFirstResponder() -> Bool { false }
}

private final class AdaptiveAttachment: NSTextAttachment {
    /// 模拟宿主按主题切换图形规格，验证库使用当前请求环境测量自定义附件。
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: 20, height: UITraitCollection.current.userInterfaceStyle == .dark ? 58 : 18)
    }
}
