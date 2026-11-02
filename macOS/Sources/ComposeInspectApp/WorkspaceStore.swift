import AppKit
import ComposeInspectCore
import Observation

@MainActor @Observable
final class WorkspaceStore {
    private(set) var snapshot: InspectorSnapshot
    private var captureRevision = UUID()

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
    private func updatePresentationIndex() {
        presentationRevision &+= 1
        presentationIndex = onlyClickableNodes ? clickableIndex : (hideInternalNodes ? compactIndex : snapshotIndex)
        imageHitCycle.reset(); hitCandidates = []
        if let selected = selectedNodeID, presentationIndex.byID[selected] == nil { clearSelection() }
    }
    private(set) var snapshots: [UUID: InspectorSnapshot]
    private(set) var ledger = IssueLedger()
    private(set) var selectedNodeID: String?
    private(set) var selectionRevision: UInt = 0
    var expandedNodes: Set<String> = []
    var search = ""
    var showWireframes = UserDefaults.standard.object(forKey: "showWireframes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWireframes, forKey: "showWireframes") }
    }
    var selectionEnabled = true
    var zoom: CGFloat = 1
    var imagePan: CGSize = .zero
    func fitImage() { zoom = 1; imagePan = .zero }
    var hitCandidates: [String] = []
    var windowRootID: String? {
        didSet { if oldValue != windowRootID { imageHitCycle.reset(); hitCandidates = [] } }
    }
    @ObservationIgnored private var imageHitCycle = ImageHitCycle()
    var errorMessage: String?
    var notice = "等待获取界面"
    private(set) var images: [UUID: NSImage] = [:]
    private var transientParameters: [ComponentKey: Set<String>] = [:]
    let deviceSession = DeviceSession()
    var rawPresentation: RawJSONPresentation?
    private struct ParameterRequestKey: Hashable {
        let component: ComponentKey
        let parameterID: String
    }
    private var parameterRequests: [ParameterRequestKey: UUID] = [:]
    var readingParameters: Set<String> {
        guard let key = selectedKey else { return [] }
        return Set(parameterRequests.keys.filter { $0.component == key }.map(\.parameterID))
    }
    private var liveSnapshotIDs: Set<UUID> = []
    private(set) var issueEditRevision: UInt = 0

    init(filterDefaults: UserDefaults = .standard) {
        self.filterDefaults = filterDefaults
        let configuration = filterDefaults.data(forKey: "tree.filterConfiguration.v1")
            .flatMap { try? JSONDecoder().decode(NodeFilterConfiguration.self, from: $0) } ?? .defaults
        filterConfiguration = configuration
        let initial = Self.emptySnapshot()
        snapshot = initial; snapshots = [initial.id: initial]
        let full = InspectorSnapshotIndex(initial)
        let compact = InspectorSnapshotIndex(initial, hidingInternals: true, configuration: configuration)
        snapshotIndex = full
        compactIndex = compact
        let clickable = InspectorSnapshotIndex(initial, onlyClickable: true, configuration: configuration)
        clickableIndex = clickable
        presentationIndex = UserDefaults.standard.bool(forKey: "onlyClickableNodes") ? clickable
            : ((UserDefaults.standard.object(forKey: "hideInternalNodes") as? Bool ?? true) ? compact : full)
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
        return ledger.issue(for: key)?.parameterIDs ?? transientParameters[key] ?? []
    }
    var image: NSImage? { images[snapshot.id] }
    var canPickImage: Bool {
        liveSnapshotIDs.contains(snapshot.id) && (snapshot.document?.displays.count ?? 0) <= 1
    }
    var visibleRoot: InspectorNode? { presentationIndex.roots.first { $0.id == windowRootID } ?? presentationIndex.roots.first }
    var visibleNodes: [InspectorNode] { visibleRoot.flatMap { presentationIndex.nodesByRoot[$0.id] } ?? [] }
    var visibleBounds: [CGRect] { visibleRoot.flatMap { presentationIndex.boundsByRoot[$0.id] } ?? [] }
    func isInVisibleWindow(_ nodeID: String) -> Bool { snapshotIndex.rootIDs[nodeID] == visibleRoot?.id }
    var issues: [ComponentIssue] { ledger.issues }
    var currentText: String {
        guard let key = selectedKey else { return "" }
        let target = ComponentIssue(component: key, description: description, parameterIDs: selectedParameters)
        return LocatorTextBuilder.text(for: target, in: snapshot, index: snapshotIndex) ?? ""
    }
    var sourceSummary: String {
        selectedNodeID.map { LocatorTextBuilder.sourceSummary(for: $0, index: snapshotIndex) } ?? "未选择组件"
    }
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
    var batchText: String? { LocatorTextBuilder.batch(issues, snapshots: snapshots) }
    var path: [InspectorNode] { selectedNodeID.map { presentationIndex.path(to: $0) } ?? [] }

    func select(_ nodeID: String) {
        guard presentationIndex.byID[nodeID] != nil else { return }
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
        guard issue.component.snapshotID == snapshot.id, snapshotIndex.byID[issue.component.nodeID] != nil else { return }
        if presentationIndex.byID[issue.component.nodeID] != nil { search = "" }
        selectNode(issue.component.nodeID)
    }

    /// Both the component and editing session must still be current for delayed AppKit events.
    func edit(_ text: String, for key: ComponentKey, revision: UInt) {
        guard revision == issueEditRevision, key == selectedKey,
              key.snapshotID == snapshot.id, snapshotIndex.byID[key.nodeID] != nil else { return }
        let parameters = ledger.issue(for: key)?.parameterIDs ?? transientParameters[key] ?? []
        ledger.update(key, description: text, parameterIDs: parameters)
    }

