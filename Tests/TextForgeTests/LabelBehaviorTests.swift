import UIKit
import XCTest
@testable import TextForge

/// 标签层与系统 UILabel 的行为对齐：多行缩字、基线锚点、改尺寸后的选区。
@MainActor
final class LabelBehaviorTests: XCTestCase {
    private let longText = String(repeating: "多行缩字测试内容 ", count: 9)

    private func shrinkingLabels(rows: Int, height: CGFloat, minimumScale: CGFloat = 0.1) -> (UILabel, TextForgeLabel) {
        let text = attributed(longText, size: 20)
        let native = nativeLabel(text, width: 200, height: height, lines: rows)
        let forged = forgedLabel(text, width: 200, height: height, lines: rows)
        for label in [native, forged] {
            label.minimumScaleFactor = minimumScale
            label.adjustsFontSizeToFitWidth = true
        }
        return (native, forged)
    }

    /// 多行文本在给定边界放不下时等比缩小，显示的行数和字的大小与系统标签相近。
    func testMultilineTextShrinksToFitLikeNativeLabel() {
        for (rows, height) in [(2, CGFloat(70)), (3, 90), (0, 80), (0, 120)] {
            let (native, forged) = shrinkingLabels(rows: rows, height: height)
            let expected = inkRows(of: native), actual = inkRows(of: forged)
            XCTAssertEqual(actual.count, expected.count, "rows=\(rows) h=\(height)")
            XCTAssertFalse(forged.isTruncated, "rows=\(rows) h=\(height)")
            guard let a = actual.first, let e = expected.first else { continue }
            XCTAssertEqual(CGFloat(a.bottom - a.top), CGFloat(e.bottom - e.top), accuracy: 3, "glyph height rows=\(rows) h=\(height)")
            if let unscaled = inkRows(of: forgedLabel(attributed("多行缩字", size: 20), width: 200, height: 40, lines: 1)).first {
                XCTAssertLessThan(a.bottom - a.top, unscaled.bottom - unscaled.top, "text did not shrink, rows=\(rows) h=\(height)")
            }
        }
    }

    /// 纯中文大字号的行会被补高；缩字要把补高后的行也算进去，结果既不截断也不越出标签。
    func testShrinkAccountsForRaisedChineseLines() {
        let text = attributed(String(repeating: "纯中文多行缩字测试内容", count: 6), size: 24)
        for height in stride(from: CGFloat(60), through: 130, by: 7) {
            let forged = forgedLabel(text, width: 200, height: height, lines: 0)
            forged.minimumScaleFactor = 0.1
            forged.adjustsFontSizeToFitWidth = true
            guard let layout = forged.displayedTextLayout else { return XCTFail("no layout") }
            XCTAssertFalse(layout.isTruncated, "h=\(height)")
            XCTAssertLessThanOrEqual(layout.textBoundingSize.height, height + 1, "h=\(height)")
            XCTAssertEqual(layout.visibleRange, NSRange(location: 0, length: text.length), "h=\(height)")
        }
    }

    /// 缩到下限仍放不下时停在下限并截断。
    func testShrinkStopsAtMinimumScale() {
        let (_, forged) = shrinkingLabels(rows: 2, height: 70, minimumScale: 0.8)
        XCTAssertTrue(forged.isTruncated)
        XCTAssertEqual(forged.displayedTextLayout?.rowCount, 2)
    }

