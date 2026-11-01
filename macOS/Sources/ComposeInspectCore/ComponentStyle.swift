import Foundation
import CoreGraphics

/// Measured modifier layers, outside to inside. Values are never inferred from ancestor bounds.
public struct ComponentStyle: Codable, Equatable, Sendable {
    public struct Insets: Codable, Equatable, Sendable {
        public let left: Double, top: Double, right: Double, bottom: Double
        public init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
        }
    }
    public struct Shape: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String
        public let topLeft: Double, topRight: Double, bottomLeft: Double, bottomRight: Double
    }
    public struct Layer: Codable, Equatable, Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let kind: String
        public let bounds: CGRect
        public let padding: Insets?
        public let argb: String?
        public let alpha: Double
        public let shape: Shape?
        public let unsupported: String?
    }
    public let density: Double
    public let contentBounds: CGRect
    public let outerBounds: CGRect
    public let layers: [Layer]
    /// A custom layout can place its own modifier layers outside its reported outer box.
    /// These rectangles are already measured in screen pixels, including padding and offsets.
    /// Union only this layout's records; never add padding again or borrow child/parent bounds.
    public var selectionBounds: CGRect {
        ([contentBounds] + layers.map(\.bounds)).reduce(outerBounds) { result, rect in
            guard !rect.isEmpty else { return result }
            return result.isEmpty ? rect : result.union(rect)
        }
    }
    public var totalPadding: Insets {
        layers.compactMap(\.padding).reduce(Insets(left: 0, top: 0, right: 0, bottom: 0)) {
            Insets(left: $0.left + $1.left, top: $0.top + $1.top, right: $0.right + $1.right, bottom: $0.bottom + $1.bottom)
        }
    }
}

/// The AndroidComposeView owns this extension; associations never cross hosts or windows.
struct ComponentStyleCatalog {
    static let attribute = "composeinspect.styleLayers.v1"
    let records: [ComponentStyle]
    init?(node: InspectorJSON) {
        guard let raw = node["attributes"]?.array?.first(where: { $0["name"]?.string == Self.attribute })?["value"]?.string,
              let json = try? InspectorJSON.parse(Data(raw.utf8)), json["version"]?.int64 == 1,
              let density = json["density"]?.double, density.isFinite, density > 0,
              let entries = json["records"]?.array else { return nil }
        records = entries.compactMap { entry in
            guard let content = Self.rect(entry["contentBounds"]), let outer = Self.rect(entry["outerBounds"]),
                  let rawLayers = entry["layers"]?.array else { return nil }
            let layers: [ComponentStyle.Layer] = rawLayers.enumerated().compactMap { index, raw in
                guard let name = raw["name"]?.string, let kind = raw["kind"]?.string,
                      let bounds = Self.rect(raw["bounds"]) else { return nil }
                let padding = raw["padding"].flatMap { Self.insets($0) }
                let shape = raw["shape"].map { value in
                    let radii = value["radiiPx"]
                    return ComponentStyle.Shape(name: value["name"]?.string ?? "未提供名称", kind: value["kind"]?.string ?? "unknown",
                        topLeft: radii?["topLeft"]?.double ?? 0, topRight: radii?["topRight"]?.double ?? 0,
                        bottomLeft: radii?["bottomLeft"]?.double ?? 0, bottomRight: radii?["bottomRight"]?.double ?? 0)
                }
                return ComponentStyle.Layer(id: index, name: name, kind: kind, bounds: bounds, padding: padding,
                    argb: raw["argb"]?.string, alpha: raw["alpha"]?.double ?? 1, shape: shape,
                    unsupported: raw["unsupported"]?.string)
            }
            // Reject partial decoding: a missing layer must not look like an absent background.
            guard layers.count == rawLayers.count else { return nil }
            return ComponentStyle(density: density, contentBounds: content, outerBounds: outer, layers: layers)
        }
    }
    func style(for bounds: CGRect) -> ComponentStyle? {
        let matches = records.filter { $0.contentBounds == bounds }
        guard let first = matches.first, matches.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    private static func rect(_ value: InspectorJSON?) -> CGRect? {
        guard let value, let x = value["x"]?.double, let y = value["y"]?.double,
              let w = value["width"]?.double, let h = value["height"]?.double,
              [x,y,w,h].allSatisfy({ $0.isFinite && abs($0) < 1e12 }), w >= 0, h >= 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private static func insets(_ value: InspectorJSON) -> ComponentStyle.Insets? {
        guard let l = value["left"]?.double, let t = value["top"]?.double,
              let r = value["right"]?.double, let b = value["bottom"]?.double,
              [l,t,r,b].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return ComponentStyle.Insets(left: l, top: t, right: r, bottom: b)
    }
}
