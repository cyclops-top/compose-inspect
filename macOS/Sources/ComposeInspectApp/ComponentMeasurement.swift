import ComposeInspectCore
import SwiftUI

struct ComponentMeasurement {
    private static let lineColor = Color(red: 1, green: 0.38, blue: 0.43)

    struct Line: Equatable {
        let start: CGPoint
        let end: CGPoint
        let horizontal: Bool

        var pixels: CGFloat { horizontal ? abs(end.x - start.x) : abs(end.y - start.y) }
    }

    let lines: [Line]
    let coincidentCenter: CGPoint?
    let density: Double?

    init?(from selected: CGRect, to hovered: CGRect, selectedDensity: Double?, hoveredDensity: Double?) {
        guard !selected.isEmpty, !hovered.isEmpty else { return nil }
        // Local Compose densities can differ. A shared gap has a single dp value only if they agree.
        density = selectedDensity.flatMap { $0.isFinite && $0 > 0 && $0 == hoveredDensity ? $0 : nil }

        coincidentCenter = selected == hovered ? CGPoint(x: selected.midX, y: selected.midY) : nil
        let x = Self.gap(selected.minX...selected.maxX, hovered.minX...hovered.maxX)
        let y = Self.gap(selected.minY...selected.maxY, hovered.minY...hovered.maxY)
        switch (x, y) {
        case let (x?, y?):
            // Join the closest corners with one segment for each axis.
            lines = [Self.horizontal(from: x.start, to: x.end, at: y.start),
                     Self.vertical(from: y.start, to: y.end, at: x.end)]
        case let (x?, nil):
            let midY = (max(selected.minY, hovered.minY) + min(selected.maxY, hovered.maxY)) / 2
            lines = [Self.horizontal(from: x.start, to: x.end, at: midY)]
        case let (nil, y?):
            let midX = (max(selected.minX, hovered.minX) + min(selected.maxX, hovered.maxX)) / 2
            lines = [Self.vertical(from: y.start, to: y.end, at: midX)]
        case (nil, nil):
            // Partial overlap keeps the selection as the reference. Full containment uses the outer frame.
            let hoveredContainsSelection = hovered.contains(selected)
            let reference = hoveredContainsSelection ? hovered : selected
            let target = hoveredContainsSelection ? selected : hovered
            lines = coincidentCenter == nil ? Self.insets(from: reference, to: target) : []
        }
    }

    private static func insets(from reference: CGRect, to target: CGRect) -> [Line] {
        let overlap = reference.intersection(target)
        var lines: [Line] = []
        if target.minX >= reference.minX {
            lines.append(horizontal(from: reference.minX, to: target.minX, at: overlap.midY))
        }
        if target.maxX <= reference.maxX {
            lines.append(horizontal(from: target.maxX, to: reference.maxX, at: overlap.midY))
        }
        if target.minY >= reference.minY {
            lines.append(vertical(from: reference.minY, to: target.minY, at: overlap.midX))
        }
        if target.maxY <= reference.maxY {
            lines.append(vertical(from: target.maxY, to: reference.maxY, at: overlap.midX))
        }
        return lines
    }

    private static func gap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> (start: CGFloat, end: CGFloat)? {
        if a.upperBound <= b.lowerBound { return (a.upperBound, b.lowerBound) }
        if b.upperBound <= a.lowerBound { return (a.lowerBound, b.upperBound) }
        return nil
    }

    private static func horizontal(from start: CGFloat, to end: CGFloat, at y: CGFloat) -> Line {
        Line(start: CGPoint(x: start, y: y), end: CGPoint(x: end, y: y), horizontal: true)
    }

    private static func vertical(from start: CGFloat, to end: CGFloat, at x: CGFloat) -> Line {
        Line(start: CGPoint(x: x, y: start), end: CGPoint(x: x, y: end), horizontal: false)
    }

    func label(for line: Line) -> String {
        let value = Double(line.pixels) / (density ?? 1)
        return value.formatted(.number.precision(.fractionLength(0...1))) + (density == nil ? " px" : " dp")
    }

    func draw(in context: GraphicsContext, size: CGSize, mapper: CoordinateMapper) {
        func display(_ point: CGPoint) -> CGPoint {
            mapper.display(CGRect(origin: point, size: .zero)).origin
        }

        var labels: [CGRect] = []
        var path = Path()
        for line in lines {
            let start = display(line.start)
            let end = display(line.end)
            path.move(to: start)
            path.addLine(to: end)
            for point in start == end ? [start] : [start, end] {
                let dx: CGFloat = line.horizontal ? 0 : 2
                let dy: CGFloat = line.horizontal ? 2 : 0
                path.move(to: CGPoint(x: point.x - dx, y: point.y - dy))
                path.addLine(to: CGPoint(x: point.x + dx, y: point.y + dy))
            }
        }
        context.stroke(path, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.stroke(path, with: .color(Self.lineColor), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        for line in lines {
            let center = display(CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2))
            let text = context.resolve(Text(label(for: line)).font(.system(size: 11, weight: .medium))
                .monospacedDigit().foregroundStyle(.white))
            let textSize = text.measure(in: size)
            let dx = line.horizontal ? 0 : textSize.width / 2 + 7
            let dy = line.horizontal ? -textSize.height / 2 - 5 : 0
            let preferred = Self.labelFrame(at: CGPoint(x: center.x + dx, y: center.y + dy), textSize: textSize, in: size)
            let alternate = Self.labelFrame(at: CGPoint(x: center.x - dx, y: center.y - dy), textSize: textSize, in: size)
            let frame = labels.contains(where: { $0.intersects(preferred) }) ? alternate : preferred
            Self.drawLabel(text, frame: frame, in: context)
            labels.append(frame)
        }
        if let coincidentCenter {
            let text = context.resolve(Text("边界重合").font(.system(size: 11, weight: .medium)).foregroundStyle(.white))
            Self.drawLabel(text, frame: Self.labelFrame(at: display(coincidentCenter), textSize: text.measure(in: size), in: size), in: context)
        }
    }

    private static func labelFrame(at point: CGPoint, textSize: CGSize, in size: CGSize) -> CGRect {
        let width = textSize.width + 8
        let height = textSize.height + 4
        return CGRect(x: max(0, min(point.x - width / 2, size.width - width)),
                      y: max(0, min(point.y - height / 2, size.height - height)), width: width, height: height)
    }

    private static func drawLabel(_ text: GraphicsContext.ResolvedText, frame: CGRect, in context: GraphicsContext) {
        context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(.black.opacity(0.78)))
        context.draw(text, at: CGPoint(x: frame.midX, y: frame.midY))
    }
}
