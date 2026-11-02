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
