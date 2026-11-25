import UIKit
import XCTest
@testable import TextForge

/// 同一段文字在系统 UILabel 路径与 TextForge 自定义排版路径下应得到相同的行高和行位置。
@MainActor
final class LineMetricsParityTests: XCTestCase {
    /// 两种路径的总高相差不超过 1 点，且每行墨迹顶边相差不超过 1 像素。
    private func assertSameRows(_ text: NSAttributedString, width: CGFloat = 300, lines: Int = 0,
                                file: StaticString = #filePath, line: UInt = #line) {
        let native = nativeLabel(text, width: width, lines: lines)
        let forged = forgedLabel(text, width: width, lines: lines)
        let unbounded = CGSize(width: width, height: 10_000)
        let nativeHeight = native.sizeThatFits(unbounded).height, forgedHeight = forged.sizeThatFits(unbounded).height
        XCTAssertEqual(forgedHeight, nativeHeight, accuracy: 1, "height", file: file, line: line)
        native.frame.size.height = ceil(nativeHeight)
        forged.frame.size.height = ceil(nativeHeight)
        let expected = inkRows(of: native).map(\.top), actual = inkRows(of: forged).map(\.top)
        XCTAssertEqual(actual.count, expected.count, "row count \(actual) vs \(expected)", file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a, b, accuracy: 1, "row tops \(actual) vs \(expected)", file: file, line: line)
        }
    }

    /// 系统字体 20pt 以上的纯中文行会换用行高更小的回退字体，自定义路径应按请求字体的度量排行。
    func testLargeChineseLinesKeepRequestedFontMetrics() {
        for size in [20.0, 24.0, 28.0] as [CGFloat] {
            assertSameRows(attributed("纯中文一\n有Latin二\n纯中文三", size: size))
            assertSameRows(attributed("创业天下标题", size: size, weight: .semibold))
            assertSameRows(attributed("这是同一段落里需要折成多行的纯中文内容用来看行距\n第二段纯中文", size: size), width: 200)
        }
    }

    /// 同一段落里的纯中文行与含拉丁字符的行应等高。
    func testChineseAndMixedLinesShareLinePitch() {
        let layout = TextForgeLayout(attributedText: attributed("第一行纯中文\n第二行有 Latin\n第三行纯中文\n第四行有数字 2026", size: 20),
                                     size: CGSize(width: 1000, height: 1000))
        let heights = layout.lines.map { $0.rect.height }
        XCTAssertEqual(heights.count, 4)
        for height in heights { XCTAssertEqual(height, heights[0], accuracy: 0.01, "\(heights)") }
        let offsets = layout.lines.map { $0.baseline - $0.rect.minY }
        for offset in offsets { XCTAssertEqual(offset, offsets[0], accuracy: 0.01, "\(offsets)") }
    }

    /// 行距、段距、行高倍数与最小最大行高下仍与系统路径一致。
    func testParagraphStylesMatchNativeLabel() {
        let styles: [(String, (NSMutableParagraphStyle) -> Void)] = [
            ("lineSpacing", { $0.lineSpacing = 6 }), ("paragraphSpacing", { $0.paragraphSpacing = 8 }),
            ("spacingBefore", { $0.paragraphSpacingBefore = 5 }), ("multiple", { $0.lineHeightMultiple = 1.5 }),
            ("minimum", { $0.minimumLineHeight = 30 }), ("fixed", { $0.minimumLineHeight = 28; $0.maximumLineHeight = 28 }),
            ("maximum", { $0.maximumLineHeight = 26 }), ("multiple+spacing", { $0.lineHeightMultiple = 1.5; $0.lineSpacing = 6 }),
            ("all", { $0.lineSpacing = 6; $0.paragraphSpacing = 8; $0.paragraphSpacingBefore = 5 }),
        ]
        for (name, configure) in styles {
            XCTContext.runActivity(named: name) { _ in
                assertSameRows(attributed("纯中文一\n有Latin二\n纯中文三", size: 20, style: configure))
                assertSameRows(attributed("这是同一段落里需要折成多行的纯中文内容用来看行距\n第二段纯中文", size: 20, style: configure), width: 200)
                assertSameRows(attributed("这是同一段落里需要折成多行的纯中文内容用来看行距还有更多更多的内容", size: 20, style: configure), width: 200, lines: 2)
            }
        }
    }

    /// 没有发生字体回退或回退字体更高的行不受影响。
    func testUnaffectedLinesKeepTheirGeometry() {
        for text in [attributed("Latin only line\nsecond", size: 20), attributed("十六号中文\n第二行", size: 16)] {
            assertSameRows(text)
        }
        let explicit = NSAttributedString(string: "显式苹方\nLatin", attributes: [.font: UIFont(name: "PingFangSC-Regular", size: 20)!,
                                                                              .foregroundColor: UIColor.black])
        assertSameRows(explicit)
    }

    /// 行内附件比文字高时仍由附件决定行高；附件比文字矮时按请求字体兜底。
    func testAttachmentsInChineseLines() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        for (size, bounds) in [(CGFloat(20), CGRect(x: 0, y: -6, width: 30, height: 30)), (22, CGRect(x: 0, y: -2, width: 14, height: 14))] {
            let text = NSMutableAttributedString(attributedString: attributed("图文混排", size: size))
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = bounds
            text.append(NSAttributedString(attachment: attachment))
            text.append(attributed("\n第二行纯中文", size: size))
            assertSameRows(text)
        }
    }

    /// 限高的不限行标签：被抬高的末行放不下时不应显示，与系统标签显示的行数一致。
    func testHeightLimitedLabelShowsSameNumberOfLines() {
        let text = attributed("第一段纯中文内容需要折行显示出来看看效果如何\n第二段也是纯中文内容同样需要折行显示\n第三段结束", size: 20)
        var mismatches: [String] = []
        for height in stride(from: 24, through: 170, by: 1) {
            let native = nativeLabel(text, width: 200, height: CGFloat(height))
            let layout = TextForgeLayout(attributedText: text, size: CGSize(width: 200, height: CGFloat(height)), insets: .zero,
                                         maximumNumberOfRows: 0, lineBreakMode: .byTruncatingTail)
            let expected = inkRows(of: native).count
            if layout.rowCount != expected { mismatches.append("H\(height): native \(expected) forged \(layout.rowCount)") }
            XCTAssertLessThanOrEqual(layout.textBoundingSize.height, CGFloat(height) + 1, "layout overflows its container at \(height)")
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: ", "))
    }

    /// 标签比补高后的一行还矮时，首行照常显示，不会因为放不下而整行消失。
    func testFirstLineIsKeptInTightContainers() {
        let text = attributed("紧凑高度里的中文标题", size: 20)
        for height in [CGFloat(20), 21, 22, 23, 24] {
            let layout = TextForgeLayout(attributedText: text, size: CGSize(width: 300, height: height), insets: .zero,
                                         maximumNumberOfRows: 1, lineBreakMode: .byTruncatingTail)
            XCTAssertEqual(layout.rowCount, 1, "h=\(height)")
            XCTAssertEqual(layout.visibleRange, NSRange(location: 0, length: text.length), "h=\(height)")
            let label = forgedLabel(text, width: 300, height: height, lines: 1)
            XCTAssertEqual(inkRows(of: label).count, 1, "h=\(height)")
        }
        // 不限行的紧凑标签同样保留首行。
        let multiline = TextForgeLayout(attributedText: text, size: CGSize(width: 300, height: 21), insets: .zero,
                                        maximumNumberOfRows: 0, lineBreakMode: .byTruncatingTail)
        XCTAssertEqual(multiline.rowCount, 1)
    }

    /// 长文追加内容时复用未变化段落的排版，补高后的行与重新排版的结果逐行一致。
    func testIncrementalUpdateMatchesFreshLayout() {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 180, height: 2000))
        label.numberOfLines = 0
        label.textVerticalAlignment = .top
        label.textTapAction = { _, _, _, _ in }
        let text = NSMutableAttributedString(attributedString: attributed("第一段是纯中文的大号内容需要折行。\n第二段 mixed 内容。\n第三段纯中文。\n", size: 22))
        label.attributedText = text
        _ = label.displayedTextLayout
        for step in 0..<4 {
            text.append(attributed(step % 2 == 0 ? "继续追加一段纯中文内容用来验证增量排版。\n" : "Appended latin paragraph 追加。\n", size: 22))
            label.attributedText = text
            let fresh = TextForgeLabel(frame: label.frame)
            fresh.numberOfLines = 0
            fresh.textVerticalAlignment = .top
            fresh.textTapAction = { _, _, _, _ in }
            fresh.attributedText = text
            guard let a = label.displayedTextLayout, let b = fresh.displayedTextLayout else { return XCTFail("no layout") }
            XCTAssertEqual(a.textBoundingSize, b.textBoundingSize, "step \(step)")
            XCTAssertEqual(a.lines.count, b.lines.count, "step \(step)")
            for (x, y) in zip(a.lines, b.lines) {
                XCTAssertEqual(x.range, y.range, "step \(step)")
                XCTAssertEqual(x.rect.minY, y.rect.minY, accuracy: 0.05, "step \(step)")
                XCTAssertEqual(x.rect.height, y.rect.height, accuracy: 0.05, "step \(step)")
                XCTAssertEqual(x.baseline, y.baseline, accuracy: 0.05, "step \(step)")
            }
            // 每一行都是补高后的行高。
            let pitch = UIFont.systemFont(ofSize: 22).lineHeight
            for line in a.lines { XCTAssertEqual(line.rect.height, pitch, accuracy: 0.05, "step \(step) \(line.range)") }
        }
    }

    /// 以换行结尾的文本在行数刚好用完时不再多出一个空行。
    func testTrailingNewlineDoesNotAddALineBeyondTheLimit() {
        assertSameRows(attributed("纯中文一\n纯中文二\n", size: 16), lines: 2)
        assertSameRows(attributed("单行标题\n", size: 16), lines: 1)
        // 未到行数上限时保留末尾空行，与系统标签一致。
        assertSameRows(attributed("纯中文一\n纯中文二\n", size: 16))
    }

    /// 逐字换行同样遵守行数上限。
    func testCharacterWrappingRespectsLineLimit() {
        let text = attributed(String(repeating: "这是一段很长的内容需要逐字换行，", count: 6), size: 16)
        let container = TextForgeContainer(size: CGSize(width: 200, height: 400))
        container.maximumNumberOfRows = 2
        container.lineBreakMode = .byCharWrapping
        let layout = TextForgeLayout(container: container, attributedText: text)
        XCTAssertEqual(layout.rowCount, 2)
        XCTAssertTrue(layout.isTruncated)
        let native = nativeLabel(text, width: 200, lines: 2, mode: .byCharWrapping)
        let forged = forgedLabel(text, width: 200, lines: 2, mode: .byCharWrapping)
        XCTAssertEqual(forged.sizeThatFits(CGSize(width: 200, height: 10_000)).height,
                       native.sizeThatFits(CGSize(width: 200, height: 10_000)).height, accuracy: 1)
        XCTAssertEqual(inkRows(of: forged).count, 2)
        // 英文单词仍在词中折断，说明逐字换行本身没有被改成按词换行。
        let latin = attributed("Supercalifragilisticexpialidocious and more words here", size: 16)
        let wrapped = TextForgeLayout(container: container, attributedText: latin)
        XCTAssertEqual(wrapped.lines.first?.range.length ?? 0, TextForgeLayout(
            attributedText: latin, size: CGSize(width: 200, height: 400), insets: .zero, maximumNumberOfRows: 0, lineBreakMode: .byCharWrapping
        ).lines.first?.range.length ?? -1)
    }
}
