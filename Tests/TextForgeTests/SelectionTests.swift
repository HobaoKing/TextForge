import UIKit
import XCTest
@testable import TextForge

/// 选区的收起、全选与菜单扩展。
@MainActor
final class SelectionTests: XCTestCase {
    private var window: UIWindow!
    private var label: TextForgeLabel!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.isHidden = false
        label = TextForgeLabel(frame: CGRect(x: 20, y: 40, width: 200, height: 120))
        label.numberOfLines = 0
        label.isSelectable = true
        label.text = "条款 contract 更多可以选择的正文内容，足够折成两行以上。"
        window.addSubview(label)
    }

    override func tearDown() async throws {
        label.removeFromSuperview()
        window.isHidden = true
        window = nil
        label = nil
    }

    private var outsideRecognizers: [UIGestureRecognizer] {
        (window.gestureRecognizers ?? []).filter { $0.delegate === label }
    }

    /// 有选区时在窗口上旁观点击，点到标签外清除选区，选区消失后不再留下识别器。
    func testTapOutsideClearsSelection() throws {
        XCTAssertTrue(outsideRecognizers.isEmpty)
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        let recognizer = try XCTUnwrap(outsideRecognizers.first as? UITapGestureRecognizer)
        XCTAssertEqual(outsideRecognizers.count, 1)
        XCTAssertFalse(recognizer.cancelsTouchesInView, "must not swallow the touch meant for other controls")
        // 再次选择不重复安装。
        XCTAssertTrue(label.selectText(in: NSRange(location: 0, length: 2)))
        XCTAssertEqual(outsideRecognizers.count, 1)

        let tap = FakeTap()
        tap.fakeState = .ended
        _ = label.perform(NSSelectorFromString("handleOutsideTap:"), with: tap)
        XCTAssertEqual(label.selectedRange.location, NSNotFound)
        XCTAssertTrue(outsideRecognizers.isEmpty)
    }

    /// 关闭后不旁观点击，选区留到宿主自己清除。
    func testOutsideTapCanBeDisabled() {
        label.clearsSelectionOnOutsideTap = false
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        XCTAssertTrue(outsideRecognizers.isEmpty)
        label.clearsSelectionOnOutsideTap = true
        XCTAssertEqual(outsideRecognizers.count, 1)
        label.clearsSelectionOnOutsideTap = false
        XCTAssertTrue(outsideRecognizers.isEmpty)
        XCTAssertEqual(label.selectedRange, NSRange(location: 3, length: 8))
    }

    /// 离开窗口时选区和识别器一起清掉；不在窗口里创建的选区在进入窗口后开始旁观。
    func testOutsideTapFollowsWindow() {
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        label.removeFromSuperview()
        XCTAssertTrue(outsideRecognizers.isEmpty)
        XCTAssertEqual(label.selectedRange.location, NSNotFound)
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        XCTAssertTrue(outsideRecognizers.isEmpty)
        window.addSubview(label)
        XCTAssertEqual(outsideRecognizers.count, 1)
    }

    /// 全选只在选区还没占满所在片段时提供，执行后选中整段可见正文。
    func testSelectAll() {
        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        XCTAssertFalse(label.canPerformAction(selectAll, withSender: nil))
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        XCTAssertTrue(label.canPerformAction(selectAll, withSender: nil))
        label.selectAll(nil)
        let length = (label.text! as NSString).length
        XCTAssertEqual(label.selectedRange, NSRange(location: 0, length: length))
        XCTAssertEqual(label.selectedText, label.text)
        XCTAssertFalse(label.canPerformAction(selectAll, withSender: nil))
    }

    /// 截断后全选不越过省略号隐藏的部分。
    func testSelectAllStaysWithinVisibleSegment() {
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.frame.size = CGSize(width: 110, height: 30)
        XCTAssertTrue(label.isTruncated)
        XCTAssertTrue(label.selectText(in: NSRange(location: 0, length: 1)))
        label.selectAll(nil)
        let selected = label.selectedRange
        XCTAssertEqual(selected.location, 0)
        XCTAssertGreaterThan(selected.length, 1)
        XCTAssertLessThan(NSMaxRange(selected), (label.text! as NSString).length)
    }

    /// 自定义菜单项接在系统操作之后，回调拿到当前选区的文案和范围。
    func testCustomSelectionActions() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("edit menu interaction requires iOS 16") }
        var received: (String, NSRange)?
        label.selectionActions = [TextForgeSelectionAction(title: "引用") { _, text, range in received = (text, range) }]
        let interaction = UIEditMenuInteraction(delegate: label)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        let system = UIAction(title: "系统项") { _ in }
        XCTAssertNil(label.editMenuInteraction(interaction, menuFor: configuration, suggestedActions: [system]), "no selection, default menu")
        XCTAssertTrue(label.selectText(in: NSRange(location: 3, length: 8)))
        let menu = try XCTUnwrap(label.editMenuInteraction(interaction, menuFor: configuration, suggestedActions: [system]))
        XCTAssertEqual(menu.children.map(\.title), ["系统项", "引用"])
        let quote = try XCTUnwrap(menu.children.last as? UIAction)
        quote.performWithSender(nil, target: nil)
        XCTAssertEqual(received?.0, "contract")
        XCTAssertEqual(received?.1, NSRange(location: 3, length: 8))
        XCTAssertEqual(label.selectedRange, NSRange(location: 3, length: 8), "the action must not clear the selection")
    }
}
