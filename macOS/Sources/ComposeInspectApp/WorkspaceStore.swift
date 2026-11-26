import AppKit
import ComposeInspectCore
import Observation

@MainActor @Observable
final class WorkspaceStore {
    private(set) var snapshot: InspectorSnapshot
    private var captureRevision = UUID()
    @ObservationIgnored private var captureTask: Task<Void, Error>?

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
            if filterClickable && !hideInternalNodes { hideInternalNodes = true }
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
    var geometrySnapshot: Bool { snapshot.document?.root["sdkCapture"]?["geometryOnly"]?.boolean == true }
    var filterClickable: Bool { onlyClickableNodes && !geometrySnapshot }
    var componentDetails: Bool {
        didSet { filterDefaults.set(componentDetails, forKey: "captureComponentDetails") }
    }
    var onlySourceNodes: Bool {
        didSet {
            filterDefaults.set(onlySourceNodes, forKey: "onlySourceNodes")
            updatePresentationIndex()
        }
    }

    private func updatePresentationIndex() {
        presentationRevision &+= 1
        let base = searchesAllComponents ? snapshotIndex : filterClickable ? clickableIndex : (hideInternalNodes ? compactIndex : snapshotIndex)
        if onlySourceNodes && !searchesAllComponents {
            presentationIndex = base.filteringNodes { node in
                LocatorTextBuilder.usableSource(node.source) != nil
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
        searchMatches = search.isEmpty ? nil : presentationIndex.matchingIDs(search).filter { isInVisibleWindow($0) }
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
            updateSearchMatches()
            imageHitCycle.reset()
            hitCandidates = []
            if let selectedNodeID, !isInVisibleWindow(selectedNodeID) { clearSelection() }
        }
    }
    @ObservationIgnored private var imageHitCycle = ImageHitCycle()
    var errorMessage: String?
    var notice = "等待获取界面"
    private var screenImage: NSImage?
    private var windowImages: [String: NSImage] = [:]
    var image: NSImage? { windowRootID.flatMap { windowImages[$0] } ?? screenImage }

    func image(for root: InspectorNode) -> NSImage? { windowImages[root.id] ?? screenImage }
    private var transientParameters: [ComponentKey: Set<String>] = [:]
    let deviceSession = DeviceSession()
    var rawPresentation: RawJSONPresentation?
    private(set) var issueEditRevision: UInt = 0

    init(filterDefaults: UserDefaults = .standard) {
        self.filterDefaults = filterDefaults
        componentDetails = filterDefaults.bool(forKey: "captureComponentDetails")
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
    var visibleRoots: [InspectorNode] {
        guard let windowRootID else { return presentationIndex.roots }
        return presentationIndex.byID[windowRootID].map { [$0] } ?? []
    }
    var visibleNodes: [InspectorNode] {
        windowRootID.flatMap { presentationIndex.nodesByRoot[$0] } ?? presentationIndex.nodes
    }
    var visibleBounds: [CGRect] { visibleRoots.flatMap { presentationIndex.boundsByRoot[$0.id] ?? [] } }
    func isInVisibleWindow(_ nodeID: String) -> Bool {
        guard let root = snapshotIndex.rootIDs[nodeID] else { return false }
        return windowRootID == nil || root == windowRootID
    }
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
        if windowRootID != nil { windowRootID = snapshotIndex.rootIDs[nodeID] }
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
                                           rootID: windowRootID).map(\.id)
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
        if verificationTask != nil { return verificationResult ?? "正在复核点击目标…" }
        if deviceSession.resolvingCaptureTarget { return "正在定位应用…" }
        return deviceSession.progress.isEmpty ? "正在抓取界面信息…" : deviceSession.progress
    }

    private(set) var isCapturing = false
    private(set) var verificationResult: String?
    private var verificationTask: Task<Void, Never>?

