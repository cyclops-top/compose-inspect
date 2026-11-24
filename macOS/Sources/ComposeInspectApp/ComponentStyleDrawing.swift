import ComposeInspectCore
import SwiftUI

enum ComponentStyleDrawing {
    static func outlineShape(style: ComponentStyle?, bounds: CGRect) -> ComponentStyle.Shape? {
        guard let style else { return nil }
        if let clip = style.layers.first(where: { $0.kind == "clip" && $0.bounds == bounds }) {
            return clip.shape?.kind == "unknown" ? nil : clip.shape
        }
        return style.layers.first { $0.kind == "background" && $0.bounds == bounds && $0.shape?.kind != "unknown" }?.shape
    }

    static func path(in rect: CGRect, shape: ComponentStyle.Shape?, scale: CGFloat) -> Path {
        guard let shape else { return Path(rect) }
        if shape.kind == "path", let commands = shape.commands {
            var path = Path()
            for command in commands {
                let values = command.coordinates
                func point(_ index: Int) -> CGPoint {
                    CGPoint(x: rect.minX + values[index] * rect.width, y: rect.minY + values[index + 1] * rect.height)
                }
                switch (command.verb, values.count) {
                case ("Move", 2): path.move(to: point(0))
                case ("Line", 2): path.addLine(to: point(0))
                case ("Quadratic", 4): path.addQuadCurve(to: point(2), control: point(0))
                case ("Cubic", 6): path.addCurve(to: point(4), control1: point(0), control2: point(2))
                case ("Close", 0): path.closeSubpath()
                default: return Path(rect)
                }
            }
            return shape.evenOdd == true ? path.normalized(eoFill: true) : path
        }
        if shape.kind == "cut" {
            let tl = shape.topLeft * scale, tr = shape.topRight * scale
            let bl = shape.bottomLeft * scale, br = shape.bottomRight * scale
            return Path { path in
                path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
                path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bl))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
                path.closeSubpath()
            }
        }
        guard shape.kind == "rounded" else { return Path(rect) }
        return UnevenRoundedRectangle(topLeadingRadius: shape.topLeft * scale,
            bottomLeadingRadius: shape.bottomLeft * scale, bottomTrailingRadius: shape.bottomRight * scale,
            topTrailingRadius: shape.topRight * scale, style: .circular).path(in: rect)
    }
}
