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
