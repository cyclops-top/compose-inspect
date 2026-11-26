import Foundation

public struct TextComponentPreview: Equatable, Sendable {
    public let content: String?
    public let colorARGB: String?
    public let fontSize: Double?
    public let fontWeight: Int?
    public let fontUnit: String?

    public init?(node: InspectorNode) {
        guard node.kind == "ComposeNode", ["Text", "BasicText"].contains(node.shortName) else { return nil }
        func field(_ name: String, in candidate: InspectorNode) -> NodeParameter? {
            candidate.parameters.first { $0.group == .parameter && $0.name == name && !$0.isTruncated }
        }
        func text(_ candidate: InspectorNode) -> String? {
            for name in ["text.text", "text"] {
                guard let parameter = field(name, in: candidate) else { continue }
                if parameter.original == nil { return parameter.value }
                if parameter.original?["elements"] == nil, parameter.original?["isCollection"]?.boolean != true,
                   let text = parameter.original?["value"]?.string { return text }
            }
            return nil
        }
        let content = text(node)
        self.content = content
        // Resolve inherited Material Text styles from its own BasicText implementation only.
        // Do not borrow a sibling's color or a business child Text's styling.
        func implementation(_ candidate: InspectorNode) -> InspectorNode? {
            for child in candidate.children {
                if let content, child.shortName == "BasicText", text(child) == content { return child }
                let file = child.source?.file.components(separatedBy: "/").last
                if child.shortName == "Text" || file.map({ !["Text.kt", "BasicText.kt", "Layout.kt"].contains($0) }) == true { continue }
                if let found = implementation(child) { return found }
            }
            return nil
        }
        let basic = node.shortName == "Text" && content != nil ? implementation(node) : nil
        let candidates = [node, basic].compactMap { $0 }
        colorARGB = candidates.lazy.compactMap { candidate in
            field("color", in: candidate)?.colorARGB ?? field("style.color", in: candidate)?.colorARGB
        }.first
        fontWeight = candidates.lazy.compactMap { candidate in
            for name in ["fontWeight", "fontWeight.weight", "style.fontWeight", "style.fontWeight.weight"] {
                if let parameter = field(name, in: candidate), let weight = Self.weight(parameter.value) { return weight }
            }
            return nil
        }.first
        var size: Double?, unit: String?
        for candidate in candidates {
            for name in ["fontSize", "style.fontSize"] {
                guard let parameter = field(name, in: candidate) else { continue }
                let value = parameter.original?["value"]
                let rendered = (value?.string ?? parameter.value).lowercased()
                let suffix = value?["unit"]?.string?.lowercased() ?? ["sp", "em", "px"].first(where: rendered.hasSuffix)
                let scalar = suffix.flatMap { unit in rendered.hasSuffix(unit) ? Double(rendered.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) : nil }
                let measured = value?["value"]?.double ?? scalar
                guard let measured, measured.isFinite, measured > 0, let suffix, ["sp", "em", "px"].contains(suffix) else { continue }
                size = measured; unit = suffix; break
            }
            if size != nil { break }
        }
        fontSize = size
        fontUnit = unit
    }

    private static func weight(_ value: String) -> Int? {
        let named = ["thin": 100, "extralight": 200, "light": 300, "normal": 400,
                     "medium": 500, "semibold": 600, "bold": 700, "extrabold": 800, "black": 900]
        var token = value.lowercased()
        if token.hasPrefix("fontweight(weight="), token.hasSuffix(")") {
            token = String(token.dropFirst("fontweight(weight=".count).dropLast())
        } else if token.hasPrefix("fontweight.") { token = String(token.dropFirst("fontweight.".count)) }
        if let weight = Int(token), (1...1000).contains(weight) { return weight }
        return named[token]
    }
}

extension InspectorNode {
    /// Identifies the style supplying an omitted Material Text argument.
    public func inheritedTextStyle(for parameter: NodeParameter) -> NodeParameter? {
        guard kind == "ComposeNode", shortName == "Text", parameter.group == .parameter,
              ["color", "fontSize"].contains(parameter.name) else { return nil }
        let raw = parameter.original?["sdkParameter"]
        // Previously saved snapshots can still contain the packed Color.Unspecified.
        let packedUnset = parameter.name == "color"
            && raw?["inlineClass"]?.string == "androidx.compose.ui.graphics.Color"
            && raw?["value"]?["value"]?.int64 == 0x10
        guard parameter.value == "Unspecified" || packedUnset else { return nil }
        return parameters.first {
            $0.group == .parameter && $0.name == "style." + parameter.name && !$0.isTruncated
                && (parameter.name == "color" ? $0.colorARGB != nil : ($0.value.hasSuffix("sp") || $0.value.hasSuffix("em")))
        }
    }
}
