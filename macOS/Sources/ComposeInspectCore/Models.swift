import Foundation
import CoreGraphics

public struct NodeParameter: Identifiable, Codable, Equatable, Sendable {
    public enum Group: String, Codable, CaseIterable, Sendable {
        case layout = "尺寸", font = "字体"
        case modifier = "修饰符", parameter = "组件参数", semantics = "语义", attribute = "View 属性"
        case mergedSemantics = "合并语义", unmergedSemantics = "原始语义"
    }
    public let id: String
    public let name: String
    public let value: String
    public let group: Group
    public let isTruncated: Bool
    public let original: InspectorJSON?
    public let continuationToken: String?

    public init(id: String, name: String, value: String, group: Group, isTruncated: Bool = false,
                original: InspectorJSON? = nil, continuationToken: String? = nil) {
        self.id = id; self.name = name; self.value = value; self.group = group; self.isTruncated = isTruncated
        self.original = original; self.continuationToken = continuationToken
    }

    /// Presentation grouping does not change parameter IDs, values or their raw namespace.
    public func presentationGroup(isText: Bool) -> Group {
        guard group == .parameter else { return group }
        let segments = name.split(separator: ".").map(String.init)
        if segments.contains(where: { Self.fontFields.contains($0) }) { return .font }
        if isText, name == "color" || name == "style" || name.hasPrefix("style.")
            || name == "textStyle" || name.hasPrefix("textStyle.") { return .font }
        return group
    }
    private static let fontFields: Set<String> = [
        "fontSize", "fontWeight", "fontStyle", "fontFamily", "fontSynthesis", "fontFeatureSettings",
        "fontVariationSettings", "letterSpacing", "lineHeight", "textDecoration", "textAlign",
        "textDirection", "textIndent", "textGeometricTransform", "baselineShift", "lineBreak",
        "hyphens", "localeList", "platformStyle", "autoSize"
    ]

