import AppKit
import ComposeInspectCore
import Observation

@MainActor @Observable
final class WorkspaceStore {
    private(set) var snapshot: InspectorSnapshot
    private var captureRevision = UUID()
    private var captureRequestID = UUID()

    private struct PreparedIndexes: Sendable {
        let full: InspectorSnapshotIndex
        let compact: InspectorSnapshotIndex
        let clickable: InspectorSnapshotIndex
        init(_ snapshot: InspectorSnapshot, configuration: NodeFilterConfiguration,
             fullIndex: InspectorSnapshotIndex? = nil, checkpoint: () throws -> Void) rethrows {
            full = try fullIndex ?? InspectorSnapshotIndex(snapshot, checkpoint: checkpoint)
            compact = try InspectorSnapshotIndex(snapshot, hidingInternals: true, configuration: configuration, checkpoint: checkpoint)
            clickable = try InspectorSnapshotIndex(snapshot, onlyClickable: true, configuration: configuration, checkpoint: checkpoint)
        }
    }

    private func installIndexes(_ indexes: PreparedIndexes) {
        snapshotIndex = indexes.full
        compactIndex = indexes.compact
        clickableIndex = indexes.clickable
        updatePresentationIndex()
    }
    private(set) var snapshotIndex: InspectorSnapshotIndex
    private(set) var presentationIndex: InspectorSnapshotIndex
    private var compactIndex: InspectorSnapshotIndex
    private var clickableIndex: InspectorSnapshotIndex
    private let filterDefaults: UserDefaults
    private(set) var presentationRevision: UInt = 0
    var filterConfiguration: NodeFilterConfiguration {
        didSet {
            guard oldValue != filterConfiguration else { return }
            if let data = try? JSONEncoder().encode(filterConfiguration) {
                filterDefaults.set(data, forKey: "tree.filterConfiguration.v1")
            }
            scheduleFilterIndexes()
        }
    }
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var filterWorker: Task<PreparedIndexes, Error>?
    @ObservationIgnored private var captureWorker: Task<PreparedIndexes, Error>?
    private var filterRevision = UUID()

