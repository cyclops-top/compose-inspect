import AppKit
import XCTest
@testable import ComposeInspectApp
import ComposeInspectCore

@MainActor
final class HierarchyDisclosureTests: XCTestCase {
    @MainActor private final class Source: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let root: NativeHierarchyView.Item
        override init() {
            let leaf = InspectorNode(id: "leaf", rawID: 2, name: "Leaf", bounds: .zero)
            root = NativeHierarchyView.Item(node: InspectorNode(id: "root", rawID: 1, name: "Root",
                bounds: .zero, children: [leaf]), depth: 0)
            root.children = [NativeHierarchyView.Item(node: leaf, depth: 0)]
            super.init()
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? NativeHierarchyView.Item)?.children.count ?? 1
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? NativeHierarchyView.Item)?.children[index] ?? root
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !(item as! NativeHierarchyView.Item).children.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTextField(labelWithString: (item as! NativeHierarchyView.Item).node.name)
        }
    }

    func testSingleChildDisclosureChangesToDotAndRestoresAfterCollapse() async throws {
        _ = NSApplication.shared
        let source = Source()
        let outline = CompactHierarchyOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.style = .sourceList
        outline.dataSource = source
        outline.delegate = source
        let window = NSWindow(contentRect: outline.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = outline
        defer { window.contentView = nil }
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()
        func disclosure() throws -> NSButton {
            let row = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
            var pending = row.subviews
            while let view = pending.popLast() {
                pending.append(contentsOf: view.subviews)
                if let button = view as? NSButton,
                   [NSOutlineView.disclosureButtonIdentifier, NSOutlineView.showHideButtonIdentifier].contains(button.identifier) {
                    return button
                }
            }
            throw NSError(domain: "Missing native disclosure button", code: 1)
        }
        let original = try disclosure().image
        outline.expandItem(source.root)
        outline.needsLayout = true
        outline.layoutSubtreeIfNeeded()
        let expanded = try disclosure()
        XCTAssertNotNil(expanded.image)
        XCTAssertFalse(expanded.image === original)
        XCTAssertEqual(expanded.image?.size, NSSize(width: 12, height: 12))
        // Exercise the native action retained by the visual replacement.
        expanded.performClick(nil)
        XCTAssertFalse(outline.isItemExpanded(source.root))
        outline.needsLayout = true
        outline.layoutSubtreeIfNeeded()
        XCTAssertTrue(try disclosure().image === original)
    }
}
