import UIKit

/// 工作线程只接收解析后的颜色和整数标记。主线程按需重绘同一份几何结果，宿主动态色闭包始终在主线程解析。
@MainActor
final class TextForgePaintPalette {
    struct Entry {
        let resolved: NSObject
        let index: Int?
    }

    struct Variant {
        let key: NSAttributedString.Key
        let liveValue: NSObject
    }

    let traits: UITraitCollection
    var hasImages = false
    var requiresExactGeometry = false
    private(set) var variants: [Variant] = []
    private(set) var variantKeys = Set<NSAttributedString.Key>()
    private var colors: [UIColor: UIColor] = [:]
    private var entries: [NSAttributedString.Key: [NSObject: Entry]] = [:]

    init(traits: UITraitCollection) { self.traits = traits }

    /// 标记随字串裁切及截断标记继承；后台无需访问原始动态颜色或其提供者。
    nonisolated static func marker(for key: NSAttributedString.Key) -> NSAttributedString.Key {
        NSAttributedString.Key("TextForge.Paint." + key.rawValue)
    }

    /// 首次遇到属性时冻结颜色和可变装饰；只有实际依赖外观的属性才附加索引。
    func entry(for value: NSObject, key: NSAttributedString.Key) -> Entry? {
        if let entry = entries[key]?[value] { return entry }
        let resolve: (UITraitCollection) -> NSObject
        let candidates: [UIColor]
        let live: NSObject
        if let color = value as? UIColor {
            candidates = [color]
            live = color
            resolve = { color.resolvedColor(with: $0) }
        } else if let shadow = value as? NSShadow {
            guard shadow.shadowColor == nil || shadow.shadowColor is UIColor else { return nil }
            let source = shadow.copy() as! NSShadow
            let color = source.shadowColor as? UIColor
            live = source
            candidates = [color].compactMap { $0 }
            resolve = { traits in
                let copy = source.copy() as! NSShadow
                copy.shadowColor = color?.resolvedColor(with: traits)
                return copy
            }
        } else if let background = value as? TextForgeBackground {
            let source = background.clone()
            live = source
            candidates = [source.fillColor, source.strokeColor].compactMap { $0 }
            resolve = { source.resolved(with: $0) }
        } else { return nil }
        var varies = false
        for color in candidates {
            let frozen = color.resolvedColor(with: traits)
            if frozen !== color {
                colors[color] = frozen
                varies = true
            }
        }
        let entry = Entry(resolved: resolve(traits), index: varies ? variants.count : nil)
        if varies {
            variantKeys.insert(key)
            variants.append(Variant(key: key, liveValue: live))
        }
        entries[key, default: [:]][value] = entry
        return entry
    }

    /// 比较实际使用的颜色；列表环境不同但输出相同的固定样式可直接使用原位图。
    func matches(_ target: UITraitCollection) -> Bool {
        traits == target || colors.allSatisfy { $0.key.resolvedColor(with: target).isEqual($0.value) }
    }
}