    /// 系统标签测量时不缩字：多行标签的自适应尺寸应是未缩小的尺寸，缩字只发生在按实际边界绘制时。
    func testMeasurementIgnoresMultilineShrink() {
        let (native, forged) = shrinkingLabels(rows: 2, height: 70)
        let unbounded = CGSize(width: 200, height: 10_000)
        XCTAssertEqual(forged.sizeThatFits(unbounded).height, native.sizeThatFits(unbounded).height, accuracy: 1)
        XCTAssertEqual(forged.sizeThatFits(CGSize(width: 200, height: 70)).height, native.sizeThatFits(CGSize(width: 200, height: 70)).height, accuracy: 1)
        forged.preferredMaxLayoutWidth = 200
        native.preferredMaxLayoutWidth = 200
        XCTAssertEqual(forged.intrinsicContentSize.height, native.intrinsicContentSize.height, accuracy: 1)
        // 放得下的文本不受缩字开关影响。
        let short = forgedLabel(attributed("短文本", size: 20), width: 200, height: 70, lines: 2)
        short.adjustsFontSizeToFitWidth = true
        short.minimumScaleFactor = 0.3
        let plain = forgedLabel(attributed("短文本", size: 20), width: 200, height: 70, lines: 2)
        XCTAssertEqual(inkRows(of: short), inkRows(of: plain))
    }

    /// 用 frame 改变尺寸与用 bounds 一样清除选区，避免选区停在旧排版的位置。
    func testResizingThroughFrameClearsSelection() {
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        label.numberOfLines = 0
        label.isSelectable = true
        label.text = "一些可选中的文字 hello world 更多内容更多内容更多内容更多内容"
        XCTAssertTrue(label.selectText(in: NSRange(location: 0, length: 4)))
        label.frame.origin.x = 40
        XCTAssertEqual(label.selectedRange, NSRange(location: 0, length: 4), "moving must keep the selection")
        label.frame = CGRect(x: 40, y: 0, width: 120, height: 160)
        XCTAssertEqual(label.selectedRange.location, NSNotFound)
        XCTAssertTrue(label.selectText(in: NSRange(location: 0, length: 4)))
        label.bounds.size.width = 100
        XCTAssertEqual(label.selectedRange.location, NSNotFound)
    }

