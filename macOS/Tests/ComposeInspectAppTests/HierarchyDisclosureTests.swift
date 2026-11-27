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
            root.children = [NativeHierarchyView.Item(node: leaf, depth: 1)]
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
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = HierarchyRowView()
            row.outline = outlineView
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTextField(labelWithString: (item as! NativeHierarchyView.Item).node.name)
        }
    }

    func testSingleChildIndentsAndParentCollapsesWithNativeDisclosure() async throws {
        _ = NSApplication.shared
        let source = Source()
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
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
        outline.expandItem(source.root)
        outline.needsLayout = true
        outline.layoutSubtreeIfNeeded()
        let parent = outline.frameOfCell(atColumn: 0, row: 0)
        let child = outline.frameOfCell(atColumn: 0, row: 1)
        XCTAssertEqual(child.minX - parent.minX, outline.indentationPerLevel, accuracy: 0.5)
        func branchRow(_ index: Int) throws -> HierarchyRowView {
            try XCTUnwrap(outline.rowView(atRow: index, makeIfNecessary: true) as? HierarchyRowView)
        }
        let lastRow = try branchRow(1)
        XCTAssertEqual(lastRow.branchPath().bounds.height, lastRow.bounds.height / 2, accuracy: 0.5)

        // A collapsed branch with a following sibling keeps its guide through the entire row.
        let sibling = NativeHierarchyView.Item(node: InspectorNode(id: "other", rawID: 3, name: "Other", bounds: .zero), depth: 1)
        source.root.children.insert(sibling, at: 0)
        sibling.children = [NativeHierarchyView.Item(node: InspectorNode(id: "nested", rawID: 4, name: "Nested", bounds: .zero), depth: 2)]
        outline.reloadItem(source.root, reloadChildren: true)
        outline.layoutSubtreeIfNeeded()
        let firstRow = try branchRow(1)
        XCTAssertEqual(firstRow.branchPath().bounds.height, firstRow.bounds.height, accuracy: 0.5)
        let siblingX = outline.frameOfCell(atColumn: 0, row: 2).minX
        outline.expandItem(sibling)
        outline.layoutSubtreeIfNeeded()
        let nested = try branchRow(2)
        XCTAssertEqual(nested.branchPath().elementCount, 6) // elbow plus the ancestor's continuing guide
        outline.collapseItem(sibling)
        XCTAssertEqual(outline.frameOfCell(atColumn: 0, row: 2).minX, siblingX, accuracy: 0.5)
        try disclosure().performClick(nil)
        XCTAssertFalse(outline.isItemExpanded(source.root))
        outline.needsLayout = true
        outline.layoutSubtreeIfNeeded()
        XCTAssertEqual(outline.numberOfRows, 1)
    }
}
