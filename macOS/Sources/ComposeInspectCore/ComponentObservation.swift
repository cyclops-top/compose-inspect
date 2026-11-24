import Foundation

extension InspectorNode {
    public var observableFields: [NodeParameter] {
        parameters.filter { field in
            guard !field.isTruncated, let raw = field.original else { return false }
            switch field.group {
            case .parameter:
                // Only named top-level scalar arguments, never flattened business-object members.
                guard let value = raw["sdkParameter"]?["value"]?["value"] else { return false }
                if let object = value.object {
                    return object.count == 2 && value["value"]?.double?.isFinite == true
                        && ["dp", "px", "sp", "em"].contains(value["unit"]?.string?.lowercased() ?? "")
                }
                return value.array == nil
            case .semantics, .unmergedSemantics, .mergedSemantics:
                guard let value = raw["value"] else { return false }
                return value.array == nil && value.object == nil
            default:
                return false
            }
        }
    }
}

public struct ComponentObservation {
    public struct Reading {
        public let time: Date
        public let value: String
        public let snapshotID: UUID
        public let nodeID: String
        fileprivate let raw: InspectorJSON?
    }
    public let component: String
    public let field: String
    public let group: NodeParameter.Group
    public private(set) var previous: Reading?
    public private(set) var latest: Reading
    public private(set) var detail = "已记录初值"
    public private(set) var interrupted = false

    public init(node: InspectorNode, field: NodeParameter, snapshot: InspectorSnapshot) {
        component = node.shortName
        self.field = field.name
        group = field.group
        latest = Self.read(node, field, snapshot)
    }

    private static func read(_ node: InspectorNode, _ field: NodeParameter, _ snapshot: InspectorSnapshot) -> Reading {
        Reading(time: snapshot.capturedAt, value: field.original?["value"] == .null ? "null" : field.value,
                snapshotID: snapshot.id, nodeID: node.id,
                raw: field.original?["sdkParameter"]?["value"] ?? field.original?["value"])
    }

    public mutating func interrupt(_ reason: String) {
        guard !interrupted else { return }
        interrupted = true
        detail = "观测中断 · " + reason
    }

    public mutating func advance(from before: InspectorSnapshot, index old: InspectorSnapshotIndex,
                                 to after: InspectorSnapshot, index new: InspectorSnapshotIndex) -> String? {
        guard !interrupted else { return nil }
        guard before.id == latest.snapshotID, let serial = before.captureMetadata?.serial, !serial.isEmpty,
              after.captureMetadata?.serial == serial, before.packageName == after.packageName,
              let a = before.document?.root, let b = after.document?.root,
              [a, b].allSatisfy({ $0["captureBackend"]?.string == "sdk" &&
                  $0["sdkCapture"]?["sdkVersion"]?.string == SDKInspectorClient.supportedSDKVersion }),
              let pid = a["sdkCapture"]?["pid"]?.int64, pid == b["sdkCapture"]?["pid"]?.int64 else {
            interrupt("设备、进程或采集来源变化"); return nil
        }
        let path = old.path(to: latest.nodeID)
        guard let root = path.first, let target = path.last, target.source?.line != nil,
              old.roots.filter({ $0.name == root.name }).count == 1,
              new.roots.filter({ $0.name == root.name }).count == 1,
              let nextRoot = new.roots.first(where: { $0.name == root.name }) else {
            interrupt("窗口或调用位置无法唯一定位"); return nil
        }
        guard !path.contains(where: { $0.shortName.hasPrefix("Lazy") || $0.source?.file.hasPrefix("Lazy") == true || $0.shortName == "ReusableContent" }) else {
            interrupt("列表或复用范围内缺少稳定实例标识"); return nil
        }
        func candidates(_ index: InspectorSnapshotIndex, root: InspectorNode) -> [InspectorNode] {
            (index.nodesByRoot[root.id] ?? []).filter { node in
                guard node.name == target.name, node.source == target.source else { return false }
                let other = index.path(to: node.id)
                return other.count == path.count && zip(other, path).allSatisfy {
                    $0.name == $1.name && $0.kind == $1.kind && $0.source == $1.source
                }
            }
        }
        let matches = candidates(new, root: nextRoot)
        guard matches.count == 1, candidates(old, root: root).count == 1 else {
            interrupt(matches.isEmpty ? "组件离开或调用路径改变" : "同一调用路径存在多个实例"); return nil
        }
        let node = matches[0]
        if let identity = target.clickTargetID, node.clickTargetID != identity {
            interrupt("关联布局实例变化"); return nil
        }
        let fields = node.observableFields.filter { $0.group == group && $0.name == field }
        guard fields.count == 1, target.observableFields.filter({ $0.group == group && $0.name == field }).count == 1 else {
            interrupt("字段缺失、截断或重名"); return nil
        }
        previous = latest
        latest = Self.read(node, fields[0], after)
        let outcome = previous?.raw == latest.raw ? "读数相同" : "读数变化"
        detail = "\(outcome) · 候选配对，需复核（同窗口、调用点与父链双向唯一）"
        return node.id
    }
}