    public var hasDisplayContent: Bool {
        guard !isTruncated, continuationToken == nil else { return true }
        guard let original else { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Self.hasContent(original)
    }
    private static func hasContent(_ raw: InspectorJSON) -> Bool {
        if raw["isTruncated"]?.boolean == true || raw["continuationToken"]?.string != nil { return true }
        // Empty collections, zero and false are meaningful values, not missing parameters.
        if raw["isCollection"]?.boolean == true { return true }
        if let value = raw["value"] {
            switch value {
            case .null: break
            case .string(let text): if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            default: return true
            }
        }
        return raw["elements"]?.array?.contains(where: hasContent) == true
    }
    /// Inspector colors use Android #AARRGGBB. Never guess that an integer is a color.
    public var colorARGB: String? {
        let text = (original?["value"]?.string ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        let hex = String(text.dropFirst())
        guard [6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return (hex.count == 6 ? "FF" + hex : hex).uppercased()
    }
}

public struct SourceAnchor: Codable, Equatable, Sendable {
    public let file: String
    public let line: Int?
    public init(file: String, line: Int? = nil) { self.file = file; self.line = line }
    public var text: String { line.map { "\(file):\($0)" } ?? file }
}

public struct InspectorNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let rawID: Int64
    public let name: String
    public let kind: String
    public let label: String?
    public let bounds: CGRect
    public let source: SourceAnchor?
    public let parameters: [NodeParameter]
    public let children: [InspectorNode]
    public let idResource: String?
    public let layoutResource: String?
    public let style: ComponentStyle?

    public init(id: String, rawID: Int64, name: String, kind: String = "ComposeNode", label: String? = nil,
                bounds: CGRect, source: SourceAnchor? = nil, parameters: [NodeParameter] = [], children: [InspectorNode] = [],
                idResource: String? = nil, layoutResource: String? = nil, style: ComponentStyle? = nil) {
        self.id = id; self.rawID = rawID; self.name = name; self.kind = kind; self.label = label
        self.bounds = bounds; self.source = source; self.parameters = parameters; self.children = children
        self.style = style
        self.idResource = idResource; self.layoutResource = layoutResource
    }
    /// These composition-only wrappers have no independently measured layout box.
    public static func isVirtualLayoutGroup(name: String, source: SourceAnchor?) -> Bool {
        guard let file = source?.file.components(separatedBy: "/").last else { return false }
        switch name.components(separatedBy: ".").last ?? name {
        case "Item", "SkippableItem": return file == "LazyLayoutItemContentFactory.kt"
        case "LazyLayoutPinnableItem": return file == "LazyListItemProvider.kt"
        case "SaveableStateProvider": return file == "LazyLayoutItemContentFactory.kt" || file == "LazySaveableStateHolder.kt"
        case "ReusableContent": return file == "SaveableStateHolder.kt"
        default: return false
        }
    }
    public var isVirtualLayoutGroup: Bool { kind == "ComposeNode" && Self.isVirtualLayoutGroup(name: name, source: source) }
    /// App measurements are selectable without overwriting parameters from the raw inspector.
    public var layoutParameters: [NodeParameter] {
        let density = style?.density
        func parameter(_ key: String, _ name: String, _ pixels: Double) -> NodeParameter {
            let value = pixels / (density ?? 1)
            let text = String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return NodeParameter(id: id + "/$layout/" + key, name: name,
                value: text + (density == nil ? "px" : "dp"), group: .layout)
        }
        var result = [parameter("outerWidth", isVirtualLayoutGroup ? "组合范围宽度" : "外框宽度", bounds.width),
                      parameter("outerHeight", isVirtualLayoutGroup ? "组合范围高度" : "外框高度", bounds.height)]
        if let style {
            result += [parameter("contentWidth", "内容区宽度", style.contentBounds.width),
                       parameter("contentHeight", "内容区高度", style.contentBounds.height)]
        }
        return result
    }
    public var selectableParameters: [NodeParameter] { layoutParameters + parameters }
    public var shortName: String { name.components(separatedBy: ".").last ?? name }
    /// Use interaction metadata, rather than component names or arbitrary callback parameters.
    public var isClickable: Bool {
        if kind == "ViewNode" {
            return parameters.contains {
                $0.group == .attribute && $0.name.split(separator: ":").last?.lowercased() == "clickable"
                    && ($0.original?["value"]?.boolean == true || $0.value.lowercased() == "true")
            }
        }
        guard kind == "ComposeNode" else { return false }
        let own = parameters.filter { $0.group == .unmergedSemantics }
        let semantics = own.isEmpty ? parameters.filter { $0.group == .mergedSemantics || $0.group == .semantics } : own
        return semantics.contains { $0.name == "OnClick" && $0.value != "null" && $0.value != "false" }
    }
    public var displayName: String { label.map { "\(shortName)「\($0)」" } ?? shortName }
    public var flattened: [InspectorNode] { [self] + children.flatMap(\.flattened) }
    public func path(to key: String) -> [InspectorNode]? {
        if id == key { return [self] }
        for child in children { if let path = child.path(to: key) { return [self] + path } }
        return nil
    }
    public func matches(_ query: String) -> Bool {
        displayName.localizedCaseInsensitiveContains(query) || (source?.text.localizedCaseInsensitiveContains(query) ?? false)
        || children.contains { $0.matches(query) }
    }
}

public struct InspectorSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let packageName: String
    public let deviceName: String
    public let pixelSize: CGSize
    public let roots: [InspectorNode]
    public let isDemo: Bool
    public let document: InspectorDocument?
    public let captureMetadata: CaptureMetadata?
    public var parameterReads: [ParameterRead]?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), packageName: String, deviceName: String,
                pixelSize: CGSize, roots: [InspectorNode], isDemo: Bool = false,
                document: InspectorDocument? = nil, captureMetadata: CaptureMetadata? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.packageName = packageName; self.deviceName = deviceName
        self.pixelSize = pixelSize; self.roots = roots; self.isDemo = isDemo
        self.document = document; self.captureMetadata = captureMetadata; self.parameterReads = nil
    }
    public var nodes: [InspectorNode] { roots.flatMap(\.flattened) }
    public func node(_ key: String) -> InspectorNode? { nodes.first { $0.id == key } }
    public func path(to key: String) -> [InspectorNode] { roots.compactMap { $0.path(to: key) }.first ?? [] }
}

/// Derived once per immutable tree. Raw JSON is deliberately excluded from interaction data.
public struct InspectorSnapshotIndex: Sendable {
    public let roots: [InspectorNode]
    public let nodes: [InspectorNode]
    public let byID: [String: InspectorNode]
    public let parentIDs: [String: String]
    public let depths: [String: Int]
    public let rootIDs: [String: String]
    public let nodesByRoot: [String: [InspectorNode]]
    public let boundsByRoot: [String: [CGRect]]