    /// 自动布局下，多行的自定义排版标签按可用宽度得到正确高度，宽度变化后高度跟着更新。
    func testAutoLayoutSizesMultilineLabel() {
        let text = String(repeating: "自动布局下的多行文本需要正确的高度。", count: 5)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
        let label = makeLabel(custom: true) { $0.numberOfLines = 0; $0.font = .systemFont(ofSize: 16); $0.text = text }
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.layoutIfNeeded()
        XCTAssertEqual(label.frame.width, 200)
        XCTAssertEqual(label.frame.height, label.sizeThatFits(CGSize(width: 200, height: 10_000)).height, accuracy: 0.5)
        let wide = label.frame.height
        container.frame.size.width = 120
        container.setNeedsLayout()
        container.layoutIfNeeded()
        XCTAssertEqual(label.frame.height, label.sizeThatFits(CGSize(width: 120, height: 10_000)).height, accuracy: 0.5)
        XCTAssertGreaterThan(label.frame.height, wide + 20)

        // 自适应高度的 Cell 常用的测量方式：内容视图定宽求高。
        let cell = UIView()
        let inner = makeLabel(custom: true) { $0.numberOfLines = 0; $0.font = .systemFont(ofSize: 16); $0.text = text }
        inner.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            inner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            inner.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),
        ])
        let fitted = cell.systemLayoutSizeFitting(CGSize(width: 200, height: 0), withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        XCTAssertEqual(fitted.height, inner.sizeThatFits(CGSize(width: 176, height: 10_000)).height + 16, accuracy: 1)
    }

    /// 整标签选中色和按压色是在绘制时临时改写前景色实现的；改色不会让已排好的行失效，
    /// 之后的局部重绘与滚动中的附件挂载照常工作。
    func testTintedDrawKeepsLayoutUsable() {
        var views: [UIView] = []
        let text = NSMutableAttributedString()
        for index in 0..<60 {
            let view = UIView()
            views.append(view)
            text.append(TextForgeAttachment.view(view, size: CGSize(width: 16, height: 16), font: .systemFont(ofSize: 16), alignment: .center))
            text.append(attributed("第\(index)段 一些正文内容 hello world\n", size: 16))
        }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let layout = TextForgeLayout(attributedText: text, size: CGSize(width: 200, height: 100_000))
        let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: 200, height: layout.textBoundingSize.height))
        label.textLayout = layout
        scroll.addSubview(label)
        scroll.contentSize = label.bounds.size
        label.layoutIfNeeded()
        XCTAssertTrue(views[0].superview === label)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let slice = CGRect(x: 0, y: label.bounds.height - 200, width: 200, height: 60)
        func render() -> Data {
            UIGraphicsImageRenderer(size: slice.size, format: format).pngData { context in
                context.cgContext.translateBy(x: -slice.minX, y: -slice.minY)
                context.cgContext.clip(to: slice)
                label.drawText(in: slice)
            }
        }
        let before = render()
        // 在文首附近以选中色重绘一次。
        label.highlightedTextColor = .red
        label.isHighlighted = true
        _ = UIGraphicsImageRenderer(size: scroll.bounds.size, format: format).image { context in
            context.cgContext.clip(to: scroll.bounds)
            label.drawText(in: scroll.bounds)
        }
        label.isHighlighted = false
        XCTAssertEqual(render(), before, "a tinted draw near the top must not disturb later partial draws near the end")
        scroll.contentOffset.y = label.bounds.height - scroll.bounds.height
        label.layoutIfNeeded()
        XCTAssertTrue(views[59].superview === label, "attachments near the end must still mount after a tinted draw")
        XCTAssertNil(views[0].superview)
    }

    // MARK: 基线锚点

    private struct Baselines {
        let first: CGFloat
        let lastFromBottom: CGFloat
        let frame: CGRect
    }

    /// 在自动布局容器里用两个标记视图读出标签首、末基线锚点相对其顶边、底边的距离。
    private func baselines(of label: UILabel, width: CGFloat? = nil, height: CGFloat? = nil) -> Baselines {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        label.translatesAutoresizingMaskIntoConstraints = false
        let first = UIView(), last = UIView()
        for marker in [first, last] {
            marker.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(marker)
        }
        container.addSubview(label)
        var constraints = [
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            first.topAnchor.constraint(equalTo: label.firstBaselineAnchor),
            last.topAnchor.constraint(equalTo: label.lastBaselineAnchor),
        ]
        if let width { constraints.append(label.widthAnchor.constraint(equalToConstant: width)) }
        if let height { constraints.append(label.heightAnchor.constraint(equalToConstant: height)) }
        NSLayoutConstraint.activate(constraints)
        container.layoutIfNeeded()
        return Baselines(first: first.frame.minY - label.frame.minY, lastFromBottom: label.frame.maxY - last.frame.minY, frame: label.frame)
    }

    private func makeLabel(custom: Bool, _ configure: (TextForgeLabel) -> Void) -> TextForgeLabel {
        let label = TextForgeLabel()
        label.font = .systemFont(ofSize: 18)
        configure(label)
        if custom { label.textTapAction = { _, _, _, _ in } }
        return label
    }

    /// 自定义排版路径的基线锚点与同一标签走系统路径时一致，也与实际绘制的基线一致。
    func testBaselineAnchorsMatchNativePath() {
        let multi = "第一行文字内容比较长需要折行显示，第二行继续显示剩余的内容直到结束"
        let cases: [(String, CGFloat?, (TextForgeLabel) -> Void)] = [
            ("single", nil, { $0.text = "基线 Baseline" }),
            ("single + insets", nil, { $0.text = "基线 Baseline"; $0.contentInsets = UIEdgeInsets(top: 10, left: 4, bottom: 6, right: 4) }),
            ("multi", 200, { $0.numberOfLines = 0; $0.text = multi }),
            // 系统对多行文本按垂直居中估算基线，上下内边距不等时两条路径都有同样的偏差，这里用对称内边距。
            ("multi + insets", 200, { $0.numberOfLines = 0; $0.text = multi; $0.contentInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4) }),
            ("two lines", 200, { $0.numberOfLines = 2; $0.text = multi }),
            ("large chinese", nil, { $0.font = .systemFont(ofSize: 24); $0.text = "大号中文标题" }),
        ]
        for (name, width, configure) in cases {
            let native = baselines(of: makeLabel(custom: false, configure), width: width)
            let label = makeLabel(custom: true, configure)
            let custom = baselines(of: label, width: width)
            XCTAssertEqual(custom.first, native.first, accuracy: 0.75, "\(name): first baseline")
            XCTAssertEqual(custom.lastFromBottom, native.lastFromBottom, accuracy: 0.75, "\(name): last baseline")
            // 与实际排版的基线核对：首行基线到标签顶边、末行基线到标签底边。
            guard let layout = label.displayedTextLayout, let head = layout.lines.first, let tail = layout.lines.last else {
                XCTFail("\(name): no layout")
                continue
            }
            let probe = NSRange(location: head.range.location, length: 1)
            let offset = label.rect(forRange: probe).minY - layout.rect(forRange: probe).minY
            XCTAssertEqual(custom.first, head.baseline + offset, accuracy: 1, "\(name): drawn first baseline")
            XCTAssertEqual(custom.lastFromBottom, custom.frame.height - (tail.baseline + offset), accuracy: 1, "\(name): drawn last baseline")
        }
    }

    /// 固定行高把文字在行内居中，单行标签的基线锚点跟随实际绘制的位置。
    func testFixedLineHeightBaselineFollowsDrawnText() {
        for (size, text) in [(CGFloat(18), "基线 Baseline"), (22, "大号中文标题"), (14, "Latin only")] {
            let label = makeLabel(custom: true) { $0.font = .systemFont(ofSize: size); $0.text = text; $0.fixedLineHeight = 36 }
            let measured = baselines(of: label)
            guard let layout = label.displayedTextLayout, let line = layout.lines.first else { return XCTFail("no layout") }
            XCTAssertEqual(measured.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(measured.first, line.baseline, accuracy: 1, "\(text): first baseline")
            XCTAssertEqual(measured.lastFromBottom, measured.frame.height - line.baseline, accuracy: 1, "\(text): last baseline")
        }
    }

    /// 标签级行距不改变"末行基线到底边"的距离。
    func testLineSpacingKeepsLastBaselineAtBottom() {
        let multi = "第一行文字内容比较长需要折行显示，第二行继续显示剩余的内容直到结束"
        let plain = baselines(of: makeLabel(custom: true) { $0.numberOfLines = 0; $0.text = multi }, width: 200)
        let spaced = baselines(of: makeLabel(custom: true) { $0.numberOfLines = 0; $0.text = multi; $0.lineSpacing = 8 }, width: 200)
        XCTAssertGreaterThan(spaced.frame.height, plain.frame.height + 10)
        XCTAssertEqual(spaced.first, plain.first, accuracy: 0.75)
        XCTAssertEqual(spaced.lastFromBottom, plain.lastFromBottom, accuracy: 0.75)
    }

    /// 基线对齐的 UIStackView 里，自定义排版的标签与相邻系统标签的基线重合。
    func testStackViewBaselineAlignment() {
        for alignment in [UIStackView.Alignment.firstBaseline, .lastBaseline] {
            let stack = UIStackView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
            stack.axis = .horizontal
            stack.alignment = alignment
            let reference = UILabel()
            reference.font = .systemFont(ofSize: 30)
            reference.text = "Ag"
            let label = makeLabel(custom: true) { $0.font = .systemFont(ofSize: 12); $0.text = "小字 small" }
            stack.addArrangedSubview(reference)
            stack.addArrangedSubview(label)
            stack.layoutIfNeeded()
            let referenceBaseline = reference.frame.minY + reference.font.ascender
            let labelBaseline = label.frame.minY + label.font.ascender
            XCTAssertEqual(labelBaseline, referenceBaseline, accuracy: 1, "alignment \(alignment.rawValue)")
        }
    }
}
