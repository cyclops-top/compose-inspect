import Foundation
import CoreGraphics

/// Adapts SDK data to the same document and node model used by every workspace interaction.
/// The untouched SDK response remains in sdkCapture (and capture metadata keeps the original bytes).
public enum SDKSnapshotImporter {
    public static func decode(_ data: Data, imageSize: CGSize, packageName: String) throws -> InspectorSnapshot {
        let document = try SDKInspectorClient.validateResponse(data, package: packageName)
        return try decode(document, imageSize: imageSize, packageName: packageName)
    }

    static func decode(_ document: InspectorDocument, imageSize: CGSize, packageName: String) throws -> InspectorSnapshot {
        guard document.root["complete"]?.boolean == true,
              let diagnostics = document.root["diagnostics"]?.array, diagnostics.isEmpty else {
            let reasons = document.root["diagnostics"]?.array?.map(\.display).joined(separator: "；") ?? "响应不完整"
            throw CommandFailure.failed("SDK 组件树采集不完整：\(reasons)")
        }
        guard let windows = document.root["windows"]?.array else { throw SnapshotImportError.schema("SDK 缺少 windows") }
        var normalized: [InspectorJSON] = []
        var nextID: Int64 = 1
        for (windowIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            guard let tables = window["tables"]?.array, let offset = window["screenOffset"]?.array,
                  offset.count == 2, let x = offset[0].double, let y = offset[1].double,
                  x.isFinite, y.isFinite else { throw SnapshotImportError.schema("SDK 窗口数据不完整") }
            // WeakHashMap table iteration order is unstable. Sort complete branches for repeat captures.
            var branches: [[InspectorJSON]] = []
            for table in tables {
                guard let tree = table["tree"], tree.object != nil else { throw SnapshotImportError.schema("SDK Composition 表缺少 tree") }
                let nodes = try convert(tree, offset: CGPoint(x: x, y: y), nextID: &nextID)
                if !nodes.isEmpty {
                    if let index = table["styleCatalogIndex"]?.int64 {
                        guard let catalogs = window["styleCatalogs"]?.array, index >= 0, index < catalogs.count else {
                            throw SnapshotImportError.schema("SDK 样式目录索引无效")
                        }
                        let catalog = catalogs[Int(index)]
                        // Keep the catalog scoped to this host/table. Its measurements are already
                        // screen pixels; only tooling group bounds need the window offset above.
                        let box = nodes.reduce(CGRect.null) { $0.union(rect($1["bounds"])) }
                        var host: [String: InspectorJSON] = [
                            "type": .string("ViewNode"), "id": .number(String(nextID)),
                            "className": .string(table["hostView"]?.string ?? "ComposeHost"),
                            "bounds": bounds(box), "children": .array(nodes), "styleCatalogIndex": .number(String(index))
                        ]
                        var warnings = catalog["diagnostics"]?.array?.map(\.display) ?? []
                        if let error = catalog["error"]?.string { warnings.append(error) }
                        if !warnings.isEmpty {
                            host["attributes"] = .array([.object(["name": .string("样式采集限制"),
                                "value": .string(warnings.joined(separator: "；"))])])
                        }
                        branches.append([.object(host)])
                        nextID += 1
                    } else { branches.append(nodes) }
                }
            }
            let children = orderedChildren(branches)
            // View-only windows are not evidence that a usable Compose capture succeeded.
            guard !children.isEmpty else { continue }
            let box = children.reduce(CGRect.null) { $0.union(rect($1["bounds"])) }
            let root: InspectorJSON = .object([
                "type": .string("ViewNode"), "id": .number(String(nextID)),
                "className": .string(window["rootClass"]?.string ?? "Window"),
                "bounds": bounds(box), "children": .array(children)
            ])
            nextID += 1
            normalized.append(.object(["root": root, "sdkWindow": .object([
                "index": window["index"] ?? .null, "screenOffset": .array(offset),
                "captureIndex": .number(String(windowIndex))
            ])]))
        }
        guard !normalized.isEmpty else { throw CommandFailure.failed("SDK 未返回可用的 Compose 组件树。") }
        let canonical: InspectorJSON = .object([
            "captureBackend": .string("sdk"), "windows": .array(normalized), "sdkCapture": document.root
        ])
        let document = InspectorDocument(root: canonical)
        return try SnapshotImporter.decode(document, imageSize: imageSize, packageName: packageName)
    }

    private struct LayoutInteraction {
        let bounds: InspectorJSON?
        let value: InspectorJSON?
        let error: String?
        let identity: InspectorJSON?
    }

