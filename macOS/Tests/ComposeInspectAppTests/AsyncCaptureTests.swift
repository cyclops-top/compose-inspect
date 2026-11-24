import AppKit
import XCTest
@testable import ComposeInspectApp
@testable import ComposeInspectCore

@MainActor
final class AsyncCaptureTests: XCTestCase {
    private func capture() throws -> CapturedSnapshot {
        let metadata = CaptureMetadata(serial: "test", packageName: "com.example.app", startedAt: Date(),
            finishedAt: Date(), diagnostics: [], baselineJSON: Data())
        let snapshot = InspectorSnapshot.demo().withCaptureContext(deviceName: "test", metadata: metadata)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        return CapturedSnapshot(snapshot: snapshot, imageData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }

    private func store() -> WorkspaceStore {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        store.deviceSession.selectedSerial = "test"
        store.deviceSession.packageName = "com.example.app"
        return store
    }

    func testTapBudgetReservesTimeForFirstResultCheck() throws {
        let now = ContinuousClock.now
        XCTAssertThrowsError(try WorkspaceStore.tapTimeout(until: now - .seconds(1), now: now))
        XCTAssertThrowsError(try WorkspaceStore.tapTimeout(until: now + .seconds(6), now: now))
        XCTAssertEqual(try WorkspaceStore.tapTimeout(until: now + .seconds(7), now: now), 1)
        XCTAssertEqual(try WorkspaceStore.tapTimeout(until: now + .seconds(16), now: now), 3)
    }

    func testStopInterruptsForegroundLookupBeforeItChangesThePackage() async throws {
        let store = store()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("adb")
        let marker = directory.appendingPathComponent("started")
        try """
        #!/bin/sh
        echo 'topResumedActivity=ActivityRecord u0 dev.stale/.Activity'
        touch "$MARKER"
        exec /bin/sleep 8
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolchainSettings(defaults: defaults, environment: ["ADB": adb.path, "MARKER": marker.path])
        store.deviceSession.devices = ADBDevice.parse("test device model:Test")
        let capture = Task { await store.capture(settings: settings) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(store.deviceSession.resolvingCaptureTarget)
        let stopped = ContinuousClock.now
        store.stopCapture()
        await capture.value
        XCTAssertLessThan(stopped.duration(to: .now), .seconds(3))
        XCTAssertFalse(store.isCapturing)
        XCTAssertEqual(store.deviceSession.packageName, "com.example.app")
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
