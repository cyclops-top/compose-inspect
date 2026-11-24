import Foundation

/// Coordinates are relative to the lazy layout's main axis, including its content padding.
public struct LazyViewport {
    public struct Item: Identifiable {
        public let id: Int
        public let key: String?
        public let offset: Int64
        public let size: Int64
        public let extent: String
        public let gridBounds: String?
    }
    public static let componentNames = ["LazyRow", "LazyColumn", "LazyVerticalGrid", "LazyHorizontalGrid"]
    public let axis: String
    public let start: Int64
    public let end: Int64
    public let count: Int
    public let items: [Item]

    public init?(node: InspectorNode) {
        guard Self.componentNames.contains(node.shortName),
              let field = node.parameters.first(where: { $0.group == .parameter && $0.name == "state" }),
              let raw = field.original?["sdkParameter"]?["value"]?["viewport"],
              let start = raw["start"]?.int64, let end = raw["end"]?.int64, end >= start,
              let axis = raw["axis"]?.string, ["Vertical", "Horizontal"].contains(axis),
              let count = raw["count"]?.int64.flatMap(Int.init(exactly:)),
              let rows = raw["items"]?.array, count >= rows.count else { return nil }
        self.axis = axis == "Vertical" ? "纵向" : "横向"
        self.start = start
        self.end = end
        self.count = count
        var items: [Item] = []
        for row in rows {
            guard let index = row["index"]?.int64.flatMap(Int.init(exactly:)), index >= 0,
                  let offset = row["offset"]?.int64, let size = row["size"]?.int64, size >= 0 else { return nil }
            let (edge, overflow) = offset.addingReportingOverflow(size)
            guard !overflow else { return nil }
            let extent: String
            if size == 0 || start == end || edge <= start || offset >= end { extent = "无面积相交" }
            else if offset >= start && edge <= end { extent = "完整相交" }
            else { extent = "部分相交" }
            var grid: String?
            if let x = row["x"]?.int64, let y = row["y"]?.int64,
               let w = row["width"]?.int64, let h = row["height"]?.int64 {
                grid = "(\(x), \(y)) · \(w) × \(h) px"
            }
            items.append(Item(id: index, key: row["key"]?.jsonString(), offset: offset, size: size,
                              extent: extent, gridBounds: grid))
        }
        guard Set(items.map(\.id)).count == items.count else { return nil }
        self.items = items
    }
}
