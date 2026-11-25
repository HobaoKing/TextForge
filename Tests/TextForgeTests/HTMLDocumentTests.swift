import XCTest
@testable import TextForge

/// HTML 预处理：宿主接管图片时从标签里读出的声明尺寸。
final class HTMLDocumentTests: XCTestCase {
    private func slots(_ html: String) throws -> [TextForgeHTMLImageSlot] {
        let document = try TextForgeHTMLDocument.prepare(html, baseURL: URL(string: "https://example.invalid/"), css: "", takesImages: true)
        return document.slots.sorted { $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count < $1.key.count }.map(\.value)
    }

    func testInlinePixelStyleOverridesAttribute() throws {
        let slot = try XCTUnwrap(slots("<img src='a.png' width='100' height='40' style='width:20px; height: 8px'>").first)
        XCTAssertEqual(slot.width, 20)
        XCTAssertEqual(slot.height, 8)
    }

    /// 百分比、auto 等相对写法不能换算成点，这时保留属性里的像素值，而不是把它一并丢掉。
    func testRelativeStyleKeepsAttributeValue() throws {
        let all = try slots("""
        <img src='a.png' width='100' height='40' style='width:50%; height:auto'>
        <img src='b.png' width='600' style='width:100%;max-width:100%'>
        <img src='c.png' style='width:50%'>
        <img src='d.png' width='80%' height='0'>
        """)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0].width, 100)
        XCTAssertEqual(all[0].height, 40)
        XCTAssertEqual(all[1].width, 600)
        XCTAssertNil(all[1].height)
        XCTAssertNil(all[2].width)
        XCTAssertNil(all[3].width)
        XCTAssertNil(all[3].height)
    }

    /// 声明了宽度的图片在加载前就按声明尺寸占位，受最大栏宽限制。
    func testDeclaredWidthSizesPlaceholder() throws {
        let slot = try XCTUnwrap(slots("<img src='a.png' width='600' height='300' style='width:100%'>").first)
        XCTAssertEqual(slot.size(for: CGSize(width: 24, height: 24), maximumWidth: 300), CGSize(width: 300, height: 150))
    }
}
