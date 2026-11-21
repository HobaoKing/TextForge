import UIKit

/// 单个标签的临时选区，只在选择期间挂载。所有矩形均来自标签正在显示的同一份 TextKit 布局。
@MainActor
final class TextForgeLabelSelection: UIView {
    let layout: TextForgeLayout
    let segment: NSRange
    private(set) var range: NSRange
    private var initialWord: NSRange
    private var startHandle = CGRect.null
    private var endHandle = CGRect.null
    private var draggingStart: Bool?
    private var dragOffset = CGPoint.zero
    private var contentOrigin = CGPoint.zero
    private var pieces: [CGRect] = []
    private(set) var menuRect = CGRect.null

    /// segment 是包含起点且没有截断缺口的原文范围。选区视图仅在两个手柄处接受触摸。
    init(layout: TextForgeLayout, segment: NSRange, range: NSRange) {
        self.layout = layout
        self.segment = segment
        self.range = range
        initialWord = range
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { nil }

    /// 同一选区可从新长按位置重新开始；移动手柄时保留原来的选择起点。
    func setRange(_ value: NSRange, asAnchor: Bool) {
        range = value
        if asAnchor { initialWord = value }
        refresh(origin: contentOrigin)
    }

    /// 以视图局部坐标记录背景和手柄。跟随段落方向、垂直对齐和附件的实际排版位置。
    func refresh(origin: CGPoint) {
        contentOrigin = origin
        pieces = layout.runRects(for: range, inToken: false).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        menuRect = pieces.reduce(CGRect.null) { $0.union($1) }
        let string = layout.attributedText.string as NSString
        // 端点按完整字素定位；换行符无墨迹时，取可见选区的首尾片段。
        func handle(at index: Int, start: Bool) -> CGRect {
            let cluster = string.rangeOfComposedCharacterSequence(at: index)
            var rect = layout.containerRect(for: cluster, inToken: false).offsetBy(dx: origin.x, dy: origin.y)
            if rect.isEmpty { rect = (start ? pieces.first : pieces.last) ?? .null }
            guard !rect.isEmpty else { return .null }
            let x = start != layout.isRightToLeft(at: index) ? rect.minX : rect.maxX
            return CGRect(x: x - 1, y: rect.minY, width: 2, height: rect.height)
        }
        startHandle = handle(at: range.location, start: true)
        endHandle = handle(at: NSMaxRange(range) - 1, start: false)
        setNeedsDisplay()
    }

    /// 绘制分段底色和两端手柄，不改写富文本，也无需丢弃常态预绘位图。
    override func draw(_ rect: CGRect) {
        tintColor.withAlphaComponent(0.22).setFill()
        for piece in pieces { UIRectFillUsingBlendMode(piece, .normal) }
        tintColor.setFill()
        for (handle, start) in [(startHandle, true), (endHandle, false)] where !handle.isEmpty {
            UIBezierPath(rect: handle).fill()
            let y = start ? handle.minY : handle.maxY
            UIBezierPath(ovalIn: CGRect(x: handle.midX - 4, y: y - 4, width: 8, height: 8)).fill()
        }
    }

    /// 取离手指最近的手柄，正文其他位置仍可点击链接或滚动父列表。
    private func nearestHandle(at point: CGPoint) -> Bool? {
        let start = hypot(point.x - startHandle.midX, point.y - startHandle.minY)
        let end = hypot(point.x - endHandle.midX, point.y - endHandle.maxY)
        guard min(start, end) <= 16 else { return nil }
        return start <= end
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        nearestHandle(at: point) != nil
    }

    /// 长按不松手时以首个词为锚点扩选，超出正文或遇到截断缺口时停在可见片段边界。
    func extendWord(to point: CGPoint) {
        let cluster = nearestCluster(to: point)
        setRange(NSUnionRange(initialWord, cluster), asAnchor: false)
    }

    /// 手柄拖动从触摸起点计算偏移，始终在同一连续可见片段内，两个端点至少保留一个完整字素。
    @objc private func dragHandle(_ gesture: UIPanGestureRecognizer) {
        guard let label = superview as? TextForgeLabel else { return }
        let point = gesture.location(in: self)
        if gesture.state == .began {
            let translation = gesture.translation(in: self)
            let initial = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            draggingStart = nearestHandle(at: initial)
            guard let start = draggingStart else { return }
            let handle = start ? startHandle : endHandle
            dragOffset = CGPoint(x: handle.midX - initial.x, y: handle.midY - initial.y)
            label.dismissSelectionMenu()
        }
        guard let draggingStart else { return }
        switch gesture.state {
        case .began, .changed, .ended:
            let cluster = nearestCluster(to: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y))
            let string = layout.attributedText.string as NSString
            if draggingStart {
                let last = string.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
                let lower = min(cluster.location, last.location)
                setRange(NSRange(location: lower, length: NSMaxRange(range) - lower), asAnchor: false)
            } else {
                let first = string.rangeOfComposedCharacterSequence(at: range.location)
                let upper = max(NSMaxRange(cluster), NSMaxRange(first))
                setRange(NSRange(location: range.location, length: upper - range.location), asAnchor: false)
            }
            if gesture.state == .ended {
                self.draggingStart = nil
                label.showSelectionMenu()
            }
        case .cancelled, .failed:
            self.draggingStart = nil
            label.showSelectionMenu()
        default: break
        }
    }

    /// 将拖动点从选区视图坐标换算到布局，并限制到连续可见原文的完整字素。
    private func nearestCluster(to point: CGPoint) -> NSRange {
        let local = CGPoint(x: point.x - contentOrigin.x, y: point.y - contentOrigin.y)
        let index = min(max(layout.nearestSelectionIndex(to: local), segment.location), NSMaxRange(segment) - 1)
        return (layout.attributedText.string as NSString).rangeOfComposedCharacterSequence(at: index)
    }
}
