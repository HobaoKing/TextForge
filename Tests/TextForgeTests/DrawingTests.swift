import UIKit
import XCTest
@testable import TextForge

/// 自定义绘制属性与排版调试叠层。
@MainActor
final class DrawingTests: XCTestCase {
    override func tearDown() async throws {
        TextForgeDebugOptions.shared = nil
    }

    private let isRed: (UInt8, UInt8, UInt8, UInt8) -> Bool = { r, g, b, a in a > 200 && r > 200 && g < 60 && b < 60 }
    private let isBlue: (UInt8, UInt8, UInt8, UInt8) -> Bool = { r, g, b, a in a > 200 && b > 200 && r < 60 && g < 60 }

    private func makeLabel(_ text: NSAttributedString, width: CGFloat = 120, height: CGFloat = 120) -> TextForgeLabel {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: width, height: height))
        label.numberOfLines = 0
        label.textVerticalAlignment = .top
        label.attributedText = text
        return label
    }

    /// 跨行的范围每行回调一次，首段、末段标记正确，矩形与同范围的排版矩形一致，并确实画到了屏幕上。
    func testDrawingIsCalledPerLineFragment() throws {
        let text = NSMutableAttributedString(attributedString: attributed("前文前文前文前文前文前文跨行的自定义绘制范围后文", size: 16))
        let range = (text.string as NSString).range(of: "前文跨行的自定义绘制范围")
        var calls: [(CGRect, Bool, Bool)] = []
        let drawing = TextForgeDrawing { context, rect, isFirst, isLast in
            calls.append((rect, isFirst, isLast))
            context.setFillColor(UIColor.red.cgColor)
            context.fill(rect)
        }
        drawing.apply(to: text, range: range)
        let label = makeLabel(text)
        let red = countPixels(of: label, where: isRed)
        let layout = try XCTUnwrap(label.displayedTextLayout)
        let expected = layout.rects(forRange: range)
        XCTAssertGreaterThan(expected.count, 1, "the range must wrap for this test")
        XCTAssertEqual(calls.count, expected.count)
        XCTAssertEqual(calls.map(\.1), [true] + Array(repeating: false, count: expected.count - 1))
        XCTAssertEqual(calls.map(\.2), Array(repeating: false, count: expected.count - 1) + [true])
        for (call, rect) in zip(calls, expected) {
            XCTAssertEqual(call.0.minX, rect.minX, accuracy: 0.01)
            XCTAssertEqual(call.0.minY, rect.minY, accuracy: 0.01)
            XCTAssertEqual(call.0.width, rect.width, accuracy: 0.01)
            XCTAssertEqual(call.0.height, rect.height, accuracy: 0.01)
        }
        XCTAssertGreaterThan(CGFloat(red), expected.reduce(0) { $0 + $1.width * $1.height } * 0.5, "fills drawn below glyphs must be visible")
    }

    /// 默认画在字形之下，文字仍然可见；设为画在字形之上时盖住文字。
    func testDrawingOrderRelativeToGlyphs() {
        func redPixels(above: Bool) -> Int {
            let text = NSMutableAttributedString(attributedString: attributed("■■■■■■", size: 20))
            let drawing = TextForgeDrawing { context, rect, _, _ in
                context.setFillColor(UIColor.red.cgColor)
                context.fill(rect)
            }
            drawing.drawsAboveText = above
            drawing.apply(to: text, range: NSRange(location: 0, length: text.length))
            return countPixels(of: makeLabel(text, width: 200, height: 40), where: isRed)
        }
        let below = redPixels(above: false), above = redPixels(above: true)
        XCTAssertGreaterThan(below, 0)
        XCTAssertGreaterThan(above, below + 200, "black glyphs must hide part of a fill drawn below them")
    }

    /// 只重绘一小块时与整块绘制逐像素一致，并且只回调与脏区相交的片段。
    func testPartialRedrawMatchesFullDraw() {
        let text = NSMutableAttributedString(attributedString: attributed(String(repeating: "自定义绘制的长段落内容，", count: 12), size: 15))
        var calls = 0
        let drawing = TextForgeDrawing { context, rect, isFirst, isLast in
            calls += 1
            context.setFillColor(UIColor.red.withAlphaComponent(0.4).cgColor)
            context.fill(rect.insetBy(dx: isFirst ? 6 : 0, dy: -3).offsetBy(dx: isLast ? -4 : 0, dy: 0))
        }
        drawing.outset = 6
        drawing.apply(to: text, range: NSRange(location: 4, length: text.length - 8))
        let label = makeLabel(text, width: 160, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: label.bounds.size, format: format)
        let full = renderer.image { _ in label.drawText(in: label.bounds) }
        let fullCalls = calls
        calls = 0
        let slice = CGRect(x: 20, y: 96, width: 90, height: 22)
        let partial = renderer.image { context in
            context.cgContext.clip(to: slice)
            label.drawText(in: slice)
        }
        XCTAssertGreaterThan(fullCalls, 6)
        XCTAssertLessThan(calls, fullCalls, "fragments far from the dirty rect must be skipped")
        XCTAssertGreaterThan(calls, 0)
        let patch = UIGraphicsImageRenderer(size: slice.size, format: format)
        let a = patch.pngData { _ in full.draw(at: CGPoint(x: -slice.minX, y: -slice.minY)) }
        let b = patch.pngData { _ in partial.draw(at: CGPoint(x: -slice.minX, y: -slice.minY)) }
        XCTAssertEqual(a, b)
    }

    /// 含自定义绘制的文本交给后台预排时退回主线程同步排版，回调不在后台线程执行。
    func testAsyncPreparationFallsBackToMainThread() async {
        let text = NSMutableAttributedString(attributedString: attributed("后台预排里的自定义绘制", size: 16))
        var offMain = false
        var calls = 0
        let drawing = TextForgeDrawing { context, rect, _, _ in
            calls += 1
            if !Thread.isMainThread { offMain = true }
            context.setFillColor(UIColor.red.cgColor)
            context.fill(rect)
        }
        drawing.apply(to: text, range: NSRange(location: 2, length: 4))
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let layout = await withCheckedContinuation { (done: CheckedContinuation<TextForgeLayout, Never>) in
            _ = TextForgeLayout.prepare(attributedText: text, size: label.bounds.size, insets: .zero, maximumNumberOfRows: 0,
                                        lineBreakMode: .byWordWrapping, renderScale: 2, traitCollection: label.traitCollection) { done.resume(returning: $0) }
        }
        label.textLayout = layout
        XCTAssertGreaterThan(countPixels(of: label, where: isRed), 100)
        XCTAssertGreaterThan(calls, 0)
        XCTAssertFalse(offMain)
    }

    /// 现成的下划线：指定颜色和线宽，画在文字排版矩形的底边之下，跨行时每行各一段。
    func testUnderlineFactory() throws {
        let text = NSMutableAttributedString(attributedString: attributed("查看详细规则以及更多需要折行的说明文字", size: 16))
        let range = NSRange(location: 0, length: text.length)
        TextForgeDrawing.underline(color: UIColor(red: 1, green: 0, blue: 0, alpha: 1), width: 2, offset: 1).apply(to: text, range: range)
        let label = makeLabel(text, width: 120, height: 100)
        let layout = try XCTUnwrap(label.displayedTextLayout)
        XCTAssertGreaterThan(layout.rowCount, 1)
        let scale = max(1, label.traitCollection.displayScale)
        let buffer = pixelBuffer(of: label, scale: scale)
        var redRows: [Int] = []
        for y in 0..<buffer.height {
            var count = 0
            for x in 0..<buffer.width {
                let o = (y * buffer.width + x) * 4
                if isRed(buffer.data[o], buffer.data[o + 1], buffer.data[o + 2], buffer.data[o + 3]) { count += 1 }
            }
            if count > 20 { redRows.append(y) }
        }
        let perRow = Int(2 * scale)
        XCTAssertEqual(redRows.count, layout.rowCount * perRow, "2pt line per row: \(redRows)")
        for (index, rect) in layout.rects(forRange: range).enumerated() where index * perRow < redRows.count {
            XCTAssertEqual(CGFloat(redRows[index * perRow]) / scale, rect.maxY + 1, accuracy: 0.5)
        }
    }

    /// 按设备倍率统计满足条件的像素数。
    private func devicePixels(of label: TextForgeLabel, where matches: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        let buffer = pixelBuffer(of: label, scale: max(1, label.traitCollection.displayScale))
        var count = 0
        for offset in stride(from: 0, to: buffer.data.count, by: 4)
        where matches(buffer.data[offset], buffer.data[offset + 1], buffer.data[offset + 2], buffer.data[offset + 3]) { count += 1 }
        return count
    }

    /// 调试叠层在每行基线处画一条线，位置与布局报告的基线一致；普通文本也切到自己的排版以保证对得上。
    func testDebugOverlayDrawsBaselines() throws {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 90))
        label.numberOfLines = 0
        label.textVerticalAlignment = .top
        label.font = .systemFont(ofSize: 18)
        label.textColor = .black
        label.text = "调试叠层的第一行内容比较长，需要折到第二行甚至第三行"
        XCTAssertEqual(devicePixels(of: label, where: isRed), 0)
        let options = TextForgeDebugOptions()
        options.baselineColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        label.debugOptions = options
        let layout = try XCTUnwrap(label.displayedTextLayout)
        XCTAssertGreaterThan(layout.rowCount, 1)
        // 找出红色像素连成线的像素行，应当每行文字一条，落在各自的基线上。
        let scale = max(1, label.traitCollection.displayScale)
        let buffer = pixelBuffer(of: label, scale: scale)
        var redRows: [Int] = []
        for y in 0..<buffer.height {
            var count = 0
            for x in 0..<buffer.width {
                let offset = (y * buffer.width + x) * 4
                if isRed(buffer.data[offset], buffer.data[offset + 1], buffer.data[offset + 2], buffer.data[offset + 3]) { count += 1 }
            }
            if count > buffer.width / 3 { redRows.append(y) }
        }
        XCTAssertEqual(redRows.count, layout.rowCount, "one crisp baseline per row: \(redRows)")
        for (row, line) in zip(redRows, layout.lines) {
            XCTAssertEqual(CGFloat(row) / scale, line.baseline, accuracy: 1 / scale + 0.01)
        }
        label.debugOptions = nil
        XCTAssertEqual(devicePixels(of: label, where: isRed), 0)
    }

    /// 全局配置对没有单独设置的标签生效；行框和附件槽都画出来，关掉后不再绘制。
    func testSharedDebugOptions() {
        let options = TextForgeDebugOptions()
        options.lineColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        options.attachmentColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        TextForgeDebugOptions.shared = options
        let text = NSMutableAttributedString(attributedString: attributed("图文", size: 18))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        text.append(TextForgeAttachment.image(image, size: image.size, font: .systemFont(ofSize: 18), alignment: .center))
        let label = makeLabel(text, width: 160, height: 40)
        let scale = max(1, label.traitCollection.displayScale)
        // 行框是整行的矩形边线，附件槽是 20 点见方的边线。
        XCTAssertGreaterThan(devicePixels(of: label, where: isBlue), Int(100 * scale))
        XCTAssertGreaterThan(devicePixels(of: label, where: isRed), Int(50 * scale))
        XCTAssertNotNil(TextForgeDebugOptions.standard().baselineColor)
        TextForgeDebugOptions.shared = nil
        XCTAssertEqual(devicePixels(of: makeLabel(text, width: 160, height: 40), where: isBlue), 0)
    }
}
