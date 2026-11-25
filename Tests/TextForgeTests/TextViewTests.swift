import UIKit
import XCTest
@testable import TextForge

/// 输入框的字数上限与高度自适应。
@MainActor
final class TextViewTests: XCTestCase {
    private var window: UIWindow!
    private var input: TextForgeTextView!
    private var changes: [String] = []
    private var limitHits = 0

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.isHidden = false
        input = TextForgeTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        input.font = .systemFont(ofSize: 16)
        window.addSubview(input)
        changes = []
        limitHits = 0
        input.onTextChange = { [unowned self] in self.changes.append($0) }
        input.onTextLimitReached = { [unowned self] in self.limitHits += 1 }
        XCTAssertTrue(input.becomeFirstResponder())
    }

    override func tearDown() async throws {
        input.resignFirstResponder()
        input.removeFromSuperview()
        window.isHidden = true
        window = nil
        input = nil
    }

    /// 超出上限的输入被截掉，回调只报告截断后的正文，并通知一次已达上限。
    func testTypingBeyondLimitIsTruncated() {
        input.maximumTextLength = 5
        input.insertText("abc")
        XCTAssertEqual(limitHits, 0)
        input.insertText("defgh")
        XCTAssertEqual(input.text, "abcde")
        XCTAssertEqual(changes, ["abc", "abcde"])
        XCTAssertEqual(limitHits, 1)
        // 已满时再输入：正文不变，不报告变化，但仍提示已达上限。
        input.insertText("x")
        XCTAssertEqual(input.text, "abcde")
        XCTAssertEqual(changes, ["abc", "abcde"])
        XCTAssertEqual(limitHits, 2)
        XCTAssertEqual(input.selectedRange, NSRange(location: 5, length: 0))
    }

    /// 在中间插入时截掉的是新输入的部分，原有文字和光标位置都保持。
    func testInsertionInTheMiddleKeepsExistingText() {
        input.maximumTextLength = 6
        input.text = "abcd"
        input.selectedRange = NSRange(location: 2, length: 0)
        input.insertText("12345")
        XCTAssertEqual(input.text, "ab12cd")
        XCTAssertEqual(input.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(changes, ["ab12cd"])
    }

    /// 上限按 UTF-16 长度计，截断落在完整字素上：放不下整个表情时整个去掉。
    func testTruncationKeepsWholeGraphemes() {
        input.maximumTextLength = 5
        input.insertText("ab")
        input.insertText("👨‍👩‍👧‍👦")
        XCTAssertEqual(input.text, "ab")
        input.insertText("😀c")
        XCTAssertEqual(input.text, "ab😀c")
        input.insertText("😀")
        XCTAssertEqual(input.text, "ab😀c")
        XCTAssertEqual(changes, ["ab", "ab😀c"])
    }

    /// 拼音组字期间不截断，上屏后再按上限处理。
    func testCompositionIsNotInterrupted() {
        input.maximumTextLength = 3
        input.insertText("ab")
        input.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        if input.markedTextRange != nil {
            XCTAssertEqual(input.text, "abnihao")
            XCTAssertEqual(limitHits, 0)
        }
        input.insertText("你好")
        XCTAssertEqual(input.text, "ab你")
        XCTAssertEqual(changes.last, "ab你")
        XCTAssertEqual(limitHits, 1)
    }

    /// 截断后宿主的 UITextViewDelegate 再收到一次通知，看到截断后的正文；撤销不会崩溃。
    func testDelegateSeesFinalTextAndUndoIsSafe() {
        final class Spy: NSObject, UITextViewDelegate {
            var seen: [String] = []
            func textViewDidChange(_ textView: UITextView) { seen.append(textView.text) }
        }
        let spy = Spy()
        input.delegate = spy
        input.maximumTextLength = 4
        input.insertText("abcdefgh")
        XCTAssertEqual(spy.seen, ["abcdefgh", "abcd"])
        // 截断后那笔输入的撤销记录已失效，被清空；再撤销不会越界崩溃。
        XCTAssertEqual(input.undoManager?.canUndo, false)
        input.undoManager?.undo()
        XCTAssertEqual(input.text, "abcd")
        // 之后的正常输入照常可以撤销。
        input.maximumTextLength = 0
        input.insertText("ef")
        input.undoManager?.undo()
        XCTAssertEqual(input.text, "abcd")
        withExtendedLifetime(spy) {}
    }

    /// 程序赋值不受上限约束，0 表示不限。
    func testProgrammaticTextAndZeroLimit() {
        input.maximumTextLength = 3
        input.text = "abcdefg"
        XCTAssertEqual(input.text, "abcdefg")
        XCTAssertEqual(limitHits, 0)
        input.maximumTextLength = 0
        input.insertText("more")
        XCTAssertEqual(input.text, "abcdefgmore")
    }

    // MARK: 粘贴与大段文本

    /// 测试进程没有剪贴板权限，这里用 UITextInput 的范围替换把一段文字写到当前选区，
    /// 截断逻辑与真实粘贴走同一处；真实的系统粘贴在 Swift 示例 App 里验证。
    private func paste(_ string: String) {
        guard let selection = input.selectedTextRange else { return XCTFail("no selection") }
        input.replace(selection, withText: string)
    }

    /// 粘贴一大段长文本：只留下上限以内的开头部分，回调一次，光标停在保留内容之后。
    func testPastingLongTextIsTruncatedOnce() {
        input.maximumTextLength = 200
        let long = String(repeating: "这是一段很长的粘贴内容，带标点和 English。\n", count: 4000)
        XCTAssertGreaterThan((long as NSString).length, 80_000)
        let start = CFAbsoluteTimeGetCurrent()
        paste(long)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(input.text, (long as NSString).substring(to: 200))
        XCTAssertEqual(changes, [input.text])
        XCTAssertEqual(limitHits, 1)
        XCTAssertEqual(input.selectedRange, NSRange(location: 200, length: 0))
        XCTAssertLessThan(elapsed, 1.0, "pasting 80k+ characters took \(elapsed)s")
    }

    /// 粘贴到中间、粘贴替换选区：截掉的都是粘贴进来的部分，前后原有文字保持。
    func testPastingIntoTheMiddleAndOverSelection() {
        input.maximumTextLength = 10
        input.text = "开头结尾"
        input.selectedRange = NSRange(location: 2, length: 0)
        paste("一二三四五六七八九十")
        XCTAssertEqual(input.text, "开头一二三四五六结尾")
        XCTAssertEqual(input.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(changes, ["开头一二三四五六结尾"])
        // 选中中间 6 个字再粘贴 9 个字：净增 3 个字超出，保留粘贴内容的前 6 个。
        input.selectedRange = NSRange(location: 2, length: 6)
        paste("甲乙丙丁戊己庚辛壬")
        XCTAssertEqual(input.text, "开头甲乙丙丁戊己结尾")
        XCTAssertEqual(changes.last, "开头甲乙丙丁戊己结尾")
        XCTAssertEqual(limitHits, 2)
    }

    /// 粘贴内容里的表情、换行按完整字素截断。
    func testPastedEmojiAndNewlinesAreCutAtGraphemeBoundaries() {
        input.maximumTextLength = 6
        paste("一\r\n二👨‍👩‍👧‍👦三")
        XCTAssertEqual(input.text, "一\r\n二")
        input.text = ""
        changes = []
        paste("😀😀😀😀")
        XCTAssertEqual(input.text, "😀😀😀")
        XCTAssertEqual(changes, ["😀😀😀"])
    }

    /// 把一个表情换成另一个高位代理相同的表情并带上更多内容：新旧正文的公共前缀停在代理对中间，
    /// 截断不能因此留下半个字符。
    func testReplacingEmojiWithSimilarEmojiKeepsSurrogatePairsWhole() {
        input.maximumTextLength = 6
        input.text = "ab😀cd"
        input.selectedRange = NSRange(location: 2, length: 2)
        paste("😁😂😃")
        XCTAssertEqual(input.text, "ab😁cd")
        XCTAssertEqual(input.text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count, 0)
        XCTAssertEqual(input.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(changes, ["ab😁cd"])
    }

    /// 正文原本就超过上限（程序赋值）时，用户再输入或粘贴只去掉新加的内容，不会删掉原有文字；删除和缩短照常。
    func testEditingTextThatAlreadyExceedsTheLimit() {
        input.maximumTextLength = 5
        input.text = "原有的十个字的正文内容"
        input.selectedRange = NSRange(location: 3, length: 0)
        input.insertText("新")
        XCTAssertEqual(input.text, "原有的十个字的正文内容")
        XCTAssertEqual(input.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(limitHits, 1)
        paste("粘贴")
        XCTAssertEqual(input.text, "原有的十个字的正文内容")
        input.selectedRange = NSRange(location: 0, length: 4)
        input.insertText("改")
        XCTAssertEqual(input.text, "改个字的正文内容")
        XCTAssertEqual(limitHits, 2)
        input.deleteBackward()
        XCTAssertEqual(input.text, "个字的正文内容")
        XCTAssertEqual(limitHits, 2)
    }

    /// 不设上限时大段写入和大段删除不受影响，回调各一次。
    func testUnlimitedLongText() {
        let long = String(repeating: "长文本", count: 20_000)
        paste(long)
        XCTAssertEqual((input.text as NSString).length, 60_000)
        XCTAssertEqual(changes.count, 1)
        input.selectedRange = NSRange(location: 0, length: 59_990)
        input.deleteBackward()
        XCTAssertEqual((input.text as NSString).length, 10)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(limitHits, 0)
    }

    /// 高度自适应开启时粘贴长文：高度停在最多行数、开启滚动，光标所在位置滚到可见区域内。
    func testPastingLongTextWithAutoHeight() {
        input.minimumNumberOfLines = 1
        input.maximumNumberOfLines = 4
        input.frame.size.height = input.preferredHeight
        var heights: [CGFloat] = []
        input.onPreferredHeightChange = { [unowned self] in heights.append($0); self.input.frame.size.height = $0 }
        paste(String(repeating: "粘贴进来的很多行内容\n", count: 300))
        input.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(input.preferredHeight, ceil(4 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertEqual(heights.last, input.preferredHeight)
        XCTAssertTrue(input.isScrollEnabled)
        // 光标在文末：内容应滚到底。TextKit 2 对视口外的内容只估算高度，光标矩形的绝对位置不稳定，按"到底"判断。
        let bottom = input.contentOffset.y + input.bounds.height - input.adjustedContentInset.bottom
        XCTAssertEqual(bottom, input.contentSize.height, accuracy: 2, "offset \(input.contentOffset.y) content \(input.contentSize.height)")
        XCTAssertGreaterThan(input.contentOffset.y, 1000)
        // 全部删掉后回到最少行数并停止滚动，内容回到顶部。
        input.selectedRange = NSRange(location: 0, length: (input.text as NSString).length)
        input.deleteBackward()
        input.layoutIfNeeded()
        XCTAssertEqual(input.preferredHeight, ceil(lineHeight() + chrome()), accuracy: 1)
        XCTAssertFalse(input.isScrollEnabled)
        XCTAssertLessThanOrEqual(input.contentOffset.y, 0.5)
    }

    /// 正文已经很长并在框内滚动时，继续输入不应每个字都整篇重新测量。
    func testTypingInLongTextStaysFast() {
        input.minimumNumberOfLines = 1
        input.maximumNumberOfLines = 4
        paste(String(repeating: "粘贴进来的很多行内容\n", count: 3000))
        input.layoutIfNeeded()
        XCTAssertTrue(input.isScrollEnabled)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { input.insertText("字") }
        let perKey = (CFAbsoluteTimeGetCurrent() - start) / 20
        XCTAssertLessThan(perKey, 0.02, "each keystroke took \(perKey * 1000) ms in a 33k-character text")
        XCTAssertEqual(input.preferredHeight, ceil(4 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertEqual(changes.count, 21)
    }

    // MARK: 高度自适应

    private func lineHeight() -> CGFloat { input.font!.lineHeight }
    private func chrome() -> CGFloat { input.textContainerInset.top + input.textContainerInset.bottom }

    /// 高度随内容在最小、最大行数之间变化，超过最大行数后开启滚动。
    func testPreferredHeightTracksContent() {
        var heights: [CGFloat] = []
        input.onPreferredHeightChange = { heights.append($0) }
        input.minimumNumberOfLines = 2
        input.maximumNumberOfLines = 4
        XCTAssertEqual(input.preferredHeight, ceil(2 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertFalse(input.isScrollEnabled)
        input.insertText("一\n二\n三")
        XCTAssertEqual(input.preferredHeight, ceil(3 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertEqual(input.intrinsicContentSize.height, input.preferredHeight)
        XCTAssertFalse(input.isScrollEnabled)
        input.insertText("\n四\n五\n六")
        XCTAssertEqual(input.preferredHeight, ceil(4 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertTrue(input.isScrollEnabled)
        input.text = ""
        XCTAssertEqual(input.preferredHeight, ceil(2 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertFalse(input.isScrollEnabled)
        XCTAssertGreaterThanOrEqual(heights.count, 3)
        XCTAssertEqual(heights.last, input.preferredHeight)
        XCTAssertEqual(Set(zip(heights, heights.dropFirst()).map { $0 == $1 }), [false], "no duplicate notifications: \(heights)")
    }

    /// 自动布局下不需要高度约束，输入框自己撑开并随内容和宽度变化。
    func testAutoLayoutGrowsWithContent() {
        input.removeFromSuperview()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        window.addSubview(host)
        input.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(input)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: host.topAnchor),
            input.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        input.minimumNumberOfLines = 1
        input.maximumNumberOfLines = 5
        host.layoutIfNeeded()
        let single = input.frame.height
        XCTAssertEqual(single, ceil(lineHeight() + chrome()), accuracy: 1)
        input.text = "这是一段足够长的文字，在两百点宽的输入框里需要折成好几行才能显示完整。"
        host.layoutIfNeeded()
        let wide = input.frame.height
        XCTAssertGreaterThan(wide, single + lineHeight() - 1)
        host.frame.size.width = 120
        host.setNeedsLayout()
        host.layoutIfNeeded()
        host.layoutIfNeeded()
        XCTAssertGreaterThan(input.frame.height, wide + lineHeight() - 1)
        XCTAssertLessThanOrEqual(input.frame.height, ceil(5 * lineHeight() + chrome()) + 1)
        host.removeFromSuperview()
    }

    /// 字数上限与高度自适应同时开启：截断、粘贴式的整段替换和直接改存储都不会在排版中途测量而崩溃。
    func testLimitAndAutoHeightTogether() {
        input.minimumNumberOfLines = 1
        input.maximumNumberOfLines = 2
        input.maximumTextLength = 4
        input.insertText("一二三😀五")
        XCTAssertEqual(input.text, "一二三")
        input.maximumTextLength = 0
        input.insertText("\n二\n三\n四")
        XCTAssertEqual(input.preferredHeight, ceil(2 * lineHeight() + chrome()), accuracy: 1)
        XCTAssertTrue(input.isScrollEnabled)
        // 宿主直接改存储没有 UIKit 通知，高度在下一次布局时跟上。
        input.textStorage.replaceCharacters(in: NSRange(location: 0, length: input.textStorage.length), with: "短")
        input.layoutIfNeeded()
        XCTAssertEqual(input.preferredHeight, ceil(lineHeight() + chrome()), accuracy: 1)
        XCTAssertFalse(input.isScrollEnabled)
    }

    /// 两个行数都为 0 时保持 UITextView 原有行为，不接管滚动开关。
    func testAutoHeightIsOptIn() {
        XCTAssertTrue(input.isScrollEnabled)
        input.insertText("一\n二\n三\n四\n五\n六\n七")
        XCTAssertTrue(input.isScrollEnabled)
        input.isScrollEnabled = false
        input.insertText("\n八")
        XCTAssertFalse(input.isScrollEnabled)
    }
}
