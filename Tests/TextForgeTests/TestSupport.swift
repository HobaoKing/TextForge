import UIKit
import XCTest
@testable import TextForge

/// 渲染结果里的一行墨迹，坐标为 1x 像素。
struct InkRow: Equatable {
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int
}

/// 把视图按 1x 渲染后逐行扫描不透明像素，返回每个文本行的上下左右边界。
/// 用实际像素比较两种排版路径，避免断言依赖实现内部的中间量。
@MainActor
func inkRows(of view: UIView, alpha threshold: UInt8 = 70) -> [InkRow] {
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    guard width > 0, height > 0 else { return [] }
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    view.layer.render(in: context)
    var rows: [InkRow] = []
    var start = -1, left = Int.max, right = -1
    for y in 0..<height {
        var rowLeft = Int.max, rowRight = -1
        for x in 0..<width where data[(y * width + x) * 4 + 3] > threshold {
            rowLeft = min(rowLeft, x)
            rowRight = x
        }
        if rowRight >= 0 {
            if start < 0 { start = y; left = Int.max; right = -1 }
            left = min(left, rowLeft)
            right = max(right, rowRight)
        } else if start >= 0 {
            rows.append(InkRow(top: start, bottom: y - 1, left: left, right: right))
            start = -1
        }
    }
    if start >= 0 { rows.append(InkRow(top: start, bottom: height - 1, left: left, right: right)) }
    return rows
}

/// 按给定倍率渲染视图，返回 RGBA 像素和像素尺寸。调试线宽为一个设备像素，需要按设备倍率取样才看得清。
@MainActor
func pixelBuffer(of view: UIView, scale: CGFloat) -> (data: [UInt8], width: Int, height: Int) {
    let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
    var data = [UInt8](repeating: 0, count: max(0, width * height * 4))
    guard width > 0, height > 0,
          let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], 0, 0) }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    view.layer.render(in: context)
    return (data, width, height)
}

/// 统计视图渲染结果中满足条件的像素数，参数依次为 R、G、B、A。
@MainActor
func countPixels(of view: UIView, where matches: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    guard width > 0, height > 0 else { return 0 }
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    view.layer.render(in: context)
    var count = 0
    for offset in stride(from: 0, to: data.count, by: 4) where matches(data[offset], data[offset + 1], data[offset + 2], data[offset + 3]) {
        count += 1
    }
    return count
}

/// 走系统 UILabel 绘制的对照标签。
@MainActor
func nativeLabel(_ text: NSAttributedString, width: CGFloat, height: CGFloat = 400, lines: Int = 0,
                 mode: NSLineBreakMode = .byTruncatingTail) -> UILabel {
    let label = UILabel(frame: CGRect(x: 0, y: 0, width: width, height: height))
    label.numberOfLines = lines
    label.attributedText = text
    label.lineBreakMode = mode
    return label
}

/// 走 TextForge 自定义排版的标签：内容与对照标签相同，仅多一个点击回调。
@MainActor
func forgedLabel(_ text: NSAttributedString, width: CGFloat, height: CGFloat = 400, lines: Int = 0,
                 mode: NSLineBreakMode = .byTruncatingTail) -> TextForgeLabel {
    let label = TextForgeLabel(frame: CGRect(x: 0, y: 0, width: width, height: height))
    label.numberOfLines = lines
    label.attributedText = text
    label.lineBreakMode = mode
    label.textTapAction = { _, _, _, _ in }
    return label
}

@MainActor
func attributed(_ string: String, size: CGFloat, weight: UIFont.Weight = .regular,
                style configure: ((NSMutableParagraphStyle) -> Void)? = nil) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: UIColor.black]
    if let configure {
        let style = NSMutableParagraphStyle()
        configure(style)
        attributes[.paragraphStyle] = style
    }
    return NSAttributedString(string: string, attributes: attributes)
}

/// 用可继承位置的手势替身直接驱动标签的私有手势入口，与示例 App 的做法一致。
final class FakeTap: UITapGestureRecognizer {
    var point = CGPoint.zero
    var fakeState = UIGestureRecognizer.State.ended
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set {}
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

final class FakePress: UILongPressGestureRecognizer {
    var point = CGPoint.zero
    var fakeState = UIGestureRecognizer.State.began
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set {}
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

extension TextForgeLabel {
    /// 在给定点触发一次点击。
    @MainActor func simulateTap(at point: CGPoint) {
        let tap = FakeTap()
        tap.point = point
        _ = perform(NSSelectorFromString("handleTap:"), with: tap)
    }

    /// 在给定点触发一次长按开始。
    @MainActor func simulateLongPress(at point: CGPoint) {
        let press = FakePress()
        press.point = point
        _ = perform(NSSelectorFromString("handleLongPress:"), with: press)
    }
}
