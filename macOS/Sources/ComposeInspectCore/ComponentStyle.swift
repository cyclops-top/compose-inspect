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
    public struct CornerConfiguration: Codable, Equatable, Sendable {
        public let value: Double
        public let unit: String
        public var label: String { value.formatted(.number.precision(.fractionLength(0...2))) + unit }
    }
    public struct Shape: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String
        public let topLeft: Double, topRight: Double, bottomLeft: Double, bottomRight: Double
        public struct Command: Codable, Hashable, Sendable {
            public let verb: String
            public let coordinates: [Double]
        }
        public var commands: [Command]? = nil
        public var evenOdd: Bool? = nil
        public var corners: [String: CornerConfiguration]? = nil
        public func title(in bounds: CGRect) -> String {
            if kind == "rectangle" { return "矩形" }
            if kind == "path" { return "自定义路径" }
            if kind == "cut" { return "切角" }
            guard kind == "rounded" else { return "未知形状" }
            let half = min(bounds.width, bounds.height) / 2
            if half > 0 && [topLeft, topRight, bottomLeft, bottomRight].allSatisfy({ abs($0 - half) < 0.01 }) {
                return abs(bounds.width - bounds.height) < 0.01 ? "圆形" : "胶囊形"
            }
            return "圆角"
        }
    }
    public struct Shadow: Codable, Equatable, Sendable {
        public let elevationDp: Double?
        public let clip: Bool?
        public let ambientColor: String?
        public let spotColor: String?
    }
    public struct GraphicsParameter: Codable, Equatable, Sendable {
        public let name: String
        public let value: String
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
        public var shadow: Shadow? = nil
        public var graphicsParameters: [GraphicsParameter]? = nil
    }
    public let density: Double
    public let contentBounds: CGRect
    public let outerBounds: CGRect
    public let layers: [Layer]
    /// A custom layout can place its own modifier layers outside its reported outer box.
    /// These rectangles are already measured in screen pixels, including padding and offsets.
    /// The outer coordinator is a layout allocation, which offset can leave behind at the
    /// original position. Only content and measured style layers describe the selection area.
    public var selectionBounds: CGRect {
        layers.map(\.bounds).reduce(contentBounds) { result, rect in
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
    let records: [ComponentStyle]
    private let identityRecords: [String: [ComponentStyle]]
    init?(json: InspectorJSON) {
        guard json["version"]?.int64 == 1,
              let density = json["density"]?.double, density.isFinite, density > 0,
              let entries = json["records"]?.array else { return nil }
        var identities: [String: [ComponentStyle]] = [:]
        records = entries.compactMap { entry in
            let density = entry["density"]?.double ?? density
            guard density.isFinite, density > 0 else { return nil }
            guard let content = Self.rect(entry["contentBounds"]), let outer = Self.rect(entry["outerBounds"]),
                  let rawLayers = entry["layers"]?.array else { return nil }
            let layers: [ComponentStyle.Layer] = rawLayers.enumerated().compactMap { index, raw in
                guard let name = raw["name"]?.string, let kind = raw["kind"]?.string,
                      let bounds = Self.rect(raw["bounds"]) else { return nil }
                let padding = raw["padding"].flatMap { Self.insets($0) }
                let shape = raw["shape"].map { value in
                    let radii = value["radiiPx"]
                    var kind = value["kind"]?.string ?? "unknown"
                    if ["rounded", "cut"].contains(kind),
                       !["topLeft", "topRight", "bottomLeft", "bottomRight"].allSatisfy({ key in
                           guard let radius = radii?[key]?.double else { return false }
                           return radius.isFinite && radius >= 0
                       }) { kind = "unknown" }
                    var commands: [ComponentStyle.Shape.Command]?
                    if kind == "path" {
                        let lengths = ["Move": 2, "Line": 2, "Quadratic": 4, "Cubic": 6, "Close": 0]
                        if let rows = value["commands"]?.array, rows.count <= 16384 {
                            let parsed = rows.compactMap { row -> ComponentStyle.Shape.Command? in
                                guard let fields = row.array, let verb = fields.first?.string,
                                      lengths[verb] == fields.count - 1 else { return nil }
                                let coordinates = fields.dropFirst().compactMap(\.double)
                                guard coordinates.count == fields.count - 1, coordinates.allSatisfy(\.isFinite) else { return nil }
                                return .init(verb: verb, coordinates: coordinates)
                            }
                            if parsed.count == rows.count { commands = parsed }
                        }
                        if commands == nil { kind = "unknown" }
                    }
                    var shape = ComponentStyle.Shape(name: value["name"]?.string ?? "未提供名称", kind: kind,
                        topLeft: radii?["topLeft"]?.double ?? 0, topRight: radii?["topRight"]?.double ?? 0,
                        bottomLeft: radii?["bottomLeft"]?.double ?? 0, bottomRight: radii?["bottomRight"]?.double ?? 0)
                    shape.commands = commands
                    shape.evenOdd = value["evenOdd"]?.boolean
                    var corners: [String: ComponentStyle.CornerConfiguration] = [:]
                    for key in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
                        if let item = value["corners"]?[key], let number = item["value"]?.double,
                           number.isFinite, number >= 0, let unit = item["unit"]?.string,
                           ["dp", "px", "%"].contains(unit), unit != "%" || number <= 100 {
                            corners[key] = .init(value: number, unit: unit)
                        }
                    }
                    shape.corners = corners.isEmpty ? nil : corners
                    return shape
                }
                return ComponentStyle.Layer(id: index, name: name, kind: kind, bounds: bounds, padding: padding,
                    argb: raw["argb"]?.string, alpha: raw["alpha"]?.double ?? 1, shape: shape,
                    unsupported: raw["unsupported"]?.string, shadow: raw["shadow"].map {
                        ComponentStyle.Shadow(elevationDp: $0["elevationDp"]?.double, clip: $0["clip"]?.boolean,
                                              ambientColor: $0["ambientColor"]?.string, spotColor: $0["spotColor"]?.string)
                    }, graphicsParameters: raw["graphicsParameters"]?.array?.compactMap { item in
                        guard let key = item["name"]?.string, let value = item["value"]?.string else { return nil }
                        return .init(name: key, value: value)
                    })
            }
            // Reject partial decoding: a missing layer must not look like an absent background.
            guard layers.count == rawLayers.count else { return nil }
            let style = ComponentStyle(density: density, contentBounds: content, outerBounds: outer, layers: layers)
            if let identity = entry["layoutIdentity"]?.int64 { identities[String(identity), default: []].append(style) }
            return style
        }
        identityRecords = identities
    }
    func style(for bounds: CGRect, node: InspectorJSON? = nil) -> ComponentStyle? {
        if let identity = node?["sdkLayoutIdentity"]?.int64 {
            let exact = identityRecords[String(identity)] ?? []
            // Tooling combines a transformed origin with untransformed width/height.
            // A proven layout identity lets us use the measured four-corner screen bounds
            // even when rotation or scale makes that tooling rectangle different.
            guard let first = exact.first, exact.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        let matches = records.filter { $0.contentBounds == bounds }
        if let first = matches.first, matches.allSatisfy({ $0 == first }) { return first }
        // Equal content rectangles are common for a padded wrapper and its Surface. Only the
        // node's own shape can disambiguate them; merged semantics may describe a descendant.
        guard let evidence = node?["parameters"]?.array?.first(where: { $0["name"]?.string == "shape" }) else { return nil }
        let supported = matches.filter { style in
            style.layers.contains { layer in
                ["clip", "background"].contains(layer.kind) && Self.matchesShape(evidence, layer: layer, density: style.density)
            }
        }
        guard let first = supported.first, supported.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func matchesShape(_ evidence: InspectorJSON, layer: ComponentStyle.Layer, density: Double) -> Bool {
        guard evidence["isTruncated"]?.boolean != true, let name = evidence["value"]?.string,
              let shape = layer.shape else { return false }
        if name == "RectangleShape" { return shape.kind == "rectangle" }
        let size = min(layer.bounds.width, layer.bounds.height)
        guard size > 0 else { return false }
        let expected: [Double]
        if name == "CircleShape", shape.kind == "rounded" {
            expected = Array(repeating: size / 2, count: 4)
        } else if ["RoundedCornerShape", "AbsoluteRoundedCornerShape", "CutCornerShape", "AbsoluteCutCornerShape"].contains(name),
                  shape.kind == (name.contains("Cut") ? "cut" : "rounded"), let elements = evidence["elements"]?.array {
            var corners: [Double] = []
            let keys = name.hasPrefix("Absolute") && elements.contains(where: { $0["name"]?.string == "topLeft" }) ? ["topLeft", "topRight", "bottomLeft", "bottomRight"] : ["topStart", "topEnd", "bottomStart", "bottomEnd"]
            for key in keys {
                guard let corner = elements.first(where: { $0["name"]?.string == key }),
                      corner["isTruncated"]?.boolean != true,
                      let pixels = Self.cornerPixels(corner["value"], density: density, size: size) else { return false }
                corners.append(pixels)
            }
            let start = corners[0] + corners[2], end = corners[1] + corners[3]
            let startScale = start > size ? size / start : 1
            let endScale = end > size ? size / end : 1
            expected = [corners[0] * startScale, corners[1] * endScale,
                        corners[2] * startScale, corners[3] * endScale]
        } else { return false }
        let actual = [shape.topLeft, shape.topRight, shape.bottomLeft, shape.bottomRight]
        func equal(_ values: [Double]) -> Bool {
            zip(actual, values).allSatisfy { abs($0 - $1) < 0.01 }
        }
        // The catalog stores physical corners; Shape semantics use start/end. If both directions
        // match different records, the caller keeps the association ambiguous rather than guessing.
        return equal(expected) || (!name.hasPrefix("Absolute") && equal([expected[1], expected[0], expected[3], expected[2]]))
    }
    private static func cornerPixels(_ raw: InspectorJSON?, density: Double, size: Double) -> Double? {
        var value = raw?["value"]?.double
        var unit = raw?["unit"]?.string?.lowercased()
        // Compose exposes PercentCornerSize/PxCornerSize as InspectableValue strings.
        if let text = raw?.string {
            for suffix in ["%", "px", "dp"] where text.hasSuffix(suffix) {
                value = Double(text.dropLast(suffix.count)); unit = suffix
            }
            if text == "ZeroCornerSize" { return 0 }
        }
        guard let value, value.isFinite, value >= 0, let unit else { return nil }
        switch unit {
        case "dp": return value * density
        case "px": return value
        case "%", "percent": return value <= 100 ? size * value / 100 : nil
        default: return nil
        }
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
