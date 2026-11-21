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
        failures.append(contentsOf: verifyLayoutFeatures())
        failures.append(contentsOf: verifyTruncationEdges())
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

    /// 用与标签外观不同的后台布局验证重建后仍保留调用方指定的显式布局尺寸。
    private func verifyExplicitLayoutAppearance(completion: @escaping ([String]) -> Void) {
        let size = CGSize(width: 200, height: 40)
        let label = TextForgeLabel(frame: CGRect(origin: .zero, size: size))
        label.overrideUserInterfaceStyle = .light
        view.addSubview(label)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let text = NSAttributedString(string: "右对齐", attributes: [
            .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label, .paragraphStyle: style
        ])
        _ = TextForgeLayout.prepare(
            attributedText: text, container: TextForgeContainer(size: size), renderScale: 2,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        ) { result in
            label.textLayout = result
            let fitted = label.sizeThatFits(size)
            let expected = result.textBoundingSize
            label.removeFromSuperview()
            completion(fitted == expected ? [] : ["explicit layout shrank after a trait change: \(fitted), expected \(expected)"])
        }
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

/// 模拟系统拒绝切换第一响应者时的标签。
private final class RejectingCopyLabel: TextForgeLabel {
    override func becomeFirstResponder() -> Bool { false }
}
