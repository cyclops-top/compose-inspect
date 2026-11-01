import Foundation

public struct TextComponentPreview: Equatable, Sendable {
    public let content: String
    public let colorARGB: String?
    public let fontSize: Double?
    public let fontUnit: String?

    public init?(node: InspectorNode) {
        guard node.kind == "ComposeNode", ["Text", "BasicText"].contains(node.shortName) else { return nil }
        func text(_ candidate: InspectorNode) -> String? {
            candidate.parameters.first(where: { $0.name == "text.text" })?.original?["value"]?.string
                ?? candidate.parameters.first(where: { $0.name == "text" })?.original?["value"]?.string
                ?? candidate.parameters.first(where: { $0.name == "text" && $0.original == nil })?.value
        }
        guard let content = text(node) else { return nil }
        self.content = content
        // Resolve inherited Material Text styles from its own BasicText implementation only.
        // Do not borrow a sibling's color or a business child Text's styling.
        func implementation(_ candidate: InspectorNode) -> InspectorNode? {
            for child in candidate.children {
                if child.shortName == "BasicText", text(child) == content { return child }
                let file = child.source?.file.components(separatedBy: "/").last
                if child.shortName == "Text" || file.map({ !["Text.kt", "BasicText.kt", "Layout.kt"].contains($0) }) == true { continue }
                if let found = implementation(child) { return found }
            }
            return nil
        }
        let basic = node.shortName == "BasicText" ? nil : implementation(node)
        let candidates = [node, basic].compactMap { $0 }
        colorARGB = candidates.lazy.compactMap { candidate in
            candidate.parameters.first(where: { $0.name == "color" && $0.colorARGB != nil })?.colorARGB
                ?? candidate.parameters.first(where: { $0.name == "style.color" })?.colorARGB
        }.first
        var size: Double?, unit: String?
        for candidate in candidates {
            for name in ["fontSize", "style.fontSize"] {
                guard let value = candidate.parameters.first(where: { $0.name == name })?.original?["value"],
                      let measured = value["value"]?.double, measured.isFinite, measured > 0,
                      let suffix = value["unit"]?.string else { continue }
                size = measured; unit = suffix.lowercased(); break
            }
            if size != nil { break }
        }
        fontSize = size; fontUnit = unit
    }
}