    private static func convert(_ root: InspectorJSON, offset: CGPoint, nextID: inout Int64) throws -> [InspectorJSON] {
        var pending: [(raw: InspectorJSON, path: String, ready: Bool)] = [(root, "0", false)]
        var converted: [String: [InspectorJSON]] = [:]
        var layoutRoots: [String: [LayoutInteraction]] = [:]
        var count = 0
        while let frame = pending.popLast() {
            try Task.checkCancellation()
            guard let children = frame.raw["children"]?.array else { throw SnapshotImportError.schema("SDK group 缺少 children") }
            if !frame.ready {
                count += 1
                guard count <= 30000 else { throw SnapshotImportError.schema("SDK 节点数超出限制") }
                pending.append((frame.raw, frame.path, true))
                for index in children.indices.reversed() { pending.append((children[index], "\(frame.path)/\(index)", false)) }
                continue
            }
            let nodes = children.indices.flatMap { converted.removeValue(forKey: "\(frame.path)/\($0)") ?? [] }
            // Layout groups are often anonymous. Follow composition ownership up to the nearest
            // layout boundary, not arbitrary equal rectangles elsewhere in this host. Two roots
            // are enough to mark a multi-layout call ambiguous, so deep wrappers stay bounded.
            var layouts: [LayoutInteraction] = []
            for index in children.indices {
                let childRoots = layoutRoots.removeValue(forKey: "\(frame.path)/\(index)") ?? []
                layouts.append(contentsOf: childRoots.prefix(2 - layouts.count))
            }
            if frame.raw["kind"]?.string == "layout" {
                layouts = [LayoutInteraction(bounds: frame.raw["boundsInWindow"], value: frame.raw["interaction"],
                                             error: frame.raw["interactionError"]?.string, identity: frame.raw["layoutIdentity"])]
            }
            layoutRoots[frame.path] = layouts
            guard let name = frame.raw["name"]?.string, !name.isEmpty else {
                converted[frame.path] = nodes
                continue
            }
            guard let rawBounds = frame.raw["boundsInWindow"]?.array, rawBounds.count == 4,
                  let left = rawBounds[0].double, let top = rawBounds[1].double,
                  let right = rawBounds[2].double, let bottom = rawBounds[3].double,
                  [left, top, right, bottom].allSatisfy({ $0.isFinite && abs($0) < 1e12 }),
                  right >= left, bottom >= top else { throw SnapshotImportError.invalidBounds }
            guard let parameters = frame.raw["parameters"]?.array else { throw SnapshotImportError.schema("SDK group 缺少 parameters") }
            var node: [String: InspectorJSON] = [
                "type": .string("ComposeNode"), "id": .number(String(nextID)), "className": .string(name),
                "bounds": bounds(CGRect(x: left + offset.x, y: top + offset.y, width: right - left, height: bottom - top)),
                "children": .array(nodes), "parameters": .array(try parameters.map(parameter)),
                "sdkInline": frame.raw["inline"] ?? .bool(false)
            ]
            nextID += 1
            if layouts.count == 1, let layout = layouts.first, layout.bounds == frame.raw["boundsInWindow"] {
                node["sdkLayoutIdentity"] = layout.identity
                if let interaction = layout.value {
                    node["unmergedSemantics"] = semantics(interaction)
                    if let merged = interaction["merged"] { node["mergedSemantics"] = semantics(merged) }
                    if let error = interaction["mergedError"]?.string {
                        node["attributes"] = .array([.object(["name": .string("合并语义采集限制"), "value": .string(error)])])
                    }
                }
                if let error = layout.error {
                    node["attributes"] = .array([.object(["name": .string("交互采集限制"), "value": .string(error)])])
                }
            }
            if let source = frame.raw["source"], let file = source["file"]?.string {
                node["sourceLocation"] = .object(["fileName": .string(file), "lineNumber": source["line"] ?? .null])
                node["sdkSource"] = source
            }
            converted[frame.path] = [.object(node)]
        }
        return converted["0"] ?? []
    }

    private static func semantics(_ interaction: InspectorJSON) -> InspectorJSON {
        var fields: [InspectorJSON] = []
        for (key, name) in [("hasClickAction", "OnClick"), ("hasLongClickAction", "OnLongClick"),
                            ("disabled", "Disabled"), ("selected", "Selected"), ("focused", "Focused"),
                            ("toggleableState", "ToggleableState")] {
            guard let value = interaction[key], value.boolean != nil || value.string != nil else { continue }
            fields.append(.object(["name": .string(name), "value": value]))
        }
        return .array(fields)
    }

    private static func parameter(_ raw: InspectorJSON) throws -> InspectorJSON {
        guard let name = raw["name"]?.string, let value = raw["value"], value.object != nil else {
            throw SnapshotImportError.schema("SDK 参数缺少 name/value")
        }
        var result = try valueParameter(name: name, encoded: value, depth: 0)
        result["sdkParameter"] = raw
        if raw["inlineClass"]?.string == "androidx.compose.ui.unit.Dp", let scalar = value["value"], scalar.double?.isFinite == true {
            result["value"] = .object(["value": scalar, "unit": .string("DP")])
        } else if raw["inlineClass"]?.string == "androidx.compose.ui.unit.TextUnit", let signed = value["value"]?.int64 {
            let bits = UInt64(bitPattern: signed)
            let unit = (bits >> 32) & 0xFF
            let size = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            if [UInt64(1), UInt64(2)].contains(unit), size.isFinite {
                result["value"] = .object(["value": .number(String(size)), "unit": .string(unit == 1 ? "sp" : "em")])
            } else {
                result["value"] = .string("Unspecified")
            }
        } else if raw["inlineClass"]?.string == "androidx.compose.ui.graphics.Color", let signed = value["value"]?.int64 {
            let bits = UInt64(bitPattern: signed)
            // sRGB Color packs ARGB in the high 32 bits. Other color spaces need a dedicated decoder.
            if bits & 0xFFFFFFFF == 0 { result["value"] = .string(String(format: "#%08X", UInt32(bits >> 32))) }
        }
        return .object(result)
    }

