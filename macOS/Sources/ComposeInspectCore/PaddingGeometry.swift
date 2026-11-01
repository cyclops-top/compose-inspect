import Foundation
import CoreGraphics

public enum PaddingGeometry {
    /// Insets and bounds use the same unit. Corner intersections are deliberately excluded.
    /// For nested padding, the final content bounds also limit the tangential extent of each band.
    public static func regions(in bounds: CGRect, insets: ComponentStyle.Insets,
                               contentBounds: CGRect? = nil) -> [CGRect] {
        guard !bounds.isEmpty else { return [] }
        let left = min(bounds.width, max(0, insets.left))
        let right = min(bounds.width - left, max(0, insets.right))
        let top = min(bounds.height, max(0, insets.top))
        let bottom = min(bounds.height - top, max(0, insets.bottom))
        let content = contentBounds ?? bounds
        let minX = max(bounds.minX + left, content.minX)
        let maxX = min(bounds.maxX - right, content.maxX)
        let minY = max(bounds.minY + top, content.minY)
        let maxY = min(bounds.maxY - bottom, content.maxY)
        return [
            CGRect(x: minX, y: bounds.minY, width: max(0, maxX - minX), height: top),
            CGRect(x: bounds.maxX - right, y: minY, width: right, height: max(0, maxY - minY)),
            CGRect(x: minX, y: bounds.maxY - bottom, width: max(0, maxX - minX), height: bottom),
            CGRect(x: bounds.minX, y: minY, width: left, height: max(0, maxY - minY))
        ].filter { !$0.isEmpty }
    }
}