    func verifyClick(expected: String, settings: ToolchainSettings) async {
        guard !isCapturing, !deviceSession.resolvingCaptureTarget,
              !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let node = selectedNode, node.isClickable, let device = deviceSession.selectedDevice else { return }
        isCapturing = true
        defer { isCapturing = false; verificationTask = nil }
        let baseline = snapshot
        let baselineIndex = snapshotIndex
        var phase = "尚未点击"
        let started = ContinuousClock.now
        let pollDeadline = started + .seconds(16)
        var expired = false
        verificationResult = "正在复核目标"
        let worker = Task { @MainActor in
            do {
                let tools = try settings.resolvedTools()
                let sdk = SDKInspectorClient(tools: tools)
                let adb = InspectorClient(tools: tools)
                let original = try ClickTarget(node: node, snapshot: baseline)
                @MainActor func checkTarget() throws {
                    try Task.checkCancellation()
                    guard device.serial == original.serial, deviceSession.selectedSerial == original.serial,
                          deviceSession.packageName == original.package else {
                        throw CommandFailure.failed("当前设备或应用已切换。")
                    }
                }
                let filtered = baseline.document?.root["sdkCapture"]
                @MainActor func readSnapshot() async throws -> CapturedSnapshot {
                    try checkTarget()
                    return try await sdk.capture(serial: original.serial, package: original.package, deviceName: device.model,
                                                 componentDetails: true, onlySourceNodes: filtered?["onlySourceNodes"]?.boolean == true)
                }
                let before = try await readSnapshot().snapshot
                let index = InspectorSnapshotIndex(before)
                guard let fresh = ClickTarget.match(node, from: baseline, index: baselineIndex, to: before, index: index) else {
                    throw CommandFailure.failed("重新采集后无法唯一确认点击实例。")
                }
                let target = try ClickTarget(node: fresh, snapshot: before)
                guard target.label == original.label, target.screen == original.screen else {
                    throw CommandFailure.failed("目标内容或屏幕尺寸已变化，请重新选择。")
                }
                try await adb.checkTap(target, expected: expected)
                try checkTarget()
                let tapTimeout = try Self.tapTimeout(until: pollDeadline)
                phase = "点击命令已提交，执行结果未知"
                verificationResult = phase
                _ = try await adb.adb(["-s", target.serial, "shell", "input", "-d", "0", "tap",
                                      String(Int(target.point.x)), String(Int(target.point.y))], timeout: tapTimeout)
                phase = "已点击一次"
                verificationResult = phase + "，等待「" + expected + "」"
                var checks = 0
                var satisfied = false
                guard ContinuousClock.now < pollDeadline else {
                    throw CommandFailure.failed("剩余时间不足，未检查点击结果。")
                }
                repeat {
                    try checkTarget()
                    let remaining = ContinuousClock.now.duration(to: pollDeadline).components
                    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                    do {
                        satisfied = try await adb.expectedTextVisible(expected, target: target, timeout: min(6, max(0, seconds)))
                    } catch CommandFailure.timedOut {
                        if ContinuousClock.now >= pollDeadline { break }
                        throw CommandFailure.timedOut
                    }
                    if satisfied { break }
                    checks += 1
                    verificationResult = phase + " · 已检查 " + String(checks) + " 次，尚未出现「" + expected + "」"
                    try await Task.sleep(until: min(pollDeadline, .now + .milliseconds(min(2000, checks * 500))), clock: .continuous)
                } while ContinuousClock.now < pollDeadline
                phase += satisfied ? "，已观察到「" + expected + "」" : "，条件等待超时 · 未观察到「" + expected + "」"
                verificationResult = phase + "，获取结果快照中"
                let final = try await readSnapshot()
                try checkTarget()
                guard final.snapshot.document?.root["sdkCapture"]?["pid"]?.int64 == target.pid else {
                    throw CommandFailure.failed("目标进程发生变化。")
                }
                try await applyCapture(final, requiringCurrentTarget: true)
                try checkTarget()
                guard snapshot.id == final.snapshot.id else { throw CancellationError() }
                if selectedNodeID == nil,
                   let matched = ClickTarget.match(fresh, from: before, index: index, to: snapshot, index: snapshotIndex),
                   presentationIndex.byID[matched.id] != nil { selectNode(matched.id) }
                verificationResult = (satisfied ? "验证通过 · " : "") + phase + " · 已获取结果快照"
                notice = "单次点击验证完成"
            } catch {
                let prior = verificationResult
                let reason = expired ? "20 秒预算已用尽" : (Task.isCancelled ? "已停止" : error.localizedDescription)
                verificationResult = (expired ? (prior ?? phase) : phase) + " · " + reason
                notice = "单次点击验证结束"
            }
        }
        verificationTask = worker
        let deadline = Task { @MainActor in
            try await Task.sleep(until: started + .seconds(20), clock: .continuous)
            expired = true
            worker.cancel()
        }
        await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        deadline.cancel()
    }

