import Foundation
import CoreGraphics

public enum SnapshotImportError: LocalizedError {
    case noWindows, invalidBounds, invalidSize, schema(String)
    public var errorDescription: String? {
        switch self {
        case .noWindows: "组件树没有可检查的窗口。"
        case .invalidBounds: "组件树包含无效的边界数据。"
        case .invalidSize: "截图尺寸无效。"
        case .schema(let message): "JSON 结构不兼容：\(message)"
        }
    }
}

public enum SnapshotImporter {
    public static func decode(_ data: Data, imageSize: CGSize, packageName: String,
                              deviceName: String = "导入的快照", metadata: CaptureMetadata? = nil) throws -> InspectorSnapshot {
        let document = try InspectorDocument(data: data)
        return try decode(document, imageSize: imageSize, packageName: packageName, deviceName: deviceName, metadata: metadata)
    }

    static func decode(_ document: InspectorDocument, imageSize: CGSize, packageName: String,
                       deviceName: String = "导入的快照", metadata: CaptureMetadata? = nil) throws -> InspectorSnapshot {
        try decode(UIInspectorSnapshotAdapter.adapt(document), imageSize: imageSize,
                   packageName: packageName, deviceName: deviceName, metadata: metadata)
    }

    /// The shared tree builder. Capture-specific fields are consumed by the adapters above it.
    static func decode(_ input: SnapshotTreeInput, imageSize: CGSize, packageName: String,
                       deviceName: String = "导入的快照", metadata: CaptureMetadata? = nil) throws -> InspectorSnapshot {
        let document = input.document
        guard imageSize.width > 0, imageSize.height > 0 else { throw SnapshotImportError.invalidSize }
        guard let windows = document.root["windows"]?.array else { throw SnapshotImportError.schema("缺少 windows 数组") }
        guard !windows.isEmpty else { throw SnapshotImportError.noWindows }
        let roots = try windows.enumerated().map { index, window in
            guard let root = window["root"] else { throw SnapshotImportError.schema("windows[\(index)] 缺少 root") }
            return try convert(root, pointer: "/windows/\(index)/root", input: input)
        }
        return InspectorSnapshot(packageName: packageName, deviceName: deviceName, pixelSize: imageSize,
                                 roots: roots, document: document, captureMetadata: metadata)
    }

    private static func convert(_ raw: InspectorJSON, pointer: String, input: SnapshotTreeInput) throws -> InspectorNode {
        // Conversion has a large stack frame in debug builds. Keep depth on the heap so real
        // Compose trees can be decoded safely on Swift concurrency worker threads.
        var pending: [(raw: InspectorJSON, pointer: String, catalog: ComponentStyleCatalog?, ready: Bool)] = [(raw, pointer, nil, false)]
        var converted: [String: InspectorNode] = [:]
        while let frame = pending.popLast() {
            let children: [InspectorJSON]
            if let value = frame.raw["children"] {
                guard let array = value.array else { throw SnapshotImportError.schema("\(frame.pointer)/children 不是数组") }
                children = array
            } else { children = [] }
            if frame.ready {
                let nodes = children.indices.map { converted.removeValue(forKey: "\(frame.pointer)/children/\($0)")! }
                converted[frame.pointer] = try convertNode(frame.raw, pointer: frame.pointer, catalog: frame.catalog,
                    hiddenParameterPaths: input.hiddenParameterPaths, convertedChildren: nodes)
            } else {
                let catalog = input.styleCatalogs[frame.pointer] ?? frame.catalog
                pending.append((frame.raw, frame.pointer, catalog, true))
                for index in children.indices.reversed() {
                    pending.append((children[index], "\(frame.pointer)/children/\(index)", catalog, false))
                }
            }
        }
        return converted[pointer]!
    }

