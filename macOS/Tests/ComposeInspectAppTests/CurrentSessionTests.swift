import AppKit
import XCTest
import SwiftUI
@testable import ComposeInspectApp
@testable import ComposeInspectCore

final class CurrentSessionTests: XCTestCase {
    @MainActor func testLiveWindowImagesSwitchWithComposeRoots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["COMPOSEINSPECT_WINDOW_SCENARIO"] else {
            throw XCTSkip("Requires the SDK sample with the dialog or popup scenario visible")
        }
        let tools = try InspectorToolchain(adb: URL(fileURLWithPath: XCTUnwrap(env["COMPOSEINSPECT_ADB"])), environment: env)
        let captured = try await SDKInspectorClient(tools: tools).capture(serial: XCTUnwrap(env["COMPOSEINSPECT_SERIAL"]),
            package: "dev.composeinspect.sample", deviceName: "Window image test", windowImages: true)
        let roots = captured.snapshot.roots
        XCTAssertEqual(roots.count, 2)
        guard roots.count == 2 else { return }
        _ = NSApplication.shared
        let store = WorkspaceStore()
        try await store.applyCapture(captured)
        let image = try XCTUnwrap(store.image)
        let pixels = try XCTUnwrap(ScreenshotPixels(XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        let marker = try XCTUnwrap(captured.snapshot.nodes.first { $0.name == (scenario == "popup" ? "PopupContent" : "DialogContent") })
        XCTAssertEqual(store.snapshotIndex.rootIDs[marker.id], roots[0].id)
        let point = CGPoint(x: marker.bounds.minX + 4, y: marker.bounds.minY + 4)
        XCTAssertEqual(pixels.hex(at: point, imageSize: image.size), scenario == "popup" ? "#FFFF00" : "#FFFFFF")
        store.windowRootID = roots[1].id
        XCTAssertNotNil(store.image)
        XCTAssertFalse(store.image === image)
    }

    @MainActor func testMergedWindowPixelsAndSelection() async throws {
        _ = NSApplication.shared
        func png(width: Int, color: NSColor) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                bytesPerRow: 0, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: width))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let size = CGSize(width: 4, height: 4)
        let front = InspectorNode(id: "front", rawID: 1, name: "Popup", bounds: CGRect(x: 1, y: 2, width: 1, height: 1))
        let back = InspectorNode(id: "back", rawID: 2, name: "Activity", bounds: CGRect(origin: .zero, size: size))
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: size, roots: [front, back])
        let capture = try CapturedSnapshot(snapshot: snapshot, imageData: Data(), windowImages: [
            front.id: .init(png: png(width: 1, color: .red), origin: front.bounds.origin),
            back.id: .init(png: png(width: 4, color: .blue), origin: .zero)
        ])
        let store = WorkspaceStore()
        try await store.applyCapture(capture)
        func color(_ x: Int, _ y: Int) throws -> String? {
            let image = try XCTUnwrap(store.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return ScreenshotPixels(image)?.hex(at: CGPoint(x: x, y: y), imageSize: size)
        }
        XCTAssertEqual(try color(1, 2), "#FF0000")
        XCTAssertEqual(try color(1, 1), "#0000FF")
        let mapper = CoordinateMapper(imageSize: size, canvasSize: size)
        store.selectImage(at: CGPoint(x: 1.5, y: 2.5), mapper: mapper)
        XCTAssertEqual(store.hitCandidates, [front.id, back.id])
        XCTAssertNil(store.windowRootID)
        store.windowRootID = back.id
        XCTAssertEqual(try color(1, 2), "#0000FF")
        XCTAssertEqual(store.visibleNodes.map(\.id), [back.id])
        XCTAssertNil(store.selectedNodeID)
        try await store.applyCapture(capture)
        XCTAssertNil(store.windowRootID)
        XCTAssertEqual(store.visibleRoots.map(\.id), [front.id, back.id])
    }

    @MainActor func testPreviewPanStopsAtEdgesAndCentersLetterboxedAxes() {
        let image = CGSize(width: 200, height: 400)
        let canvas = CGSize(width: 300, height: 400)
        let outside = CGSize(width: 2000, height: -2000)
        func clamp(_ proposed: CGSize, zoom: CGFloat) -> CGSize {
            PreviewView.clampedPan(proposed, imageSize: image, canvasSize: canvas, zoom: zoom)
        }
        let limit = clamp(outside, zoom: 2)
        XCTAssertEqual(limit, CGSize(width: 72, height: -224))
        XCTAssertEqual(clamp(CGSize(width: -2000, height: 2000), zoom: 2), CGSize(width: -72, height: 224))
        let inward = CGSize(width: limit.width - 1, height: limit.height + 1)
        XCTAssertEqual(clamp(inward, zoom: 2), inward)
        XCTAssertEqual(clamp(limit, zoom: 1), .zero)
        XCTAssertEqual(clamp(outside, zoom: 0.99), .zero)
        XCTAssertEqual(clamp(limit, zoom: 0.5), .zero)
        XCTAssertEqual(PreviewView.clampedPan(limit, imageSize: image, canvasSize: CGSize(width: 500, height: 400), zoom: 2),
                       CGSize(width: 0, height: -224))
    }

    @MainActor func testSourceFilterPromotesMatchingDescendantsAndSelectionKeepsClickedNode() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(filterDefaults: defaults)
        let originalClickable = store.onlyClickableNodes, originalCompact = store.hideInternalNodes
        defer { store.onlyClickableNodes = originalClickable; store.hideInternalNodes = originalCompact }
        store.onlyClickableNodes = false
        store.hideInternalNodes = false
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let feature = root.appendingPathComponent("feature/src")
        try fm.createDirectory(at: feature, withIntermediateDirectories: true)
        try "package dev.composeinspect.sample".write(to: feature.appendingPathComponent("Screen.kt"), atomically: true, encoding: .utf8)
        store.projectSources.open(root.path)
        defer { store.projectSources.open("") }
        let deadline = ContinuousClock.now + .seconds(8)
        while !store.projectSources.status.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let localSource = SourceAnchor(file: "Screen.kt", line: 10, packageHash: 577838147)
        let leaf = InspectorNode(id: "leaf", rawID: 3, name: "Local", bounds: .zero, source: localSource)
        let wrapper = InspectorNode(id: "wrapper", rawID: 4, name: "Wrapper", bounds: .zero, children: [leaf])
        let child = InspectorNode(id: "impl", rawID: 2, name: "Implementation", bounds: bounds,
                                  source: SourceAnchor(file: "Screen.kt", line: 1, packageHash: 123), children: [wrapper])
        let parent = InspectorNode(id: "owner", rawID: 1, name: "Action", bounds: bounds,
                                   source: SourceAnchor(file: "Screen.kt", line: 10, packageHash: 577838147), children: [child])
        let image = try captured().imageData
        let metadata = CaptureMetadata(serial: "s", packageName: "app", startedAt: Date(), finishedAt: Date(),
                                       diagnostics: [], baselineJSON: Data())
        let snapshot = InspectorSnapshot(packageName: "app", deviceName: "test", pixelSize: bounds.size,
                                         roots: [parent], captureMetadata: metadata)
        try await store.applyCapture(CapturedSnapshot(snapshot: snapshot, imageData: image))
        let mapper = CoordinateMapper(imageSize: bounds.size, canvasSize: bounds.size)
        store.select(child.id)
        XCTAssertEqual(store.selectedNodeID, child.id)
        let location = try XCTUnwrap(store.sourceLocation(for: child.id))
        XCTAssertTrue(location.inherited)
        XCTAssertEqual(location.anchor.text, "feature/src/Screen.kt:10")
        XCTAssertTrue(store.sourceSummary.contains(location.anchor.text))
        store.edit("调整子组件", for: try XCTUnwrap(store.selectedKey), revision: store.issueEditRevision)
        XCTAssertTrue(store.currentText.contains("位于 feature/src/Screen.kt:10 的 Action 内"))
        XCTAssertTrue(store.currentText.contains("工程内调用处：feature/src/Screen.kt:10"))
        XCTAssertTrue(store.currentText.contains("组件自身采集位置：Screen.kt:1"))
        XCTAssertEqual(store.batchText, "# 问题 1\n\n" + store.currentText)
        store.selectImage(at: CGPoint(x: 50, y: 50), mapper: mapper)
        XCTAssertEqual(Set(store.hitCandidates), [child.id, parent.id])
        store.select(wrapper.id)
        XCTAssertEqual(store.selectedNodeID, wrapper.id)

        store.onlySourceNodes = true
        XCTAssertNil(store.selectedNodeID)
        XCTAssertNil(store.presentationIndex.byID[wrapper.id])
        XCTAssertNotNil(store.presentationIndex.byID[child.id])
        XCTAssertEqual(store.presentationIndex.parentIDs[leaf.id], child.id)
        store.selectImage(at: CGPoint(x: 50, y: 50), mapper: mapper)
        XCTAssertEqual(Set(store.hitCandidates), [child.id, parent.id])
        store.searchesAllComponents = true
        XCTAssertNotNil(store.presentationIndex.byID[wrapper.id])
        store.searchesAllComponents = false
        store.onlySourceNodes = false
    }

    @MainActor func testEscapeExitsColorPickerBeforeClearingSelection() async throws {
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("login")
        let originalWireframes = store.showWireframes
        defer { store.showWireframes = originalWireframes }
        for show in [false, true] {
            store.showWireframes = show
            store.pickingColor = true
            store.handleEscape()
            XCTAssertFalse(store.pickingColor)
            XCTAssertEqual(store.showWireframes, show)
            XCTAssertEqual(store.selectedNodeID, "login")
        }
        store.handleEscape()
        XCTAssertNil(store.selectedNodeID)
        store.pickingColor = true
        store.handleEscape()
        XCTAssertFalse(store.pickingColor)
        XCTAssertNil(store.selectedNodeID)
    }

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
        return CapturedSnapshot(snapshot: .demo(), imageData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }

    @MainActor func testNewCaptureDiscardsIssuesParametersAndOldEditorCallbacks() async throws {
        _ = NSApplication.shared
        let store = WorkspaceStore()
        XCTAssertTrue(store.snapshot.nodes.isEmpty)
        XCTAssertTrue(store.issues.isEmpty)
        try await store.applyCapture(captured())
        store.select("login")
        let oldKey = try XCTUnwrap(store.selectedKey), oldRevision = store.issueEditRevision
        store.toggleParameter("修饰符.height", enabled: true)
        store.edit("修改按钮", for: oldKey, revision: oldRevision)
        let oldIssue = try XCTUnwrap(store.currentIssue)
        try await store.applyCapture(captured())
        XCTAssertNotEqual(store.snapshot.id, oldKey.snapshotID)
        XCTAssertNil(store.selectedKey)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertNil(store.batchText)
        store.edit("迟到的输入", for: oldKey, revision: oldRevision)
        store.selectIssue(oldIssue)
        XCTAssertNil(store.selectedKey)
        store.select("login")
        XCTAssertFalse(store.selectedParameters.contains("修饰符.height"))
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertFalse(store.canUndoClearIssues)
    }

    @MainActor func testSwitchingWindowClearsOldLocatorAndIssueSelectionReturnsToItsWindow() async throws {
        let store = WorkspaceStore()
        let sample = try captured()
        let dialog = InspectorNode(id: "dialog", rawID: 100, name: "Dialog", bounds: .zero)
        let snapshot = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: sample.snapshot.pixelSize,
                                         roots: sample.snapshot.roots + [dialog])
        try await store.applyCapture(CapturedSnapshot(snapshot: snapshot, imageData: sample.imageData))
        store.select("login")
        store.edit("修改按钮", for: try XCTUnwrap(store.selectedKey), revision: store.issueEditRevision)
        let issue = try XCTUnwrap(store.currentIssue)
        store.windowRootID = dialog.id
        XCTAssertNil(store.selectedKey)
        XCTAssertTrue(store.currentText.isEmpty)
        store.selectIssue(issue)
        XCTAssertEqual(store.selectedKey, issue.component)
        XCTAssertTrue(store.isInVisibleWindow("login"))
    }

    @MainActor func testStartingCaptureDiscardsIssuesEvenIfItFailsAndKeepsDisplayedImage() async throws {
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        store.select("screen")
        let key = try XCTUnwrap(store.selectedKey)
        let revision = store.issueEditRevision
        store.edit("上一轮的问题", for: key, revision: revision)
        store.zoom = 2
        await store.capture(settings: ToolchainSettings())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.selectedKey)
        store.edit("旧编辑回调", for: key, revision: revision)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertFalse(store.canUndoClearIssues)
        XCTAssertEqual(store.snapshot.id, key.snapshotID)
        XCTAssertEqual(store.zoom, 2)
        XCTAssertNotNil(store.image)
    }

    @MainActor func testSearchAllComponentsKeepsQueryAndRestoresFilterOnClear() async throws {
        let defaults = UserDefaults.standard
        let compact = defaults.object(forKey: "hideInternalNodes")
        let clickable = defaults.object(forKey: "onlyClickableNodes")
        defer {
            defaults.set(compact, forKey: "hideInternalNodes")
            defaults.set(clickable, forKey: "onlyClickableNodes")
        }
        let store = WorkspaceStore()
        store.onlyClickableNodes = true
        try await store.applyCapture(captured())
        store.search = "邮箱"
        XCTAssertEqual(store.searchMatches, [])
        store.searchesAllComponents = true
        XCTAssertEqual(store.search, "邮箱")
        XCTAssertTrue(store.searchMatches?.contains("email") == true)
        store.search = ""
        XCTAssertTrue(store.onlyClickableNodes)
        XCTAssertFalse(store.searchesAllComponents)
        XCTAssertNil(store.searchMatches)
        XCTAssertNil(store.presentationIndex.byID["email"])
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

    @MainActor func testUndoClearRestoresOrderAndParametersOnlyWithinCurrentCapture() async throws {
        let store = WorkspaceStore()
        try await store.applyCapture(captured())
        for id in ["login", "email"] {
            store.select(id)
            store.toggleParameter("参数-\(id)", enabled: true)
            store.edit("修改 \(id)", for: try XCTUnwrap(store.selectedKey), revision: store.issueEditRevision)
        }
        let before = store.issues
        store.clearIssues()
        XCTAssertTrue(store.canUndoClearIssues)
        let clearedRevision = store.issueEditRevision
        store.undoClearIssues()
        store.edit("", for: try XCTUnwrap(store.selectedKey), revision: clearedRevision)
        XCTAssertEqual(store.issues, before)
        XCTAssertEqual(store.selectedParameters, ["参数-email"])
        XCTAssertFalse(store.canUndoClearIssues)

        store.clearIssues()
        store.edit("新输入", for: try XCTUnwrap(store.selectedKey), revision: store.issueEditRevision)
        store.undoClearIssues()
        XCTAssertEqual(store.issues.map(\.description), ["新输入"])
        store.clearIssues()
        try await store.applyCapture(captured())
        store.undoClearIssues()
        XCTAssertFalse(store.canUndoClearIssues)
        XCTAssertTrue(store.issues.isEmpty)
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

    @MainActor func testDuplicateHitBoundsKeepSiblingsAndOtherWindows() async throws {
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        func node(_ id: String, _ children: [InspectorNode] = []) -> InspectorNode {
            InspectorNode(id: id, rawID: 1, name: id, bounds: rect, children: children)
        }
        let roots = [node("wrapper", [node("first"), node("second")]), node("otherWindow")]
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: rect.size, roots: roots)
        let store = WorkspaceStore()
        try await store.applyCapture(CapturedSnapshot(snapshot: snapshot, imageData: captured().imageData))
        let mapper = CoordinateMapper(imageSize: rect.size, canvasSize: rect.size)
        let point = CGPoint(x: 10, y: 10)
        store.skipsDuplicateHitBounds = true
        store.selectImage(at: point, mapper: mapper)
        XCTAssertEqual(store.hitCandidates, ["first", "second", "otherWindow"])
        store.selectImage(at: point, mapper: mapper)
        XCTAssertEqual(store.selectedNodeID, "second")
        store.skipsDuplicateHitBounds = false
        XCTAssertTrue(store.hitCandidates.isEmpty)
        store.selectImage(at: point, mapper: mapper)
        XCTAssertEqual(store.hitCandidates, ["first", "second", "wrapper", "otherWindow"])
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