    func toggleParameter(_ id: String, enabled: Bool) {
        guard let key = selectedKey else { return }
        var ids = selectedParameters
        if enabled { ids.insert(id) } else { ids.remove(id) }
        transientParameters[key] = ids
        if let issue = ledger.issue(for: key) { ledger.update(key, description: issue.description, parameterIDs: ids) }
    }

    func remove(_ issue: ComponentIssue) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        issueEditRevision &+= 1
        ledger.update(issue.component, description: "", parameterIDs: [])
        transientParameters.removeValue(forKey: issue.component)
    }

    func clearIssues() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        issueEditRevision &+= 1
        ledger = IssueLedger()
        transientParameters = [:]
    }

    func targetChanged() {
        guard let metadata = snapshot.captureMetadata,
              metadata.serial != deviceSession.selectedSerial || metadata.packageName != deviceSession.packageName else { return }
        deviceSession.cancel()
        clearIssues()
        let empty = Self.emptySnapshot()
        captureRevision = UUID()
        captureWorker?.cancel()
        cancelFilterIndexes()
        snapshot = empty
        installIndexes(PreparedIndexes(empty, configuration: filterConfiguration, checkpoint: {}))
        snapshots = [empty.id: empty]; images = [:]; liveSnapshotIDs = []
        selectedNodeID = nil; expandedNodes = []; windowRootID = nil; search = ""; fitImage()
        rawPresentation = nil; parameterRequests = [:]
        notice = "等待获取界面"
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
        if let text = batchText { copy(text) }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { notice = "已复制到剪贴板" }
    }

    func capture(settings: ToolchainSettings) async {
        guard !deviceSession.capturing, !deviceSession.resolvingCaptureTarget else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
            try await deviceSession.prepareCaptureTarget(settings: settings)
            targetChanged()
            let captured = try await deviceSession.capture(settings: settings)
            let source = captured.snapshot
            guard source.captureMetadata?.serial == deviceSession.selectedSerial,
                  source.packageName == deviceSession.packageName else { return }
            try await applyCapture(captured, requiringCurrentTarget: true)
        } catch is CancellationError { notice = "已取消抓取，保留上次快照。" }
        catch { errorMessage = error.localizedDescription }
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
        guard let image = NSImage(data: captured.imageData) else { throw CocoaError(.fileReadCorruptFile) }
        cancelFilterIndexes()
        clearIssues()
        let source = captured.snapshot
        snapshots = [source.id: source]; images = [source.id: image]; liveSnapshotIDs = [source.id]
        rawPresentation = nil; parameterRequests = [:]
        snapshot = source
        installIndexes(indexes)
        selectedNodeID = nil; search = ""; fitImage(); hitCandidates = []
        expandedNodes = Set(source.roots.map(\.id)); windowRootID = source.roots.first?.id
        notice = "已获取界面"
    }

    func showRawJSON(parameter: NodeParameter? = nil) {
        if let parameter, let original = parameter.original, let document = try? InspectorDocument(data: Data(original.jsonString(pretty: true).utf8)) {
            rawPresentation = RawJSONPresentation(title: parameter.name, document: document)
        } else if let document = snapshot.document {
            rawPresentation = RawJSONPresentation(title: "完整检查数据", document: document, nodePointer: selectedNodeID,
                                                  metadata: snapshot.captureMetadata, reads: snapshot.parameterReads ?? [])
        } else { notice = "请先获取界面。" }
    }

    func canRead(_ parameter: NodeParameter) -> Bool {
        guard parameter.continuationToken != nil, liveSnapshotIDs.contains(snapshot.id), let metadata = snapshot.captureMetadata else { return false }
        return !deviceSession.capturing && metadata.serial == deviceSession.selectedSerial && metadata.packageName == deviceSession.packageName
    }

    func readParameter(_ parameter: NodeParameter, settings: ToolchainSettings) async {
        guard let metadata = snapshot.captureMetadata, let token = parameter.continuationToken else { return }
        await readParameter(parameter) {
            let client = InspectorClient(tools: try settings.resolvedTools())
            return try await client.parameter(serial: metadata.serial, package: metadata.packageName, token: token)
        }
    }

    func readParameter(_ parameter: NodeParameter,
                       operation: @MainActor () async throws -> InspectorDocument) async {
        guard canRead(parameter), let token = parameter.continuationToken, let key = selectedKey,
              let source = snapshots[key.snapshotID], let metadata = source.captureMetadata else { return }
        let requestKey = ParameterRequestKey(component: key, parameterID: parameter.id)
        guard parameterRequests[requestKey] == nil else { return }
        let requestID = UUID()
        parameterRequests[requestKey] = requestID
        defer {
            if parameterRequests[requestKey] == requestID { parameterRequests.removeValue(forKey: requestKey) }
        }
        func isCurrent() -> Bool {
            parameterRequests[requestKey] == requestID && snapshot.id == key.snapshotID
                && deviceSession.selectedSerial == metadata.serial && deviceSession.packageName == metadata.packageName
        }
        do {
            let document = try await operation()
            try Task.checkCancellation()
            guard isCurrent() else { return }
            var updated = snapshot
            let read = ParameterRead(nodeID: key.nodeID, parameterID: parameter.id, token: token, document: document)
            updated.parameterReads = (updated.parameterReads ?? []) + [read]
            snapshots[key.snapshotID] = updated
            snapshot = updated
            if selectedKey == key { rawPresentation = RawJSONPresentation(title: "后续参数读取 · \(parameter.name)", document: document) }
            notice = "参数已继续读取；结果单独保存，原快照未被覆盖。"
        } catch is CancellationError {
            // Cancellation retires this request without replacing the current UI's status.
        } catch {
            if isCurrent() { errorMessage = error.localizedDescription }
        }
    }

}
