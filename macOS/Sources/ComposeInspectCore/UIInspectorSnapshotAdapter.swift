import Foundation

/// ui-inspector uses the common node/parameter fields already, but transports style catalogs
/// as a JSON string in a View attribute. Decode that extension only at this backend boundary.
enum UIInspectorSnapshotAdapter {
    static let styleAttribute = "composeinspect.styleLayers.v1"

    static func adapt(_ document: InspectorDocument) throws -> SnapshotTreeInput {
        var input = SnapshotTreeInput(document: document)
        try SnapshotTreeInput.visitNodes(in: document) { node, path in
            let attributes = node["attributes"]?.array ?? []
            for (index, attribute) in attributes.enumerated() where attribute["name"]?.string == styleAttribute {
                input.hiddenParameterPaths.insert("\(path)/attributes/\(index)")
            }
            if let raw = attributes.first(where: { $0["name"]?.string == styleAttribute })?["value"]?.string,
               let json = try? InspectorJSON.parse(Data(raw.utf8)) {
                input.styleCatalogs[path] = ComponentStyleCatalog(json: json)
            }
        }
        return input
    }
}