    static func tapTimeout(until pollDeadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) throws -> TimeInterval {
        // Keep the full six-second accessibility read available after the tap.
        let remaining = now.duration(to: pollDeadline) - .seconds(6)
        guard remaining > .zero else {
            throw CommandFailure.failed("剩余时间不足以复核点击结果，请重试。")
        }
        let duration = min(remaining, .seconds(3)).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func stopCapture() {
        guard isCapturing else { return }
        verificationTask?.cancel()
        captureTask?.cancel()
        notice = "已停止获取界面。"
    }

    func capture(settings: ToolchainSettings) async {
        guard !isCapturing, !deviceSession.resolvingCaptureTarget else { return }
        isCapturing = true
        defer { isCapturing = false; captureTask = nil }
        verificationResult = nil
        discardCaptureIssues()
        let task = Task {
            try Task.checkCancellation()
            try await deviceSession.prepareCaptureTarget(settings: settings)
            try Task.checkCancellation()
            let captured = try await deviceSession.capture(settings: settings, componentDetails: componentDetails, onlySourceNodes: onlySourceNodes)
            try Task.checkCancellation()
            let source = captured.snapshot
            guard source.captureMetadata?.serial == deviceSession.selectedSerial,
                  source.packageName == deviceSession.packageName else { return }
            try await applyCapture(captured, requiringCurrentTarget: true)
        }
        captureTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if task.isCancelled || error is CancellationError {
                notice = "已停止获取界面。"
            } else {
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
        var newImage = NSImage(data: captured.imageData)
        let size = captured.snapshot.pixelSize
        let pairedImages = try captured.windowImages.mapValues { entry -> NSImage in
            guard let source = NSBitmapImageRep(data: entry.png)?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
            if entry.origin == .zero, source.width == Int(size.width), source.height == Int(size.height) {
                return NSImage(cgImage: source, size: size)
            }
            guard let canvas = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let height = CGFloat(source.height)
            canvas.draw(source, in: CGRect(x: entry.origin.x, y: size.height - entry.origin.y - height,
                                           width: CGFloat(source.width), height: height))
            guard let result = canvas.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            return NSImage(cgImage: result, size: size)
        }
        if pairedImages.count == 1 {
            newImage = pairedImages.values.first
        } else if !pairedImages.isEmpty {
            guard let canvas = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for root in captured.snapshot.roots.reversed() {
                guard let pixels = pairedImages[root.id]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { throw CocoaError(.fileReadCorruptFile) }
                canvas.draw(pixels, in: CGRect(origin: .zero, size: size))
            }
            newImage = canvas.makeImage().map { NSImage(cgImage: $0, size: size) }
        }
        guard newImage != nil else { throw CocoaError(.fileReadCorruptFile) }
        discardCaptureIssues()
        cancelFilterIndexes()
        rawPresentation = nil
        snapshot = captured.snapshot
        screenImage = newImage
        windowImages = pairedImages
        search = ""
        installIndexes(indexes)
        expandedNodes = Set(snapshot.roots.map(\.id))
        windowRootID = nil
        fitImage()
        notice = geometrySnapshot ? "已快速采集结构与边界" : "已获取界面"
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