    public init(_ snapshot: InspectorSnapshot, hidingInternals: Bool = false, onlyClickable: Bool = false,
                configuration: NodeFilterConfiguration = .defaults) {
        let presentedRoots = hidingInternals || onlyClickable
            ? ComposeNodeFilter.roots(snapshot.roots, onlyClickable: onlyClickable, configuration: configuration) : snapshot.roots
        var nodes: [InspectorNode] = [], byID: [String: InspectorNode] = [:]
        var parents: [String: String] = [:], roots: [String: String] = [:]
        var depths: [String: Int] = [:]
        var grouped: [String: [InspectorNode]] = [:], bounds: [String: [CGRect]] = [:]
        var seenBounds: [String: Set<[CGFloat]>] = [:]
        func visit(_ node: InspectorNode, parent: String?, root: String) {
            nodes.append(node); byID[node.id] = node; parents[node.id] = parent; roots[node.id] = root
            depths[node.id] = parent.flatMap { depths[$0] }.map { $0 + 1 } ?? 0
            grouped[root, default: []].append(node)
            let rect = node.bounds.standardized
            if !rect.isEmpty,
               seenBounds[root, default: []].insert([rect.minX, rect.minY, rect.width, rect.height]).inserted {
                bounds[root, default: []].append(rect)
            }
            for child in node.children { visit(child, parent: node.id, root: root) }
        }
        for root in presentedRoots { visit(root, parent: nil, root: root.id) }
        self.roots = presentedRoots
        self.nodes = nodes; self.byID = byID; parentIDs = parents; rootIDs = roots
        self.depths = depths
        nodesByRoot = grouped; boundsByRoot = bounds
    }

    /// One postorder pass per search, rather than recursively rescanning every subtree per row.
    public func matchingIDs(_ query: String) -> Set<String> {
        guard !query.isEmpty else { return Set(byID.keys) }
        var matches: Set<String> = []
        for node in nodes.reversed() {
            if node.displayName.localizedCaseInsensitiveContains(query)
                || node.source?.text.localizedCaseInsensitiveContains(query) == true
                || node.children.contains(where: { matches.contains($0.id) }) {
                matches.insert(node.id)
            }
        }
        return matches
    }

    public func path(to id: String) -> [InspectorNode] {
        var path: [InspectorNode] = [], current: String? = id
        while let key = current, let node = byID[key] {
            path.append(node); current = parentIDs[key]
        }
        return path.reversed()
    }
}

/// Presentation only: remove known implementation wrappers and promote their children. Never
/// prune a subtree: slots, custom content and Android Views nested inside a primitive survive.
public enum ComposeNodeFilter {
    public static func roots(_ roots: [InspectorNode], onlyClickable: Bool = false,
                             configuration: NodeFilterConfiguration = .defaults) -> [InspectorNode] {
        func project(_ node: InspectorNode, insideText: Bool, isRoot: Bool = false) -> [InspectorNode] {
            let name = node.shortName
            let compose = node.kind == "ComposeNode"
            let file = node.source?.file.components(separatedBy: "/").last
            let textImplementation = configuration.hideTextImplementation && compose && insideText && name == "BasicText" && (file == nil || file == "Text.kt")
            let layoutImplementation = configuration.hideLayoutImplementation && compose && (
                (name == "ReusableComposeNode" && (file == nil || file == "Layout.kt" || file == "SubcomposeLayout.kt"))
                || (name == "Layout" && file.map { layoutCallSites.contains($0) } == true))
            let children = node.children.flatMap { project($0, insideText: insideText || (compose && name == "Text")) }
            // Known composition wrappers have no independent layout. Keep any identity or
            // semantics attached to them, but don't retain bookkeeping parameters as UI rows.
            let meaningfulIdentity = node.label?.isEmpty == false || node.idResource != nil || node.layoutResource != nil
                || node.parameters.contains { [.semantics, .mergedSemantics, .unmergedSemantics, .attribute].contains($0.group) }
                || node.style?.layers.isEmpty == false
            let compositionWrapper = configuration.hideCompositionWrappers && node.isVirtualLayoutGroup && !meaningfulIdentity
            let androidWrapper = configuration.viewRules.contains { $0.matches(node) }
            if !isRoot && (textImplementation || layoutImplementation || compositionWrapper || androidWrapper
                || (onlyClickable && !node.isClickable)) { return children }
            return [InspectorNode(id: node.id, rawID: node.rawID, name: node.name, kind: node.kind, label: node.label,
                                  bounds: node.bounds, source: node.source, parameters: node.parameters, children: children,
                                  idResource: node.idResource, layoutResource: node.layoutResource, style: node.style)]
        }
        return roots.flatMap { project($0, insideText: false, isRoot: true) }
    }
    private static let layoutCallSites: Set<String> = [
        "Layout.kt", "Text.kt", "BasicText.kt", "Box.kt", "Row.kt", "Column.kt", "Spacer.kt",
        "SubcomposeLayout.kt", "Icon.kt", "Image.kt"
    ]
}

