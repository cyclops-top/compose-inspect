import Foundation

/// The single input contract for building InspectorNode trees. Both capture adapters supply
/// screen-space nodes and decoded host-scoped styles. Backend payloads stay in the document
/// for inspection; the tree builder never interprets them.
struct SnapshotTreeInput {
    let document: InspectorDocument
    var styleCatalogs: [String: ComponentStyleCatalog] = [:]
    var hiddenParameterPaths: Set<String> = []

    /// Iterative traversal preserves raw JSON pointers and handles deep composition trees.
    static func visitNodes(in document: InspectorDocument,
                           _ visit: (InspectorJSON, String) throws -> Void) throws {
        guard let windows = document.root["windows"]?.array else { throw SnapshotImportError.schema("缺少 windows 数组") }
        var pending: [(InspectorJSON, String)] = []
        for (index, window) in windows.enumerated().reversed() {
            guard let root = window["root"] else { throw SnapshotImportError.schema("windows[\(index)] 缺少 root") }
            pending.append((root, "/windows/\(index)/root"))
        }
        while let (node, path) = pending.popLast() {
            try Task.checkCancellation()
            try visit(node, path)
            if let children = node["children"] {
                guard let values = children.array else { throw SnapshotImportError.schema("\(path)/children 不是数组") }
                for index in values.indices.reversed() {
                    pending.append((values[index], "\(path)/children/\(index)"))
                }
            }
        }
    }
}
