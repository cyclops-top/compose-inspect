import Foundation
import CoreGraphics

public struct NodeParameter: Identifiable, Codable, Equatable, Sendable {
    public enum Group: String, Codable, CaseIterable, Sendable {
        case layout = "尺寸", font = "字体"
        case modifier = "修饰符", parameter = "组件参数", semantics = "语义", attribute = "View 属性"
        case unmergedSemantics = "原始语义"
        case mergedSemantics = "合并语义" // Decodes previously exported Codable snapshots.
    }
    public let id: String
    public let name: String
    public let value: String
    public let group: Group
    public let isTruncated: Bool
    public let original: InspectorJSON?

    public init(id: String, name: String, value: String, group: Group, isTruncated: Bool = false,
                original: InspectorJSON? = nil) {
        self.id = id; self.name = name; self.value = value; self.group = group; self.isTruncated = isTruncated
        self.original = original
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
        guard !isTruncated else { return true }
        guard let original else { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Self.hasContent(original)
    }
    private static func hasContent(_ raw: InspectorJSON) -> Bool {
        if raw["isTruncated"]?.boolean == true { return true }
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
    public let packageHash: Int32?
    public init(file: String, line: Int? = nil, packageHash: Int32? = nil) {
        self.file = file
        self.line = line
        self.packageHash = packageHash
    }
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
    public let clickTargetID: String?
    public let style: ComponentStyle?

    public init(id: String, rawID: Int64, name: String, kind: String = "ComposeNode", label: String? = nil,
                bounds: CGRect, source: SourceAnchor? = nil, parameters: [NodeParameter] = [], children: [InspectorNode] = [],
                style: ComponentStyle? = nil, clickTargetID: String? = nil) {
        self.id = id; self.rawID = rawID; self.name = name; self.kind = kind; self.label = label
        self.bounds = bounds; self.source = source; self.parameters = parameters; self.children = children
        self.style = style
        self.clickTargetID = clickTargetID
    }
    fileprivate func withChildren(_ children: [InspectorNode]) -> InspectorNode {
        InspectorNode(id: id, rawID: rawID, name: name, kind: kind, label: label,
                                  bounds: bounds, source: source, parameters: parameters, children: children,
                                  style: style, clickTargetID: clickTargetID)
    }

    /// These composition-only wrappers have no independently measured layout box.
    public static func isVirtualLayoutGroup(name: String, source: SourceAnchor?) -> Bool {
        let shortName = name.components(separatedBy: ".").last ?? name
        if ["CompositionLocalProvider", "SkippableItem", "SaveableStateProvider", "ReusableContent",
            "ReusableContentHost", "LazyLayoutPinnableItem", "ProvideCommonCompositionLocals",
            "ProvideTextStyle", "ProvideContentColorTextStyle"].contains(shortName) { return true }
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
        guard kind == "ComposeNode" else { return false }
        let semantics = parameters.filter { $0.group == .unmergedSemantics }
        if semantics.contains(where: { $0.name == "Disabled" && $0.value != "false" && $0.value != "null" }) { return false }
        return semantics.contains { $0.name == "OnClick" && $0.value != "null" && $0.value != "false" }
    }
    public var displayName: String { label.map { "\(shortName)「\($0)」" } ?? shortName }
    public var flattened: [InspectorNode] {
        var result: [InspectorNode] = [], pending = [self]
        while let node = pending.popLast() {
            result.append(node)
            pending.append(contentsOf: node.children.reversed())
        }
        return result
    }
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

    public init(id: UUID = UUID(), capturedAt: Date = Date(), packageName: String, deviceName: String,
                pixelSize: CGSize, roots: [InspectorNode], isDemo: Bool = false,
                document: InspectorDocument? = nil, captureMetadata: CaptureMetadata? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.packageName = packageName; self.deviceName = deviceName
        self.pixelSize = pixelSize; self.roots = roots; self.isDemo = isDemo
        self.document = document; self.captureMetadata = captureMetadata
    }
    /// Attach capture diagnostics without parsing the original document or rebuilding its tree.
    public func withCaptureContext(deviceName: String, metadata: CaptureMetadata) -> InspectorSnapshot {
        InspectorSnapshot(id: id, capturedAt: capturedAt, packageName: packageName,
                                       deviceName: deviceName, pixelSize: pixelSize, roots: roots,
                                       isDemo: isDemo, document: document, captureMetadata: metadata)
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
        self.init(snapshot, hidingInternals: hidingInternals, onlyClickable: onlyClickable,
                  configuration: configuration, checkpoint: {})
    }

    public init(_ snapshot: InspectorSnapshot, hidingInternals: Bool = false, onlyClickable: Bool = false,
                configuration: NodeFilterConfiguration = .defaults, checkpoint: () throws -> Void) rethrows {
        try checkpoint()
        let presentedRoots = hidingInternals || onlyClickable
            ? try ComposeNodeFilter.roots(snapshot.roots, onlyClickable: onlyClickable,
                                          configuration: configuration, checkpoint: checkpoint) : snapshot.roots
        try self.init(presentedRoots: presentedRoots, checkpoint: checkpoint)
    }

    private init(presentedRoots: [InspectorNode], checkpoint: () throws -> Void) rethrows {
        var nodes: [InspectorNode] = [], byID: [String: InspectorNode] = [:]
        var parents: [String: String] = [:], roots: [String: String] = [:]
        var depths: [String: Int] = [:]
        var grouped: [String: [InspectorNode]] = [:], bounds: [String: [CGRect]] = [:]
        var seenBounds: [String: Set<[CGFloat]>] = [:]
        var pending = presentedRoots.reversed().map { (node: $0, parent: Optional<String>.none, root: $0.id, depth: 0) }
        while let (node, parent, root, depth) = pending.popLast() {
            try checkpoint()
            nodes.append(node); byID[node.id] = node; parents[node.id] = parent; roots[node.id] = root
            depths[node.id] = depth
            grouped[root, default: []].append(node)
            let rect = node.bounds.standardized
            if !rect.isEmpty,
               seenBounds[root, default: []].insert([rect.minX, rect.minY, rect.width, rect.height]).inserted {
                bounds[root, default: []].append(rect)
            }
            pending.append(contentsOf: node.children.reversed().map { ($0, node.id, root, depth + 1) })
        }
        self.roots = presentedRoots
        self.nodes = nodes; self.byID = byID; parentIDs = parents; rootIDs = roots
        self.depths = depths
        nodesByRoot = grouped; boundsByRoot = bounds
    }

    /// Keep window roots and promote matching descendants through omitted parents.
    public func filteringNodes(_ includes: (InspectorNode) -> Bool) -> InspectorSnapshotIndex {
        var projected: [String: [InspectorNode]] = [:]
        for node in nodes.reversed() {
            let children = node.children.flatMap { projected.removeValue(forKey: $0.id) ?? [] }
            projected[node.id] = parentIDs[node.id] == nil || includes(node) ? [node.withChildren(children)] : children
        }
        return InspectorSnapshotIndex(presentedRoots: roots.flatMap { projected[$0.id] ?? [] }, checkpoint: {})
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
        self.roots(roots, onlyClickable: onlyClickable, configuration: configuration, checkpoint: {})
    }

    public static func roots(_ roots: [InspectorNode], onlyClickable: Bool = false,
                             configuration: NodeFilterConfiguration = .defaults,
                             checkpoint: () throws -> Void) rethrows -> [InspectorNode] {
        // Identity comes from the captured layout, never from names or equal rectangles.
        var preferred: [String: String] = [:]
        if onlyClickable {
            let frameworkFiles: Set<String> = ["Surface.kt", "Box.kt", "Row.kt", "Column.kt", "Layout.kt",
                "Button.kt", "Text.kt", "BasicText.kt", "Clickable.kt", "Composables.kt", "SubcomposeLayout.kt"]
            var scores: [String: Int] = [:]
            var candidates = Array(try self.roots(roots, onlyClickable: false, configuration: configuration, checkpoint: checkpoint).reversed())
            while let node = candidates.popLast() {
                try checkpoint()
                if node.isClickable, let target = node.clickTargetID {
                    let file = node.source?.file.components(separatedBy: "/").last
                    let score = file.map { frameworkFiles.contains($0) ? 1 : 2 } ?? 0
                    if preferred[target] == nil || score > (scores[target] ?? -1) {
                        preferred[target] = node.id
                        scores[target] = score
                    }
                }
                candidates.append(contentsOf: node.children.reversed())
            }
        }
        var pending = roots.reversed().map { (node: $0, insideText: false, isRoot: true, ready: false) }
        var transitionScaffolding = Set<String>()
        var projected: [String: [InspectorNode]] = [:]
        while let (node, insideText, isRoot, ready) = pending.popLast() {
            try checkpoint()
            if !ready {
                if configuration.hideCompositionWrappers && node.kind == "ComposeNode" {
                    if node.children.contains(where: { $0.shortName == "SharedTransitionLayout" }) {
                        transitionScaffolding.insert(node.id)
                    }
                    if transitionScaffolding.contains(node.id) {
                        for child in node.children where child.kind == "ComposeNode" && transitionImplementation.contains(child.shortName) {
                            transitionScaffolding.insert(child.id)
                        }
                    }
                }
                pending.append((node, insideText, isRoot, true))
                let childInsideText = insideText || (node.kind == "ComposeNode" && node.shortName == "Text")
                pending.append(contentsOf: node.children.reversed().map { ($0, childInsideText, false, false) })
                continue
            }
            let name = node.shortName
            let compose = node.kind == "ComposeNode"
            let file = node.source?.file.components(separatedBy: "/").last
            let textImplementation = configuration.hideTextImplementation && compose && insideText && name == "BasicText" && (file == nil || file == "Text.kt")
            let layoutImplementation = configuration.hideLayoutImplementation && compose && (
                (name == "ReusableComposeNode" && (file == nil || file == "Layout.kt" || file == "SubcomposeLayout.kt" || file == "Composables.kt" || file == "LookaheadScope.kt"))
                || (name == "Layout" && file.map { layoutCallSites.contains($0) } == true))
            let children = node.children.flatMap { projected.removeValue(forKey: $0.id) ?? [] }
            // Known composition wrappers have no independent layout. Keep any identity or
            // semantics attached to them, but don't retain bookkeeping parameters as UI rows.
            let meaningfulIdentity = node.label?.isEmpty == false
                || node.parameters.contains {
                    [.semantics, .mergedSemantics, .unmergedSemantics, .attribute].contains($0.group)
                        && !["false", "null", ""].contains($0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                || node.style?.layers.isEmpty == false
            // Once projected, an idle transition host forwards its sole measured slot.
            // Retain the stacking boundary when a preview adds another visible child.
            let hasOneSlot = configuration.hideCompositionWrappers && compose && node.parameters.lazy.filter { parameter in
                guard parameter.group == .parameter, let sdk = parameter.original?["sdkParameter"] else { return false }
                if let flag = sdk["forwardsContent"]?.boolean { return flag }
                return sdk["value"]?["type"]?.string == "androidx.compose.runtime.internal.ComposableLambdaImpl"
            }.prefix(2).count == 1
            let hasModifier = node.parameters.contains { $0.group == .modifier && $0.original?["sdkParameter"]?["fromDefault"]?.boolean != true }
            let contentWrapper = ((hasOneSlot && !hasModifier) || transitionScaffolding.contains(node.id)) && !meaningfulIdentity && !node.isClickable && {
                let measured = children.lazy.filter { !$0.bounds.isEmpty }.prefix(2)
                return (measured.isEmpty && transitionScaffolding.contains(node.id)) ||
                    (measured.count == 1 && measured.first?.bounds == node.bounds)
            }()
            let compositionWrapper = configuration.hideCompositionWrappers && compose && (
                nonVisualCall(name, file: file)
                    || (node.isVirtualLayoutGroup && (name != "Item" || !meaningfulIdentity)))
            let composeHost = configuration.hideComposeHosts && node.kind == "ViewNode"
                && (name.hasSuffix("AndroidComposeView") || name == "ComposeHost")
            if !isRoot && (textImplementation || layoutImplementation || compositionWrapper || contentWrapper || composeHost
                || (onlyClickable && (!node.isClickable || node.clickTargetID.map { preferred[$0] != node.id } == true))) {
                projected[node.id] = children
                continue
            }
            projected[node.id] = [node.withChildren(children)]
        }
        return roots.flatMap { projected.removeValue(forKey: $0.id) ?? [] }
    }
    private static let transitionImplementation: Set<String> = [
        "SharedTransitionLayout", "SharedTransitionScope", "LookaheadScope", "Box",
        "Layout", "ReusableComposeNode", "CompositionLocalProvider"
    ]
    private static let layoutCallSites: Set<String> = [
        "Layout.kt", "Text.kt", "BasicText.kt", "Box.kt", "Row.kt", "Column.kt", "Spacer.kt",
        "SubcomposeLayout.kt", "Icon.kt", "Image.kt", "FlowLayout.kt"
    ]

    // Tooling does not expose return types. Only known non-UI calls are classified here;
    // a lowercase name or a Color suffix alone is not evidence that a call returns a value.
    private static func nonVisualCall(_ name: String, file: String?) -> Bool {
        if nonVisualCalls.contains(name) { return true }
        if name == "remember" || (name.hasPrefix("remember") && name.dropFirst(8).first?.isUppercase == true) { return true }
        if name.hasPrefix("animate") && name.hasSuffix("AsState") { return true }
        if name.hasPrefix("<get-") && name.hasSuffix(">") { return true }
        switch (name, file) {
        case ("LazySaveableStateHolderProvider", "LazyLayout.kt"), ("collectInto", "SnapshotFlow.kt"), ("resourceCardColor", "ResourceFolderSelectorCard.kt"),
             ("masteryColor", "ResourceMastery.kt"), ("masteryLabel", "ResourceMastery.kt"):
            return true
        default: return false
        }
    }

    private static let nonVisualCalls: Set<String> = [
        "SideEffect", "DisposableEffect", "LaunchedEffect", "produceState", "derivedStateOf",
        "LifecycleStartEffect", "LifecycleStartEffectImpl", "LifecycleResumeEffect", "LifecycleResumeEffectImpl",
        "LifecycleEventEffect", "BackHandler", "PredictiveBackHandler", "BackgroundTextMeasurement",
        "collectAsState", "collectAsStateWithLifecycle", "collectIsPressedAsState", "collectIsFocusedAsState",
        "collectIsHoveredAsState", "collectIsDraggedAsState", "currentStateAsState", "collectAsLazyPagingItems",
        "viewModel", "hiltViewModel", "stringResource", "pluralStringResource", "stringArrayResource",
        "painterResource", "imageResource", "vectorResource", "colorResource", "dimensionResource",
        "integerResource", "booleanResource", "buttonColors", "buttonElevation", "iconButtonColors",
        "rowMeasurePolicy", "columnMeasurePolicy", "rowMeasurementMultiContentHelper",
        "surfaceColorAtElevation", "applyTonalElevation", "loadVectorResource"
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
    public struct SourceLocation {
        public let anchor: SourceAnchor
        public let ownerName: String
        public let inherited: Bool
        public let inProject: Bool

        public var summary: String {
            if inProject { return (inherited ? "父组件调用处 · " : "工程内调用处 · ") + anchor.text }
            if inherited { return "祖先定位线索：\(anchor.text) · \(ownerName)（非当前组件位置）" }
            return "自身采集位置：" + anchor.text + (anchor.line == nil ? "（行号未知）" : "")
        }
    }

    /// A reported callsite is a search anchor, never a verified declaration.
    public static func usableSource(_ source: SourceAnchor?) -> SourceAnchor? {
        guard let source else { return nil }
        let file = source.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return nil }
        return SourceAnchor(file: file, line: source.line.flatMap { $0 > 0 ? $0 : nil }, packageHash: source.packageHash)
    }

    public static func sourceLocation(in path: [InspectorNode], projectFile: (SourceAnchor) -> String? = { _ in nil }) -> SourceLocation? {
        var nearest: SourceLocation?
        for owner in path.reversed() {
            guard let source = usableSource(owner.source) else { continue }
            let inherited = owner.id != path.last?.id
            if let file = projectFile(source) {
                let anchor = SourceAnchor(file: file, line: source.line, packageHash: source.packageHash)
                return SourceLocation(anchor: anchor, ownerName: owner.shortName, inherited: inherited, inProject: true)
            }
            if nearest == nil {
                nearest = SourceLocation(anchor: source, ownerName: owner.shortName, inherited: inherited, inProject: false)
            }
        }
        return nearest
    }

    public static func sourceSummary(for nodeID: String, index: InspectorSnapshotIndex) -> String {
        guard index.byID[nodeID] != nil else { return "未找到组件" }
        return sourceLocation(in: index.path(to: nodeID))?.summary ?? "无源码位置：请按组件名或文字搜索"
    }

    public static func text(for issue: ComponentIssue, in snapshot: InspectorSnapshot,
                            index suppliedIndex: InspectorSnapshotIndex? = nil,
                            projectFile: (SourceAnchor) -> String? = { _ in nil }) -> String? {
        let index = suppliedIndex ?? InspectorSnapshotIndex(snapshot)
        guard issue.component.snapshotID == snapshot.id, let node = index.byID[issue.component.nodeID] else { return nil }
        let path = index.path(to: node.id)
        let source = sourceLocation(in: path, projectFile: projectFile)
        let location: String
        if let source {
            location = source.inherited ? "位于 \(source.anchor.text) 的 \(source.ownerName) 内" : source.anchor.text
        } else { location = path.map(\.shortName).joined(separator: " > ") }
        // A source callsite can have multiple runtime instances. Keep the shortest useful ancestor label.
        let capturedSource = usableSource(node.source)
        let hasDuplicate = index.nodes.contains { $0.id != node.id && usableSource($0.source) == capturedSource && $0.displayName == node.displayName }
        let context = hasDuplicate ? path.dropLast().reversed().first(where: { $0.label != nil })?.displayName : nil
        let target = context.map { "\($0) > \(node.displayName)" } ?? node.displayName
        let parameters = node.selectableParameters.filter { issue.parameterIDs.contains($0.id) }.map {
            "\($0.name)=\($0.value)\($0.isTruncated ? "（截断值）" : "")"
        }
        let ancestors = path.dropLast().filter { ancestor in
            ancestor.kind == "ComposeNode" && usableSource(ancestor.source) != nil && !contextWrappers.contains(ancestor.shortName)
        }
        // Keep the nearest screen and the business components below it. sourceLocation is a
        // reported callsite, not a verified function declaration or a JVM/Kotlin stack frame.
        let screen = ancestors.lastIndex { $0.shortName.hasSuffix("Screen") }
        let contextual = screen.map { Array(ancestors[$0...]) } ?? Array(ancestors.suffix(3))
        let route = contextual.map { "\(usableSource($0.source)!.text) (\($0.displayName))" }
            + ["\(location) (\(target))"]
        let hasRequest = !issue.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let locator = ["## 组件路径", "已省略包装组件，末项为目标。", "", codeBlock(route.enumerated().map { $0.offset == 0 ? $0.element : "  → " + $0.element }.joined(separator: "\n"))]
        var clues = ["", "注：文件和行号为运行时采集的调用位置线索，请结合当前源码确认。"]
        if let source, source.inProject {
            clues.append("工程内调用处：\(source.anchor.text)" + (source.inherited ? "（父组件 \(source.ownerName)）" : ""))
            clues.append("组件自身采集位置：" + (capturedSource?.text ?? "未提供"))
        } else if capturedSource?.line == nil {
            clues.append(source?.summary ?? "无源码位置：请按组件名或文字搜索")
        }
        let parameterSection = parameters.isEmpty ? [] : ["", "## 所选参数", codeBlock(parameters.joined(separator: "\n"))]
        return (locator + clues + parameterSection + (hasRequest ? ["", "## 修改要求", issue.description] : [])).joined(separator: "\n")
    }

    private static func codeBlock(_ text: String) -> String {
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    private static let contextWrappers: Set<String> = [
        "Layout", "ReusableComposeNode", "ReusableContent", "SubcomposeLayout", "Box", "BoxWithConstraints",
        "Row", "Column", "Spacer", "LazyColumn", "LazyRow", "LazyList", "LazyLayout", "Item", "SkippableItem",
        "LazySaveableStateHolderProvider", "SaveableStateProvider", "LazyLayoutPinnableItem",
        "MaterialTheme", "ProvideTextStyle", "CompositionLocalProvider", "Scaffold", "ScaffoldLayout", "Surface"
    ]

    public static func batch(_ issues: [ComponentIssue], snapshots: [UUID: InspectorSnapshot]) -> String? {
        var indexes: [UUID: InspectorSnapshotIndex] = [:]
        return batch(issues) { issue in
            guard let snapshot = snapshots[issue.component.snapshotID] else { return nil }
            if indexes[snapshot.id] == nil { indexes[snapshot.id] = InspectorSnapshotIndex(snapshot) }
            return text(for: issue, in: snapshot, index: indexes[snapshot.id])
        }
    }

    public static func batch(_ issues: [ComponentIssue], textForIssue: (ComponentIssue) -> String?) -> String? {
        var sections: [String] = []
        for (index, issue) in issues.enumerated() {
            guard let text = textForIssue(issue) else { return nil }
            sections.append("# 问题 \(index + 1)\n\n\(text)")
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
