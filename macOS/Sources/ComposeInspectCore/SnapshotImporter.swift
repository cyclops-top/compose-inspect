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
        guard imageSize.width > 0, imageSize.height > 0 else { throw SnapshotImportError.invalidSize }
        let document = try InspectorDocument(data: data)
        guard let windows = document.root["windows"]?.array else { throw SnapshotImportError.schema("缺少 windows 数组") }
        guard !windows.isEmpty else { throw SnapshotImportError.noWindows }
        let roots = try windows.enumerated().map { index, window in
            guard let root = window["root"] else { throw SnapshotImportError.schema("windows[\(index)] 缺少 root") }
            return try convert(root, pointer: "/windows/\(index)/root")
        }
        return InspectorSnapshot(packageName: packageName, deviceName: deviceName, pixelSize: imageSize,
                                 roots: roots, document: document, captureMetadata: metadata)
    }

    private static func convert(_ raw: InspectorJSON, pointer: String, catalog inherited: ComponentStyleCatalog? = nil) throws -> InspectorNode {
        let catalog = ComponentStyleCatalog(node: raw) ?? inherited
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
                parameters += try flatten(values, group: group, pointer: pointer + "/" + namespace).filter { $0.name != ComponentStyleCatalog.attribute }
            }
        }
        let label = parameters.first {
            ["text", "contentdescription", "testtag"].contains($0.name.lowercased())
                && !$0.value.isEmpty && $0.value.count <= 80 && !$0.isTruncated && $0.original?["value"]?.string != nil
        }?.value
        let source = raw["sourceLocation"].flatMap { source -> SourceAnchor? in
            guard let file = source["fileName"]?.string else { return nil }
            return SourceAnchor(file: file, line: source["lineNumber"]?.int64.flatMap(Int.init(exactly:)))
        }
        let children: [InspectorJSON]
        if let value = raw["children"] {
            guard let array = value.array else { throw SnapshotImportError.schema("\(pointer)/children 不是数组") }
            children = array
        } else { children = [] }
        let contentBounds = CGRect(x: x, y: y, width: width, height: height)
        let virtual = kind == "ComposeNode" && InspectorNode.isVirtualLayoutGroup(name: name, source: source)
        let style = kind == "ComposeNode" && !virtual ? catalog?.style(for: contentBounds) : nil
        let convertedChildren = try children.enumerated().map {
            try convert($0.element, pointer: "\(pointer)/children/\($0.offset)", catalog: catalog)
        }
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
                             idResource: raw["idResource"]?.string, layoutResource: raw["layoutResource"]?.string, style: style)
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
