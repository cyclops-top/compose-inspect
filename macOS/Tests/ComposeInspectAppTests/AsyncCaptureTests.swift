import AppKit
import XCTest
@testable import ComposeInspectApp
@testable import ComposeInspectCore

@MainActor
final class AsyncCaptureTests: XCTestCase {
    @MainActor private final class Response {
        var pending: CheckedContinuation<InspectorDocument, Error>?
        var started: CheckedContinuation<Void, Never>?
        func read() async throws -> InspectorDocument {
            try await withCheckedThrowingContinuation {
                pending = $0
                started?.resume(); started = nil
            }
        }
        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish(_ result: Result<InspectorDocument, Error>) {
            pending?.resume(with: result); pending = nil
        }
    }

    private func capture() throws -> CapturedSnapshot {
        let metadata = CaptureMetadata(serial: "test", packageName: "com.example.app", startedAt: Date(),
            finishedAt: Date(), includeFacets: "", stableLayout: true, stableImage: true, diagnostics: [], baselineJSON: Data())
        let snapshot = InspectorSnapshot.demo().withCaptureContext(deviceName: "test", metadata: metadata)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        return CapturedSnapshot(snapshot: snapshot, imageData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), aligned: true)
    }

    private func store() -> WorkspaceStore {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        store.deviceSession.selectedSerial = "test"
        store.deviceSession.packageName = "com.example.app"
        return store
    }

    private let parameter = NodeParameter(id: "same", name: "value", value: "…", group: .parameter, continuationToken: "token")

    func testOldFailureCannotClearNewRequestOrReplaceCurrentError() async throws {
        let store = store()
        let captured = try capture()
        try await store.applyCapture(captured)
        store.select(store.presentationIndex.roots[0].id)
        let old = Response()
        let oldTask = Task { await store.readParameter(parameter, operation: old.read) }
        await old.waitUntilStarted()
        // Reusing even the same snapshot and parameter key must not let the retired request win.
        try await store.applyCapture(captured)
        store.select(store.presentationIndex.roots[0].id)
        let current = Response()
        let currentTask = Task { await store.readParameter(parameter, operation: current.read) }
        await current.waitUntilStarted()
        store.errorMessage = "current error"
        old.finish(.failure(CommandFailure.failed("stale error")))
        await oldTask.value
        XCTAssertEqual(store.readingParameters, [parameter.id])
        XCTAssertEqual(store.errorMessage, "current error")
        current.finish(.success(try InspectorDocument(data: Data("{}".utf8))))
        await currentTask.value
        XCTAssertTrue(store.readingParameters.isEmpty)
        XCTAssertEqual(store.snapshot.parameterReads?.count, 1)
    }

    func testOldSuccessCannotAttachToNewSnapshot() async throws {
        let store = store()
        try await store.applyCapture(capture())
        store.select(store.presentationIndex.roots[0].id)
        let old = Response()
        let task = Task { await store.readParameter(parameter, operation: old.read) }
        await old.waitUntilStarted()
        let replacement = try capture()
        try await store.applyCapture(replacement)
        old.finish(.success(try InspectorDocument(data: Data("{}".utf8))))
        await task.value
        XCTAssertEqual(store.snapshot.id, replacement.snapshot.id)
        XCTAssertNil(store.snapshot.parameterReads)
        XCTAssertNil(store.rawPresentation)
        XCTAssertTrue(store.readingParameters.isEmpty)
    }

    func testSameParameterOnDifferentNodesCanReadIndependently() async throws {
        let store = store()
        try await store.applyCapture(capture())
        let nodes = Array(store.presentationIndex.nodes.prefix(2))
        XCTAssertEqual(nodes.count, 2)
        store.select(nodes[0].id)
        let first = Response()
        let firstTask = Task { await store.readParameter(parameter, operation: first.read) }
        await first.waitUntilStarted()
        store.select(nodes[1].id)
        XCTAssertTrue(store.readingParameters.isEmpty)
        let second = Response()
        let secondTask = Task { await store.readParameter(parameter, operation: second.read) }
        await second.waitUntilStarted()
        first.finish(.success(try InspectorDocument(data: Data("{}".utf8))))
        await firstTask.value
        XCTAssertEqual(store.readingParameters, [parameter.id])
        XCTAssertNil(store.rawPresentation)
        second.finish(.success(try InspectorDocument(data: Data("{}".utf8))))
        await secondTask.value
        XCTAssertEqual(store.snapshot.parameterReads?.map(\.nodeID), nodes.map(\.id))
    }

    func testDuplicateReadIsSuppressedAndCancelledResponseIsDiscarded() async throws {
        let store = store()
        try await store.applyCapture(capture())
        store.select(store.presentationIndex.roots[0].id)
        let response = Response()
        let task = Task { await store.readParameter(parameter, operation: response.read) }
        await response.waitUntilStarted()
        await store.readParameter(parameter) {
            XCTFail("Duplicate request must not invoke the client")
            return try InspectorDocument(data: Data("{}".utf8))
        }
        task.cancel()
        response.finish(.success(try InspectorDocument(data: Data("{}".utf8))))
        await task.value
        XCTAssertTrue(store.readingParameters.isEmpty)
        XCTAssertNil(store.snapshot.parameterReads)
        XCTAssertNil(store.errorMessage)
    }

    func testCaptureForPreviousTargetCannotReplaceCurrentSession() async throws {
        let store = store()
        let original = try capture()
        try await store.applyCapture(original)
        store.deviceSession.selectedSerial = "other-device"
        try await store.applyCapture(capture(), requiringCurrentTarget: true)
        XCTAssertEqual(store.snapshot.id, original.snapshot.id)
        XCTAssertEqual(store.snapshotIndex.nodes, original.snapshot.nodes)
    }

    func testPreparedIndexesMatchSnapshotAndCancellationPreservesSession() async throws {
        let store = store()
        let captured = try capture()
        try await store.applyCapture(captured)
        XCTAssertEqual(store.snapshotIndex.nodes, captured.snapshot.nodes)
        XCTAssertEqual(store.presentationIndex.nodes,
            InspectorSnapshotIndex(captured.snapshot, hidingInternals: store.hideInternalNodes,
                onlyClickable: store.onlyClickableNodes, configuration: store.filterConfiguration).nodes)
        let replacement = try capture()
        let task = Task { try await store.applyCapture(replacement) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(store.snapshot.id, captured.snapshot.id)
        XCTAssertEqual(store.snapshotIndex.nodes, captured.snapshot.nodes)
    }
    func testRapidFilterEditsPublishOnlyLatestRules() async throws {
        let store = store()
        try await store.applyCapture(capture())
        let revision = store.presentationRevision
        let original = store.filterConfiguration
        store.filterConfiguration.hideTextImplementation.toggle()
        store.filterConfiguration.hideLayoutImplementation.toggle()
        store.filterConfiguration = original
        await store.waitForFilterIndexes()
        XCTAssertEqual(store.presentationRevision, revision + 1)
        XCTAssertEqual(store.presentationIndex.nodes,
            InspectorSnapshotIndex(store.snapshot, hidingInternals: store.hideInternalNodes,
                onlyClickable: store.onlyClickableNodes, configuration: original).nodes)
    }

    func testPendingFilterCannotOverwriteNewCapture() async throws {
        let store = store()
        try await store.applyCapture(capture())
        let original = store.filterConfiguration
        defer { store.filterConfiguration = original }
        store.filterConfiguration.hideTextImplementation.toggle()
        let replacement = try capture()
        try await store.applyCapture(replacement)
        await store.waitForFilterIndexes()
        XCTAssertEqual(store.snapshot.id, replacement.snapshot.id)
        XCTAssertEqual(store.snapshotIndex.nodes, replacement.snapshot.nodes)
        XCTAssertEqual(store.presentationIndex.nodes,
            InspectorSnapshotIndex(replacement.snapshot, hidingInternals: store.hideInternalNodes,
                onlyClickable: store.onlyClickableNodes, configuration: store.filterConfiguration).nodes)
    }

    func testSearchReusesItemsAndRestoresChildren() async throws {
        let store = store()
        try await store.applyCapture(capture())
        let coordinator = NativeHierarchyView.Coordinator(store: store)
        let outline = NSOutlineView()
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.synchronize(store: store)
        let root = try XCTUnwrap(coordinator.outlineView(outline, child: 0, ofItem: nil) as? NativeHierarchyView.Item)
        let children = root.children
        store.search = "no-such-component-123456"
        coordinator.synchronize(store: store)
        XCTAssertEqual(coordinator.outlineView(outline, numberOfChildrenOfItem: nil), 0)
        store.search = ""
        coordinator.synchronize(store: store)
        let restored = try XCTUnwrap(coordinator.outlineView(outline, child: 0, ofItem: nil) as? NativeHierarchyView.Item)
        XCTAssertTrue(root === restored)
        XCTAssertEqual(restored.children.count, children.count)
        for (before, after) in zip(children, restored.children) { XCTAssertTrue(before === after) }
    }

}