    private static func valueParameter(name: String, encoded: InspectorJSON, depth: Int) throws -> [String: InspectorJSON] {
        guard depth < 16 else { throw SnapshotImportError.schema("SDK 参数嵌套超出限制") }
        let type = encoded["type"]?.string ?? "未知类型"
        var result: [String: InspectorJSON] = ["name": .string(name)]
        if let value = encoded["value"] {
            result["value"] = value
        } else if let count = encoded["viewport"]?["count"]?.int64 {
            result["value"] = .string("\(type.components(separatedBy: ".").last ?? type) · 可见条目 \(count)")
        } else if let items = encoded["items"]?.array {
            result["value"] = .string("List[\(encoded["size"]?.int64 ?? Int64(items.count))]")
            result["isCollection"] = .bool(true)
            result["elements"] = .array(try items.enumerated().map { .object(try valueParameter(name: "[\($0.offset)]", encoded: $0.element, depth: depth + 1)) })
        } else if let fields = encoded["fields"]?.array {
            result["value"] = .string(type.components(separatedBy: ".").last ?? type)
            result["elements"] = .array(try fields.map { field in
                guard let name = field["name"]?.string, let value = field["value"] else { throw SnapshotImportError.schema("SDK 对象字段不完整") }
                return .object(try valueParameter(name: name, encoded: value, depth: depth + 1))
            })
        } else if let entries = encoded["entries"]?.array {
            result["value"] = .string("Map[\(encoded["size"]?.int64 ?? Int64(entries.count))]")
            result["isCollection"] = .bool(true)
            result["elements"] = .array(try entries.enumerated().map { index, entry in
                guard let key = entry["key"], let value = entry["value"] else { throw SnapshotImportError.schema("SDK Map 字段不完整") }
                return .object(["name": .string("[\(index)]"), "elements": .array([
                    .object(try valueParameter(name: "key", encoded: key, depth: depth + 1)),
                    .object(try valueParameter(name: "value", encoded: value, depth: depth + 1))
                ])])
            })
        } else {
            result["value"] = .string("\(type)（未展开）")
        }
        if encoded["truncated"]?.boolean == true || encoded["opaque"]?.boolean == true {
            result["isTruncated"] = .bool(true)
        }
        return result
    }

    private static func bounds(_ rect: CGRect) -> InspectorJSON {
        .object(["x": .number(String(Double(rect.minX))), "y": .number(String(Double(rect.minY))),
                 "width": .number(String(Double(rect.width))), "height": .number(String(Double(rect.height)))])
    }
    private static func rect(_ value: InspectorJSON?) -> CGRect {
        CGRect(x: value?["x"]?.double ?? 0, y: value?["y"]?.double ?? 0,
               width: value?["width"]?.double ?? 0, height: value?["height"]?.double ?? 0)
    }
    private static func orderedChildren(_ branches: [[InspectorJSON]]) -> [InspectorJSON] {
        guard branches.count > 1 else { return branches.first ?? [] }
        let groups = Dictionary(grouping: branches) { branch in
            branch.flatMap { node in
                [node["className"]?.string ?? "", node["sourceLocation"]?.jsonString() ?? "",
                 node["bounds"]?.jsonString() ?? ""]
            }
        }
        var children: [InspectorJSON] = []
        for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let tied = groups[key]!
            if tied.count == 1 {
                children.append(contentsOf: tied[0])
                continue
            }
            // Same-sized hosts can wrap different calls. Ignore IDs assigned in enumeration order.
            let ranked = tied.map { (branch: $0, key: subtreeKey($0)) }
            for entry in ranked.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                children.append(contentsOf: entry.branch)
            }
        }
        return children
    }

    private static func subtreeKey(_ roots: [InspectorJSON]) -> [String] {
        var pending = Array(roots.reversed())
        var key: [String] = []
        while let node = pending.popLast() {
            let children = node["children"]?.array ?? []
            let labelParameters = (node["parameters"]?.array ?? []).filter {
                ["text", "contentdescription"].contains($0["name"]?.string?.lowercased() ?? "")
            }
            key.append(contentsOf: [node["className"]?.string ?? "", node["bounds"]?.jsonString() ?? "",
                                    node["sourceLocation"]?.jsonString() ?? "", String(children.count),
                                    InspectorJSON.array(labelParameters).jsonString()])
            pending.append(contentsOf: children.reversed())
        }
        return key
    }
}
