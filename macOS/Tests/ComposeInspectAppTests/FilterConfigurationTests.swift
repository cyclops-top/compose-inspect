import AppKit
import XCTest
@testable import ComposeInspectApp
@testable import ComposeInspectCore

final class FilterConfigurationTests: XCTestCase {
    @MainActor func testRuleChangesPersistRebuildAllResultsAndPreserveIssueBindings() throws {
        _ = NSApplication.shared
        let suite = "ComposeInspect-filter-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let standard = UserDefaults.standard
        let compactPreference = standard.object(forKey: "hideInternalNodes")
        let clickablePreference = standard.object(forKey: "onlyClickableNodes")
        defer {
            defaults.removePersistentDomain(forName: suite)
            standard.set(compactPreference, forKey: "hideInternalNodes")
            standard.set(clickablePreference, forKey: "onlyClickableNodes")
        }
        let store = WorkspaceStore(filterDefaults: defaults)
        store.onlyClickableNodes = false
        store.hideInternalNodes = true
        let rootBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bounds = CGRect(x: 10, y: 10, width: 60, height: 60)
        let text = InspectorNode(id: "text", rawID: 3, name: "Text", bounds: CGRect(x: 20, y: 20, width: 20, height: 20))
        let layout = InspectorNode(id: "layout", rawID: 2, name: "example.CustomLayout", kind: "ViewNode", bounds: bounds, children: [text])
        let root = InspectorNode(id: "root", rawID: 1, name: "android.widget.FrameLayout", kind: "ViewNode", bounds: rootBounds, children: [layout])
        let snapshot = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: rootBounds.size, roots: [root])
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        try store.applyCapture(CapturedSnapshot(snapshot: snapshot,
            imageData: XCTUnwrap(bitmap.representation(using: .png, properties: [:])), aligned: true))
        store.select("layout")
        let key = try XCTUnwrap(store.selectedKey)
        store.edit("调整布局", for: key, revision: store.issueEditRevision)
        let issue = try XCTUnwrap(store.currentIssue)
        let revision = store.presentationRevision
        XCTAssertTrue(store.filterConfiguration.addViewRule("example.CustomLayout"))
        XCTAssertGreaterThan(store.presentationRevision, revision)
        XCTAssertEqual(store.presentationIndex.nodes.map(\.id), ["root", "text"])
        XCTAssertFalse(store.visibleBounds.contains(bounds))
        XCTAssertNil(store.selectedNodeID)
        let mapper = CoordinateMapper(imageSize: rootBounds.size, canvasSize: rootBounds.size)
        store.selectImage(at: CGPoint(x: 15, y: 15), mapper: mapper)
        XCTAssertFalse(store.hitCandidates.contains("layout"))
        store.selectIssue(issue)
        XCTAssertEqual(store.selectedKey, key)
        XCTAssertEqual(store.highlightedNode?.bounds, bounds)
        XCTAssertTrue(store.path.isEmpty)
        XCTAssertEqual(store.snapshotIndex.byID["layout"], layout)
        XCTAssertEqual(WorkspaceStore(filterDefaults: defaults).filterConfiguration, store.filterConfiguration)
        store.restoreDefaultFilters()
        XCTAssertEqual(store.filterConfiguration, .defaults)
        XCTAssertNotNil(store.presentationIndex.byID["layout"])
        XCTAssertTrue(store.visibleBounds.contains(bounds))
        XCTAssertEqual(store.issues.first?.component, key)
        XCTAssertEqual(WorkspaceStore(filterDefaults: defaults).filterConfiguration, .defaults)
    }
}