    private func scheduleFilterIndexes() {
        filterTask?.cancel()
        filterWorker?.cancel()
        let revision = UUID()
        filterRevision = revision
        let source = snapshot, rules = filterConfiguration, full = snapshotIndex
        filterTask = Task { [weak self] in
            do {
                // Coalesce rapid edits before starting the expensive traversal.
                try await Task.sleep(for: .milliseconds(100))
                let worker = Task.detached(priority: .userInitiated) {
                    try PreparedIndexes(source, configuration: rules, fullIndex: full,
                                        checkpoint: { try Task.checkCancellation() })
                }
                self?.filterWorker = worker
                let indexes = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.filterRevision == revision, self.snapshot.id == source.id,
                      self.filterConfiguration == rules else { return }
                self.installIndexes(indexes)
                self.filterWorker = nil
            } catch is CancellationError {
                // New rules or a new capture superseded this result.
            } catch {
                if let self, self.filterRevision == revision { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func waitForFilterIndexes() async { await filterTask?.value }

    private func cancelFilterIndexes() {
        filterRevision = UUID()
        filterTask?.cancel(); filterWorker?.cancel()
        filterTask = nil; filterWorker = nil
    }

    func restoreDefaultFilters() { filterConfiguration = .defaults }
    var hideInternalNodes = UserDefaults.standard.object(forKey: "onlyClickableNodes") as? Bool == true
        || (UserDefaults.standard.object(forKey: "hideInternalNodes") as? Bool ?? true) {
        didSet {
            if onlyClickableNodes && !hideInternalNodes { hideInternalNodes = true }
            UserDefaults.standard.set(hideInternalNodes, forKey: "hideInternalNodes")
            updatePresentationIndex()
        }
    }
    var onlyClickableNodes = UserDefaults.standard.bool(forKey: "onlyClickableNodes") {
        didSet {
            UserDefaults.standard.set(onlyClickableNodes, forKey: "onlyClickableNodes")
            if onlyClickableNodes { hideInternalNodes = true }
            updatePresentationIndex()
        }
    }
    var onlySourceNodes: Bool {
        didSet {
            filterDefaults.set(onlySourceNodes, forKey: "onlySourceNodes")
            updatePresentationIndex()
        }
    }

    private func updatePresentationIndex() {
        presentationRevision &+= 1
        let base = searchesAllComponents ? snapshotIndex : onlyClickableNodes ? clickableIndex : (hideInternalNodes ? compactIndex : snapshotIndex)
        if onlySourceNodes && !searchesAllComponents {
            let local = usesProjectSources
            presentationIndex = base.filteringNodes { node in
                local ? projectSources.confirms(node.source) : LocatorTextBuilder.usableSource(node.source) != nil
            }
        } else {
            presentationIndex = base
        }
        updateSearchMatches()
        imageHitCycle.reset(); hitCandidates = []
        if let selected = selectedNodeID, presentationIndex.byID[selected] == nil { clearSelection() }
    }
    private(set) var ledger = IssueLedger()
    private var clearedIssues: (ledger: IssueLedger, parameters: [ComponentKey: Set<String>])?
    var canUndoClearIssues: Bool { clearedIssues != nil }
    private(set) var selectedNodeID: String?
    private(set) var selectionRevision: UInt = 0
    var expandedNodes: Set<String> = []
    var search = "" {
        didSet {
            if search.isEmpty && searchesAllComponents { searchesAllComponents = false }
            else { updateSearchMatches() }
        }
    }
    var searchesAllComponents = false {
        didSet { updatePresentationIndex() }
    }
    private(set) var searchMatches: Set<String>?
    private func updateSearchMatches() {
        searchMatches = search.isEmpty ? nil : presentationIndex.matchingIDs(search)
    }
    var showWireframes = UserDefaults.standard.object(forKey: "showWireframes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWireframes, forKey: "showWireframes") }
    }
    var pickingColor = false
    var selectionEnabled = true
    var zoom: CGFloat = 1
    var imagePan: CGSize = .zero
    func fitImage() { zoom = 1; imagePan = .zero }
    var hitCandidates: [String] = []
    var windowRootID: String? {
        didSet {
            guard oldValue != windowRootID else { return }
            imageHitCycle.reset()
            hitCandidates = []
            if let selectedNodeID, !isInVisibleWindow(selectedNodeID) { clearSelection() }
        }
    }
    @ObservationIgnored private var imageHitCycle = ImageHitCycle()
    var errorMessage: String?
    var notice = "等待获取界面"
    private(set) var image: NSImage?
    private var transientParameters: [ComponentKey: Set<String>] = [:]
    let deviceSession = DeviceSession()
    var rawPresentation: RawJSONPresentation?
    private(set) var issueEditRevision: UInt = 0

    init(filterDefaults: UserDefaults = .standard) {
        self.filterDefaults = filterDefaults
        onlySourceNodes = filterDefaults.bool(forKey: "onlySourceNodes")
        let configuration = filterDefaults.data(forKey: "tree.filterConfiguration.v1")
            .flatMap { try? JSONDecoder().decode(NodeFilterConfiguration.self, from: $0) } ?? .defaults
        filterConfiguration = configuration
        let initial = Self.emptySnapshot()
        snapshot = initial
        let full = InspectorSnapshotIndex(initial)
        let compact = InspectorSnapshotIndex(initial, hidingInternals: true, configuration: configuration)
        snapshotIndex = full
        compactIndex = compact
        let clickable = InspectorSnapshotIndex(initial, onlyClickable: true, configuration: configuration)
        clickableIndex = clickable
        presentationIndex = UserDefaults.standard.bool(forKey: "onlyClickableNodes") ? clickable
            : ((UserDefaults.standard.object(forKey: "hideInternalNodes") as? Bool ?? true) ? compact : full)
        projectSources.onCatalogChange = { [weak self] in
            guard let self, self.onlySourceNodes, !self.searchesAllComponents else { return }
            self.updatePresentationIndex()
        }
    }

    private static func emptySnapshot() -> InspectorSnapshot {
        InspectorSnapshot(packageName: "", deviceName: "", pixelSize: .zero, roots: [])
    }

    var highlightedNode: InspectorNode? {
        guard let id = selectedNodeID else { return nil }
        return presentationIndex.byID[id] ?? (currentIssue == nil ? nil : snapshotIndex.byID[id])
    }
    var selectedNode: InspectorNode? { selectedNodeID.flatMap { snapshotIndex.byID[$0] } }
    var selectedKey: ComponentKey? { selectedNodeID.map { ComponentKey(snapshotID: snapshot.id, nodeID: $0) } }
    var currentIssue: ComponentIssue? { selectedKey.flatMap { ledger.issue(for: $0) } }
    var description: String { currentIssue?.description ?? "" }
    var selectedParameters: Set<String> {
        guard let key = selectedKey else { return [] }
        return ledger.issue(for: key)?.parameterIDs ?? transientParameters[key]
            ?? Set((selectedNode?.selectableParameters ?? []).filter { $0.name == "item.key" }.map(\.id))
    }
    var canPickImage: Bool {
        image != nil
    }
    var visibleRoot: InspectorNode? { presentationIndex.roots.first { $0.id == windowRootID } ?? presentationIndex.roots.first }
    var visibleNodes: [InspectorNode] { visibleRoot.flatMap { presentationIndex.nodesByRoot[$0.id] } ?? [] }
    var visibleBounds: [CGRect] { visibleRoot.flatMap { presentationIndex.boundsByRoot[$0.id] } ?? [] }
    func isInVisibleWindow(_ nodeID: String) -> Bool { snapshotIndex.rootIDs[nodeID] == visibleRoot?.id }
    var issues: [ComponentIssue] { ledger.issues }
    var currentText: String {
        guard let key = selectedKey else { return "" }
        let target = ComponentIssue(component: key, description: description, parameterIDs: selectedParameters)
        return locatorText(for: target) ?? ""
    }
    let projectSources = ProjectSourceIndex()
    var usesProjectSources: Bool {
        !projectSources.project.isEmpty
    }
    private func projectFile(for source: SourceAnchor) -> String? {
        guard !projectSources.project.isEmpty else { return nil }
        return projectSources.uniqueFile(for: source)
    }
    private func locatorText(for issue: ComponentIssue) -> String? {
        LocatorTextBuilder.text(for: issue, in: snapshot, index: snapshotIndex, projectFile: projectFile)
    }
    func sourceLocation(for id: String) -> LocatorTextBuilder.SourceLocation? {
        LocatorTextBuilder.sourceLocation(in: snapshotIndex.path(to: id), projectFile: projectFile)
    }
    func sourceSummary(for id: String) -> String {
        sourceLocation(for: id)?.summary ?? "无源码位置：请按组件名或文字搜索"
    }
    var sourceSummary: String { selectedNodeID.map(sourceSummary(for:)) ?? "未选择组件" }
    var selectedParentID: String? { path.dropLast().last?.id }

    func selectHitCandidate(_ id: String) {
        guard hitCandidates.contains(id), presentationIndex.byID[id] != nil, isInVisibleWindow(id) else { return }
        let candidates = hitCandidates
        select(id)
        hitCandidates = candidates
    }

    func cycleHitCandidate(_ direction: Int) {
        guard !hitCandidates.isEmpty else { return }
        let current = selectedNodeID.flatMap { hitCandidates.firstIndex(of: $0) } ?? 0
        let next = (current + direction % hitCandidates.count + hitCandidates.count) % hitCandidates.count
        selectHitCandidate(hitCandidates[next])
    }
    var batchText: String? { LocatorTextBuilder.batch(issues, textForIssue: locatorText) }
    var path: [InspectorNode] { selectedNodeID.map { presentationIndex.path(to: $0) } ?? [] }

    func select(_ nodeID: String) {
        guard !isCapturing, presentationIndex.byID[nodeID] != nil else { return }
        selectNode(nodeID)
    }

    private func selectNode(_ nodeID: String) {
        imageHitCycle.reset()
        guard snapshotIndex.byID[nodeID] != nil else { return }
        hitCandidates = []
        if !search.isEmpty, let visible = presentationIndex.byID[nodeID], !visible.matches(search) { search = "" }
        selectionRevision &+= 1
        guard selectedNodeID != nodeID || !isInVisibleWindow(nodeID) else { return }
        // Commit IME text to the old component, then retire its editor before switching.
        NSApp.keyWindow?.makeFirstResponder(nil)
        issueEditRevision &+= 1
        selectedNodeID = nodeID
        windowRootID = snapshotIndex.rootIDs[nodeID]
        for node in presentationIndex.path(to: nodeID).dropLast() { expandedNodes.insert(node.id) }
    }

    func handleEscape() {
        if pickingColor {
            pickingColor = false
        } else {
            clearSelection()
        }
    }

    func clearSelection() {
        // Commit the active editor (including IME composition) before hiding it.
        NSApp.keyWindow?.makeFirstResponder(nil)
        issueEditRevision &+= 1
        selectedNodeID = nil
        selectionRevision &+= 1
        imageHitCycle.reset()
        hitCandidates = []
    }

    func selectImage(at point: CGPoint, mapper: CoordinateMapper) {
        guard canPickImage else { return }
        if !mapper.display(CGRect(origin: .zero, size: snapshot.pixelSize)).contains(point) {
            clearSelection()
            return
        }
        guard selectionEnabled else { return }
        let candidates = mapper.candidates(at: point, in: presentationIndex, imageSize: snapshot.pixelSize,
                                           rootID: visibleRoot?.id).map(\.id)
        var cycle = imageHitCycle
        guard let next = cycle.next(in: candidates, selected: selectedNodeID) else {
            imageHitCycle = cycle; hitCandidates = []; return
        }
        select(next)
        imageHitCycle = cycle
        hitCandidates = candidates
    }

    func selectIssue(_ issue: ComponentIssue) {
        guard issue.component.snapshotID == snapshot.id, ledger.issue(for: issue.component)?.id == issue.id else { return }
        if presentationIndex.byID[issue.component.nodeID] != nil { search = "" }
        selectNode(issue.component.nodeID)
    }

    /// Both the component and editing session must still be current for delayed AppKit events.
    func edit(_ text: String, for key: ComponentKey, revision: UInt) {
        guard !isCapturing, revision == issueEditRevision, key == selectedKey, text != description,
              key.snapshotID == snapshot.id, snapshotIndex.byID[key.nodeID] != nil else { return }
        let parameters = selectedParameters
        clearedIssues = nil
        ledger.update(key, description: text, parameterIDs: parameters)
    }

    func toggleParameter(_ id: String, enabled: Bool) {
        guard !isCapturing, let key = selectedKey, selectedParameters.contains(id) != enabled else { return }
        clearedIssues = nil
        var ids = selectedParameters
        if enabled { ids.insert(id) } else { ids.remove(id) }
        transientParameters[key] = ids
        if let issue = ledger.issue(for: key) { ledger.update(key, description: issue.description, parameterIDs: ids) }
    }

    func remove(_ issue: ComponentIssue) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard ledger.issue(for: issue.component)?.id == issue.id else { return }
        issueEditRevision &+= 1
        clearedIssues = nil
        ledger.update(issue.component, description: "", parameterIDs: [])
        transientParameters.removeValue(forKey: issue.component)
    }

    func clearIssues() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard !issues.isEmpty else { return }
        issueEditRevision &+= 1
        clearedIssues = (ledger, transientParameters)
        ledger = IssueLedger()
        transientParameters = [:]
    }

    func undoClearIssues() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let previous = clearedIssues else { return }
        issueEditRevision &+= 1
        clearedIssues = nil
        ledger = previous.ledger
        transientParameters = previous.parameters
    }

    private func discardCaptureIssues() {
        clearSelection()
        ledger = IssueLedger()
        transientParameters.removeAll()
        clearedIssues = nil
    }

    func copyCurrentLocator(to pasteboard: NSPasteboard = .general) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let text = currentText
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) { notice = "已复制当前组件的 AI 定位信息" }
    }

    func copyAllIssues() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let text = batchText { _ = copy(text, successNotice: "已复制全部 \(issues.count) 条问题") }
    }

    func copy(_ text: String) {
        _ = copy(text, successNotice: "已复制到剪贴板")
    }

    func copy(_ text: String, successNotice: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        notice = successNotice
        return true
    }

    var captureProgressText: String {
        if deviceSession.resolvingCaptureTarget { return "正在定位应用…" }
        return deviceSession.progress.isEmpty ? "正在抓取界面信息…" : deviceSession.progress
    }

    private(set) var isCapturing = false

    func stopCapture() {
        guard isCapturing else { return }
        captureRequestID = UUID()
        captureRevision = UUID()
        deviceSession.cancel()
        captureWorker?.cancel()
        notice = "已停止获取界面。"
    }

    func capture(settings: ToolchainSettings) async {
        guard !isCapturing, !deviceSession.resolvingCaptureTarget else { return }
        isCapturing = true
        defer { isCapturing = false }
        captureRequestID = UUID()
        let requestID = captureRequestID
        discardCaptureIssues()
        await deviceSession.waitForCaptureCancellation()
        guard captureRequestID == requestID else { return }
        do {
            try await deviceSession.prepareCaptureTarget(settings: settings)
            guard captureRequestID == requestID else { return }
            let captured = try await deviceSession.capture(settings: settings)
            guard captureRequestID == requestID else { return }
            let source = captured.snapshot
            guard source.captureMetadata?.serial == deviceSession.selectedSerial,
                  source.packageName == deviceSession.packageName else { return }
            try await applyCapture(captured, requiringCurrentTarget: true)
        } catch is CancellationError {
            if captureRequestID == requestID { notice = "已取消抓取。" }
        } catch {
            if captureRequestID == requestID {
                notice = "获取界面失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyCapture(_ captured: CapturedSnapshot, requiringCurrentTarget: Bool = false) async throws {
        try Task.checkCancellation()
        let revision = UUID()
        captureRevision = revision
        captureWorker?.cancel()
        defer { if captureRevision == revision { captureWorker = nil } }
        // Configuration can change while preparing; publish only indexes for the latest rules.
        var configuration = filterConfiguration
        var indexes: PreparedIndexes
        while true {
            let source = captured.snapshot
            let rules = configuration
            let worker = Task.detached(priority: .userInitiated) {
                try PreparedIndexes(source, configuration: rules, checkpoint: { try Task.checkCancellation() })
            }
            captureWorker = worker
            indexes = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard captureRevision == revision else { return }
            if requiringCurrentTarget {
                guard source.captureMetadata?.serial == deviceSession.selectedSerial,
                      source.packageName == deviceSession.packageName else { return }
            }
            if configuration == filterConfiguration { break }
            configuration = filterConfiguration
        }
        guard let newImage = NSImage(data: captured.imageData) else { throw CocoaError(.fileReadCorruptFile) }
        discardCaptureIssues()
        cancelFilterIndexes()
        rawPresentation = nil
        snapshot = captured.snapshot
        image = newImage
        search = ""
        installIndexes(indexes)
        expandedNodes = Set(snapshot.roots.map(\.id))
        windowRootID = snapshot.roots.first?.id
        fitImage()
        notice = "已获取界面"
    }

    func showRawJSON(parameter: NodeParameter? = nil) {
        if let parameter, let original = parameter.original, let document = try? InspectorDocument(data: Data(original.jsonString(pretty: true).utf8)) {
            rawPresentation = RawJSONPresentation(title: parameter.name, document: document)
        } else if let document = snapshot.document {
            rawPresentation = RawJSONPresentation(title: "完整检查数据", document: document, nodePointer: selectedNodeID,
                                                  metadata: snapshot.captureMetadata)
        } else { notice = "请先获取界面。" }
    }
}