public struct ComponentKey: Codable, Hashable, Sendable {
    public let snapshotID: UUID
    public let nodeID: String
    public init(snapshotID: UUID, nodeID: String) { self.snapshotID = snapshotID; self.nodeID = nodeID }
}

public struct ComponentIssue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let component: ComponentKey
    public var description: String
    public var parameterIDs: Set<String>
    public init(id: UUID = UUID(), component: ComponentKey, description: String, parameterIDs: Set<String>) {
        self.id = id; self.component = component; self.description = description; self.parameterIDs = parameterIDs
    }
    public var excerpt: String { description.split(whereSeparator: \.isNewline).first.map(String.init) ?? "" }
}

/// The only source of truth for recorded issues. Empty edits never become issues.
public struct IssueLedger: Codable, Sendable {
    public private(set) var issues: [ComponentIssue]
    public init(issues: [ComponentIssue] = []) { self.issues = issues }
    public func issue(for key: ComponentKey) -> ComponentIssue? { issues.first { $0.component == key } }
    public mutating func update(_ key: ComponentKey, description: String, parameterIDs: Set<String>) {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.removeAll { $0.component == key }
        } else if let index = issues.firstIndex(where: { $0.component == key }) {
            issues[index].description = description
            issues[index].parameterIDs = parameterIDs
        } else {
            issues.append(ComponentIssue(component: key, description: description, parameterIDs: parameterIDs))
        }
    }
}

public enum LocatorTextBuilder {
    public static func text(for issue: ComponentIssue, in snapshot: InspectorSnapshot) -> String? {
        guard issue.component.snapshotID == snapshot.id, let node = snapshot.node(issue.component.nodeID) else { return nil }
        let path = snapshot.path(to: node.id)
        let location: String
        if let source = node.source { location = source.text }
        else if let ancestor = path.dropLast().reversed().first(where: { $0.source != nil }), let source = ancestor.source {
            location = "位于 \(source.text) 的 \(ancestor.shortName) 内"
        } else { location = path.map(\.shortName).joined(separator: " > ") }
        // A source callsite can have multiple runtime instances. Keep the shortest useful ancestor label.
        let duplicates = snapshot.nodes.filter { $0.source == node.source && $0.displayName == node.displayName }
        let context = duplicates.count > 1 ? path.dropLast().reversed().first(where: { $0.label != nil })?.displayName : nil
        let target = context.map { "\($0) > \(node.displayName)" } ?? node.displayName
        let parameters = node.selectableParameters.filter { issue.parameterIDs.contains($0.id) }.map {
            "\($0.name)=\($0.value)\($0.isTruncated ? "（截断值）" : "")"
        }
        let ancestors = path.dropLast().filter { ancestor in
            ancestor.kind == "ComposeNode" && ancestor.source != nil && !contextWrappers.contains(ancestor.shortName)
        }
        // Keep the nearest screen and the business components below it. sourceLocation is a
        // reported callsite, not a verified function declaration or a JVM/Kotlin stack frame.
        let screen = ancestors.lastIndex { $0.shortName.hasSuffix("Screen") }
        let contextual = screen.map { Array(ancestors[$0...]) } ?? Array(ancestors.suffix(3))
        let route = contextual.map { "\($0.source!.text) · \($0.displayName)" }
            + ["\(location) · \(target)"]
        let locator = ["请按以下要求修改：", "组件路径（采集，省略包装）："]
            + route.enumerated().map { $0.offset == 0 ? $0.element : "  → " + $0.element }
        return (locator + parameters + ["修改要求：", issue.description]).joined(separator: "\n")
    }

    private static let contextWrappers: Set<String> = [
        "Layout", "ReusableComposeNode", "ReusableContent", "SubcomposeLayout", "Box", "BoxWithConstraints",
        "Row", "Column", "Spacer", "LazyColumn", "LazyRow", "LazyList", "LazyLayout", "Item", "SkippableItem",
        "LazySaveableStateHolderProvider", "SaveableStateProvider", "LazyLayoutPinnableItem",
        "MaterialTheme", "ProvideTextStyle", "CompositionLocalProvider", "Scaffold", "ScaffoldLayout", "Surface"
    ]

