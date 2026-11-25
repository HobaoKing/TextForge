import UIKit
import XCTest
@testable import TextForge

/// VoiceOver 的链接转子与自定义操作。
@MainActor
final class AccessibilityTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.isHidden = false
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func makeLabel(tapped: @escaping (String) -> Void) -> TextForgeLabel {
        let text = NSMutableAttributedString(string: "同意《用户协议》和《隐私政策》，详见官网。", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        for name in ["《用户协议》", "《隐私政策》"] {
            let highlight = TextForgeHighlight(color: .systemBlue, backgroundColor: nil)
            highlight.tapAction = { _, _, _, _ in tapped(name) }
            highlight.apply(to: text, range: (text.string as NSString).range(of: name))
        }
        text.addAttribute(.link, value: URL(string: "https://example.invalid/")!, range: (text.string as NSString).range(of: "官网"))
        let label = TextForgeLabel(frame: CGRect(x: 20, y: 60, width: 160, height: 80))
        label.numberOfLines = 0
        label.attributedText = text
        label.highlightTapAction = { _, text, range, _ in tapped((text.string as NSString).substring(with: range)) }
        window.addSubview(label)
        return label
    }

    private func walk(_ rotor: UIAccessibilityCustomRotor, direction: UIAccessibilityCustomRotor.Direction) -> [UIAccessibilityElement] {
        var elements: [UIAccessibilityElement] = []
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = direction
        while let result = rotor.itemSearchBlock(predicate), let element = result.targetElement as? UIAccessibilityElement {
            elements.append(element)
            predicate.currentItem = result
            if elements.count > 10 { break }
        }
        return elements
    }

    /// 链接转子按出现顺序列出每个可点击的高亮和链接，前后方向都能走完，激活等同点击。
    func testLinkRotorListsAndActivatesLinks() throws {
        var tapped: [String] = []
        let label = makeLabel { tapped.append($0) }
        let rotor = try XCTUnwrap(label.accessibilityCustomRotors?.first { $0.systemRotorType == .link })
        let forward = walk(rotor, direction: .next)
        XCTAssertEqual(forward.map { $0.accessibilityLabel ?? "" }, ["《用户协议》", "《隐私政策》", "官网"])
        XCTAssertEqual(walk(rotor, direction: .previous).map { $0.accessibilityLabel ?? "" }, ["官网", "《隐私政策》", "《用户协议》"])
        XCTAssertTrue(forward.allSatisfy { $0.accessibilityTraits.contains(.link) })

        XCTAssertTrue(forward[1].accessibilityActivate())
        XCTAssertTrue(forward[2].accessibilityActivate())
        XCTAssertEqual(tapped, ["《隐私政策》", "官网"])

        // 每个元素的位置就是该链接在屏幕上的矩形，互不重叠且都落在标签范围内。
        let labelFrame = UIAccessibility.convertToScreenCoordinates(label.bounds, in: label)
        let frames = forward.map(\.accessibilityFrame)
        for frame in frames {
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(labelFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(frame) outside \(labelFrame)")
        }
        let expected = UIAccessibility.convertToScreenCoordinates(label.rect(forRange: (label.text! as NSString).range(of: "官网")), in: label)
        XCTAssertEqual(frames[2].origin.x, expected.origin.x, accuracy: 0.5)
        XCTAssertEqual(frames[2].origin.y, expected.origin.y, accuracy: 0.5)
        XCTAssertEqual(frames[2].width, expected.width, accuracy: 0.5)
    }

    /// 换文后旧元素失效：不再有位置，激活不触发任何回调，转子从新内容重新开始。
    func testRotorElementsExpireWithContent() throws {
        var tapped: [String] = []
        let label = makeLabel { tapped.append($0) }
        let rotor = try XCTUnwrap(label.accessibilityCustomRotors?.first { $0.systemRotorType == .link })
        let stale = try XCTUnwrap(walk(rotor, direction: .next).first)
        label.text = "没有链接的普通文本"
        XCTAssertFalse(stale.accessibilityActivate())
        XCTAssertTrue(stale.accessibilityFrame.isEmpty)
        XCTAssertTrue(tapped.isEmpty)
        XCTAssertNil(label.accessibilityCustomRotors, "plain text exposes no link rotor")
        XCTAssertNil(rotor.itemSearchBlock(UIAccessibilityCustomRotorSearchPredicate()))
    }

    /// 看不见的链接（被截断）不进转子；截断标记里的可点击项会进。
    func testRotorFollowsTruncation() throws {
        var tapped: [String] = []
        let label = makeLabel { tapped.append($0) }
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.truncationToken = TextForgeContainer.readMoreToken { _, _, _, _ in tapped.append("全文") }
        label.frame.size = CGSize(width: 150, height: 24)
        let rotor = try XCTUnwrap(label.accessibilityCustomRotors?.first { $0.systemRotorType == .link })
        let names = walk(rotor, direction: .next).map { $0.accessibilityLabel ?? "" }
        XCTAssertEqual(names.last, "…全文")
        XCTAssertFalse(names.contains("官网"))
        XCTAssertTrue(walk(rotor, direction: .next).last?.accessibilityActivate() ?? false)
        XCTAssertEqual(tapped, ["全文"])
    }

    /// 宿主自己的转子保留，原有的自定义操作不变。
    func testHostRotorsAndActionsAreKept() {
        let label = makeLabel { _ in }
        let host = UIAccessibilityCustomRotor(name: "标题") { _ in nil }
        label.accessibilityCustomRotors = [host]
        XCTAssertEqual(label.accessibilityCustomRotors?.count, 2)
        XCTAssertTrue(label.accessibilityCustomRotors?.first === host)
        XCTAssertEqual(label.accessibilityCustomActions?.map(\.name), ["《用户协议》", "《隐私政策》", "官网"])
    }
}
