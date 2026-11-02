import AppKit
import XCTest
import SwiftUI
@testable import ComposeInspectApp
@testable import ComposeInspectCore

final class CurrentSessionTests: XCTestCase {
    @MainActor func testSwitchAfterCutRejectsPreviousEditorCallbacksIncludingAfterReselection() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        let child = try XCTUnwrap(store.selectedKey)
        let revision = store.issueEditRevision
        store.edit("调整间距", for: child, revision: revision)
        store.edit("", for: child, revision: revision)
        store.select("screen")
        store.edit("调整间距", for: child, revision: revision)
        XCTAssertTrue(store.issues.isEmpty, "A stale editor must not recreate the cut child's issue")

        let ancestor = try XCTUnwrap(store.selectedKey)
        store.edit("调整间距", for: ancestor, revision: store.issueEditRevision)
        XCTAssertEqual(store.issues.map(\.component), [ancestor])
        XCTAssertFalse(store.currentText.isEmpty)
        store.select("login")
        store.edit("过期输入", for: child, revision: revision)
        XCTAssertTrue(store.description.isEmpty)
        XCTAssertEqual(store.issues.map(\.component), [ancestor])
    }

    @MainActor func testCutThenPasteIntoAncestorRecordsSelectedComponent() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        let host = NSHostingController(rootView: IssuesWorkspaceView(store: store).environment(ToolchainSettings()))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1000, height: 300))
        defer { window.orderOut(nil) }

        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func settle() async {
            host.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            host.view.layoutSubtreeIfNeeded()
        }
        await settle()
        var input = try XCTUnwrap(editor(in: host.view))
        input.insertText("调整间距", replacementRange: NSRange(location: 0, length: 0))
        await settle()
        XCTAssertEqual(store.issues.first?.component.nodeID, "login")
        input.insertText("", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
        await settle()
        XCTAssertTrue(store.issues.isEmpty)

        store.select("screen")
        await settle()
        input = try XCTUnwrap(editor(in: host.view))
        input.insertText("调整间距", replacementRange: NSRange(location: 0, length: 0))
        await settle()
        XCTAssertEqual(store.selectedNodeID, "screen")
        XCTAssertEqual(store.issues.count, 1)
        XCTAssertEqual(store.issues.first?.component.nodeID, "screen")
        XCTAssertFalse(store.currentText.isEmpty)
        store.selectIssue(try XCTUnwrap(store.issues.first))
        XCTAssertEqual(store.selectedNodeID, "screen")
    }

    @MainActor func testFitImageResetsZoomAndPan() async {
        let store = WorkspaceStore()
        store.zoom = 3
        store.imagePan = CGSize(width: 100, height: -50)
        store.fitImage()
        XCTAssertEqual(store.zoom, 1)
        XCTAssertEqual(store.imagePan, .zero)
    }

    @MainActor private func captured() throws -> CapturedSnapshot {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        return CapturedSnapshot(snapshot: .demo(), imageData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), aligned: true)
    }

    @MainActor func testNewCaptureReplacesEntireSessionAndRejectsOldEditorCallbacks() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        XCTAssertTrue(store.snapshot.nodes.isEmpty)
        XCTAssertTrue(store.issues.isEmpty)
        try await store.applyCapture(captured())
        store.select("login")
        let oldKey = try XCTUnwrap(store.selectedKey), oldRevision = store.issueEditRevision
        store.edit("修改按钮", for: oldKey, revision: oldRevision)
        XCTAssertEqual(store.issues.count, 1)
        try await store.applyCapture(captured())
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.images.count, 1)
        XCTAssertNil(store.snapshots[oldKey.snapshotID])
        store.edit("迟到的输入", for: oldKey, revision: oldRevision)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertTrue(WorkspaceStore().snapshot.nodes.isEmpty)
    }

    @MainActor func testClearSelectionPreservesIssueAndResetsHitCycle() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        let key = try XCTUnwrap(store.selectedKey), revision = store.issueEditRevision
        store.edit("保留修改要求", for: key, revision: revision)
        store.hitCandidates = ["login"]
        store.clearSelection()
        XCTAssertNil(store.selectedNodeID)
        XCTAssertTrue(store.path.isEmpty)
        XCTAssertTrue(store.hitCandidates.isEmpty)
        XCTAssertEqual(store.issues.first?.description, "保留修改要求")
        store.edit("过期回调", for: key, revision: revision)
        store.select("login")
        XCTAssertEqual(store.description, "保留修改要求")
    }

    @MainActor func testClickOutsideScreenshotClearsSelectionEvenWhenPickingDisabled() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        store.selectionEnabled = false
        let size = store.snapshot.pixelSize
        let mapper = CoordinateMapper(imageSize: size, canvasSize: CGSize(width: size.width * 2, height: size.height))
        store.selectImage(at: CGPoint(x: 0, y: 0), mapper: mapper)
        XCTAssertNil(store.selectedNodeID)
        XCTAssertTrue(store.hitCandidates.isEmpty)
    }

    @MainActor func testDeleteAndClearImmediatelyEmptyEditorAndCannotResurrectIssues() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        let key = try XCTUnwrap(store.selectedKey), revision = store.issueEditRevision
        store.edit("修改按钮", for: key, revision: revision)
        store.remove(try XCTUnwrap(store.issues.first))
        XCTAssertTrue(store.description.isEmpty)
        store.edit("旧编辑器失焦", for: key, revision: revision)
        XCTAssertTrue(store.issues.isEmpty)
        let current = store.issueEditRevision
        store.edit("新的问题", for: key, revision: current)
        XCTAssertEqual(store.issues.count, 1)
        store.clearIssues()
        store.edit("清空前的编辑器回调", for: key, revision: current)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertTrue(store.description.isEmpty)
        XCTAssertEqual(store.selectedKey, key)
    }
    @MainActor func testClickableFilterLocksCompactAndHiddenIssueDoesNotChangeFiltersOrTreePath() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let oldCompact = defaults.object(forKey: "hideInternalNodes")
        let oldClickable = defaults.object(forKey: "onlyClickableNodes")
        defer {
            defaults.set(oldCompact, forKey: "hideInternalNodes")
            defaults.set(oldClickable, forKey: "onlyClickableNodes")
        }
        let store = WorkspaceStore()
        store.onlyClickableNodes = false
        store.hideInternalNodes = false
        try await store.applyCapture(captured())
        store.select("login")
        let key = try XCTUnwrap(store.selectedKey)
        store.edit("保留按钮问题", for: key, revision: store.issueEditRevision)
        let issue = try XCTUnwrap(store.currentIssue)
        store.onlyClickableNodes = true
        XCTAssertTrue(store.hideInternalNodes)
        store.hideInternalNodes = false
        XCTAssertTrue(store.hideInternalNodes)
        XCTAssertNil(store.presentationIndex.byID["login"], "Demo button has no click semantics")
        XCTAssertNil(store.selectedNodeID)
        store.select("login")
        XCTAssertNil(store.selectedNodeID, "Ordinary selection must use the filtered result")
        let expanded = store.expandedNodes
        store.search = "unmatched"
        store.selectIssue(issue)
        XCTAssertEqual(store.selectedKey, key)
        XCTAssertEqual(store.highlightedNode?.id, "login")
        XCTAssertTrue(store.path.isEmpty)
        XCTAssertEqual(store.expandedNodes, expanded)
        XCTAssertEqual(store.search, "unmatched")
        XCTAssertTrue(store.onlyClickableNodes)
        XCTAssertTrue(store.hideInternalNodes)
        XCTAssertEqual(store.issues.first?.component, key)
        XCTAssertEqual(store.visibleNodes.map(\.id), store.presentationIndex.nodes.map(\.id))
        store.onlyClickableNodes = false
        XCTAssertTrue(store.hideInternalNodes)
        store.hideInternalNodes = false
        XCTAssertFalse(store.hideInternalNodes)
        XCTAssertNotNil(store.presentationIndex.byID["login"])
    }

    @MainActor func testCopyWithoutDescriptionIncludesSelectedParametersAndCreatesNoIssue() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        store.toggleParameter("修饰符.height", enabled: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        store.copyCurrentLocator(to: board)
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(copied, store.currentText)
        XCTAssertTrue(copied.contains("height=48dp"))
        XCTAssertFalse(copied.contains("enabled="))
        XCTAssertFalse(copied.contains("修改要求："))
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertTrue(store.description.isEmpty)
        store.clearSelection()
        store.copyCurrentLocator(to: board)
        XCTAssertEqual(board.string(forType: .string), copied, "No selection must not erase the clipboard")
    }

    @MainActor func testOverlapNavigationPreservesCandidatesAndOrdinarySelectionClearsThem() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        let size = store.snapshot.pixelSize
        let mapper = CoordinateMapper(imageSize: size, canvasSize: size)
        let bounds = try XCTUnwrap(store.snapshotIndex.byID["login-text"]).bounds
        store.selectImage(at: CGPoint(x: bounds.midX, y: bounds.midY), mapper: mapper)
        let hits = store.hitCandidates
        XCTAssertGreaterThan(hits.count, 1)
        XCTAssertEqual(store.selectedNodeID, hits.first)
        store.cycleHitCandidate(1)
        XCTAssertEqual(store.selectedNodeID, hits[1])
        XCTAssertEqual(store.hitCandidates, hits)
        store.cycleHitCandidate(-1)
        XCTAssertEqual(store.selectedNodeID, hits.first)
        store.cycleHitCandidate(-1)
        XCTAssertEqual(store.selectedNodeID, hits.last)
        store.selectHitCandidate("not-a-candidate")
        XCTAssertEqual(store.selectedNodeID, hits.last)
        store.select("login-text")
        XCTAssertTrue(store.hitCandidates.isEmpty)
        XCTAssertEqual(store.selectedParentID, "login")
    }

}