    private static func convertNode(_ raw: InspectorJSON, pointer: String, catalog: ComponentStyleCatalog?,
                                    hiddenParameterPaths: Set<String>,
                                    convertedChildren: [InspectorNode]) throws -> InspectorNode {
        guard let kind = raw["type"]?.string, let id = raw["id"]?.int64, let name = raw["className"]?.string,
              let bounds = raw["bounds"], let x = bounds["x"]?.double, let y = bounds["y"]?.double,
              let width = bounds["width"]?.double, let height = bounds["height"]?.double else {
            throw SnapshotImportError.schema("\(pointer) 的 type/id/className/bounds 不完整")
        }
        guard width >= 0, height >= 0, [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) < 1e12 }) else { throw SnapshotImportError.invalidBounds }
        var parameters: [NodeParameter] = []
        for (namespace, group) in [("parameters", NodeParameter.Group.parameter), ("attributes", .attribute),
                                    ("mergedSemantics", .mergedSemantics), ("unmergedSemantics", .unmergedSemantics)] {
            if let value = raw[namespace] {
                guard let values = value.array else { throw SnapshotImportError.schema("\(pointer)/\(namespace) 不是数组") }
                parameters += try flatten(values, group: group, pointer: pointer + "/" + namespace)
                    .filter { !hiddenParameterPaths.contains($0.id) }
            }
        }
        let label = parameters.lazy.filter {
            ["text", "contentdescription"].contains($0.name.lowercased())
        }.compactMap { $0.original.flatMap(Self.labelText) }.first
        let source = raw["sourceLocation"].flatMap { source -> SourceAnchor? in
            guard let file = source["fileName"]?.string else { return nil }
            return SourceAnchor(file: file, line: source["lineNumber"]?.int64.flatMap(Int.init(exactly:)),
                                packageHash: raw["sdkSource"]?["packageHash"]?.int64.flatMap(Int32.init(exactly:)))
        }
        let contentBounds = CGRect(x: x, y: y, width: width, height: height)
        let virtual = kind == "ComposeNode" && InspectorNode.isVirtualLayoutGroup(name: name, source: source)
        let style = kind == "ComposeNode" && !virtual ? catalog?.style(for: contentBounds, node: raw) : nil
        // Real layouts include only their own measured modifier envelope, including layers
        // placed outside a custom layout's reported size. Only composition wrappers borrow
        // descendants' bounds; clipping/scrolling parents must not expand to fit their children.
        let selectionBounds = virtual ? convertedChildren.reduce(contentBounds) { box, child in
            child.bounds.isEmpty ? box : (box.isEmpty ? child.bounds : box.union(child.bounds))
        } : style?.selectionBounds ?? contentBounds
        return InspectorNode(id: pointer, rawID: id, name: name, kind: kind, label: label,
                             bounds: selectionBounds, source: source,
                             parameters: parameters,
                             children: convertedChildren,
                             idResource: raw["idResource"]?.string, layoutResource: raw["layoutResource"]?.string, style: style,
                             clickTargetID: raw["sdkLayoutIdentity"]?.int64.map { "sdk:\($0)" })
    }

    public static func flatten(_ values: [InspectorJSON], group: NodeParameter.Group, pointer: String, parent: String = "") throws -> [NodeParameter] {
        var result: [NodeParameter] = []
        for (index, raw) in values.enumerated() {
            guard let name = raw["name"]?.string else { throw SnapshotImportError.schema("\(pointer)/\(index) 缺少参数名") }
            let path = parent.isEmpty ? name : parent + "." + name
            let id = "\(pointer)/\(index)"
            let resolvedGroup: NodeParameter.Group = group == .parameter && path.lowercased().contains("modifier") ? .modifier : group
            let value = raw["value"].map(displayValue) ?? (raw["isCollection"]?.boolean == true ? "（集合）" : "（参数组）")
            result.append(NodeParameter(id: id, name: path, value: value, group: resolvedGroup,
                                        isTruncated: raw["isTruncated"]?.boolean ?? false,
                                        original: raw, continuationToken: raw["continuationToken"]?.string))
            if let elements = raw["elements"] {
                guard let array = elements.array else { throw SnapshotImportError.schema("\(id)/elements 不是数组") }
                result += try flatten(array, group: resolvedGroup, pointer: id + "/elements", parent: path)
            }
        }
        return result
    }

    /// Collection values such as List[1] describe the container, not visible or accessible text.
    /// Keep the original parameter untouched; only the presentation label unwraps its strings.
    private static func labelText(_ raw: InspectorJSON) -> String? {
        guard raw["isTruncated"]?.boolean != true else { return nil }
        let text: String
        if raw["isCollection"]?.boolean == true {
            guard let elements = raw["elements"]?.array, !elements.isEmpty else { return nil }
            var parts: [String] = []
            for element in elements {
                guard let value = labelText(element) else { return nil }
                parts.append(value)
            }
            text = parts.joined(separator: " · ")
        } else {
            guard let value = raw["value"]?.string else { return nil }
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, text.count <= 80 else { return nil }
        return text
    }

    private static func displayValue(_ value: InspectorJSON) -> String {
        if let fields = value.object {
            if let scalar = fields["value"], let unit = fields["unit"]?.string { return scalar.display + unit.lowercased() }
            if let file = fields["fileName"]?.string, let line = fields["startLineNumber"]?.int64 { return "\(file):\(line)" }
            if let name = fields["name"]?.string, let type = fields["type"]?.string {
                return "@\(fields["namespace"]?.string.map { $0 + ":" } ?? "")\(type)/\(name)"
            }
        }
        return value.display
    }
}