    public static func batch(_ issues: [ComponentIssue], snapshots: [UUID: InspectorSnapshot]) -> String? {
        var sections: [String] = []
        for (index, issue) in issues.enumerated() {
            guard let snapshot = snapshots[issue.component.snapshotID], let text = text(for: issue, in: snapshot) else { return nil }
            sections.append("\(index + 1). \(text)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}

public struct CoordinateMapper: Sendable {
    public let scale: CGFloat
    public let offset: CGPoint
    public init(imageSize: CGSize, canvasSize: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero) {
        let scale = min(canvasSize.width / max(imageSize.width, 1), canvasSize.height / max(imageSize.height, 1)) * zoom
        self.scale = scale
        self.offset = CGPoint(x: (canvasSize.width - imageSize.width * scale) / 2 + pan.width,
                              y: (canvasSize.height - imageSize.height * scale) / 2 + pan.height)
    }
    public func display(_ rect: CGRect) -> CGRect {
        CGRect(x: offset.x + rect.minX * scale, y: offset.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
    public func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / max(scale, 0.0001), y: (point.y - offset.y) / max(scale, 0.0001))
    }
    public func candidates(at point: CGPoint, in snapshot: InspectorSnapshot) -> [InspectorNode] {
        candidates(at: point, in: InspectorSnapshotIndex(snapshot), imageSize: snapshot.pixelSize)
    }
    public func candidates(at point: CGPoint, in index: InspectorSnapshotIndex, imageSize: CGSize, rootID: String? = nil) -> [InspectorNode] {
        let imagePoint = imagePoint(point)
        guard CGRect(origin: .zero, size: imageSize).contains(imagePoint) else { return [] }
        let nodes = rootID.flatMap { index.nodesByRoot[$0] } ?? index.nodes
        return nodes.enumerated().filter { !$0.element.bounds.isEmpty && $0.element.bounds.contains(imagePoint) }.sorted {
            let a = $0.element.bounds.width * $0.element.bounds.height
            let b = $1.element.bounds.width * $1.element.bounds.height
            if a != b { return a < b }
            let depthA = index.depths[$0.element.id] ?? 0, depthB = index.depths[$1.element.id] ?? 0
            if depthA != depthB { return depthA > depthB }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

/// Repeated hits on the same component stack cycle outward, then wrap back to the smallest.
public struct ImageHitCycle: Sendable {
    private var previous: [String] = []
    public init() {}
    public mutating func reset() { previous = [] }
    public mutating func next(in candidates: [String], selected: String?) -> String? {
        defer { previous = candidates }
        guard !candidates.isEmpty else { return nil }
        if candidates == previous, let selected, let index = candidates.firstIndex(of: selected) {
            return candidates[(index + 1) % candidates.count]
        }
        return candidates.first
    }
}

/// Reveal a tree row with minimal scrolling. Long labels keep their beginning visible rather
/// than chasing an unreachable trailing edge; a visible short row keeps the horizontal offset.
public enum TreeSelectionViewport {
    public static func origin(revealing target: CGRect, in viewport: CGRect, documentSize: CGSize,
                              leadingInset: CGFloat = 16, trailingInset: CGFloat = 8) -> CGPoint {
        var origin = viewport.origin
        let availableWidth = max(0, viewport.width - leadingInset - trailingInset)
        if target.width > availableWidth {
            if target.minX < viewport.minX + leadingInset || target.maxX > viewport.maxX - trailingInset {
                origin.x = target.minX - leadingInset
            }
        } else if target.minX < viewport.minX + leadingInset {
            origin.x = target.minX - leadingInset
        } else if target.maxX > viewport.maxX - trailingInset {
            origin.x = target.maxX + trailingInset - viewport.width
        }
        if target.minY < viewport.minY { origin.y = target.minY }
        else if target.maxY > viewport.maxY { origin.y = target.maxY - viewport.height }
        origin.x = min(max(0, origin.x), max(0, documentSize.width - viewport.width))
        origin.y = min(max(0, origin.y), max(0, documentSize.height - viewport.height))
        return origin
    }
}

/// Preserve explicit sidebar/bottom sizes; the designated flexible pane absorbs window resizing.
public enum SplitLayoutSizing {
    public static func restored(saved: [Double]?, preferred: [Double?], minimum: [Double], available: Double,
                                flexible: Int) -> [Double] {
        guard !minimum.isEmpty, minimum.count == preferred.count, minimum.indices.contains(flexible) else { return [] }
        let valid = saved.flatMap { values in
            values.count == minimum.count && values.allSatisfy { $0.isFinite && $0 > 0 } ? values : nil
        }
        var result = minimum.indices.map { max(minimum[$0], valid?[$0] ?? preferred[$0] ?? minimum[$0]) }
        var delta = available - result.reduce(0, +)
        if delta >= 0 { result[flexible] += delta; return result }
        let order = [flexible] + minimum.indices.filter { $0 != flexible }
        for index in order {
            let shrink = min(-delta, result[index] - minimum[index])
            result[index] -= shrink; delta += shrink
            if delta >= 0 { break }
        }
        return result
    }
}
