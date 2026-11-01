import ComposeInspectCore
import AppKit
import SwiftUI

struct HierarchyView: View {
    @Bindable var store: WorkspaceStore
    @State private var showingFilterConfiguration = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionCaption(text: "组件树")
                Spacer()
            }.padding(.horizontal, 14).frame(height: 35)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找组件", text: $store.search).textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("清除搜索")
                }
            }.font(.system(size: 12)).padding(7)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppStyle.divider.opacity(0.5)))
                .padding(.horizontal, 10).padding(.bottom, 8)
            HStack(spacing: 12) {
                Toggle("精简", isOn: $store.hideInternalNodes)
                    .disabled(store.onlyClickableNodes)
                    .help(store.onlyClickableNodes ? "仅可点击模式必须开启精简" : "隐藏内部实现及 Android 宿主容器，保留子组件")
                Toggle("仅可点击", isOn: $store.onlyClickableNodes)
                    .help("保留窗口根节点及具有点击动作的组件，并自动开启精简")
                Spacer(minLength: 0)
                Button { showingFilterConfiguration = true } label: {
                    Image(systemName: "gearshape")
                }.buttonStyle(.plain).help("配置精简规则").accessibilityLabel("配置精简规则")
            }.toggleStyle(.checkbox).font(.system(size: 11))
                .padding(.horizontal, 10).padding(.bottom, 12)
            if store.snapshot.roots.count > 1 {
                Text("多个窗口 · 在预览中选择窗口")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6)
            }
            NativeHierarchyView(store: store)
            HStack(spacing: 5) {
                Text("C").font(.system(size: 9, weight: .semibold, design: .monospaced))
                Text("Compose").font(.system(size: 10))
                Text("·  V View").font(.system(size: 10))
                Spacer()
            }.foregroundStyle(.tertiary).padding(12)
        }.background(AppStyle.sidebar)
            .sheet(isPresented: $showingFilterConfiguration) { NodeFilterSettingsView(store: store) }
    }
}

/// Native row selection happens on the first mouse-down. Double-action only changes expansion,
/// so single selection is never delayed by waiting for a possible double-click gesture.
private struct NativeHierarchyView: NSViewRepresentable {
    let store: WorkspaceStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("component"))
        column.resizingMask = []
        column.maxWidth = .greatestFiniteMagnitude
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 28
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.setAccessibilityLabel("组件树，单击选择，双击展开或收起")
        let scroll = HierarchyScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.usesPredominantAxisScrolling = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.synchronize(store: store)
    }

    @MainActor final class Item: NSObject {
        let node: InspectorNode
        let children: [Item]
        let depth: Int
        let textWidth: CGFloat
        init(node: InspectorNode, visibleIDs: Set<String>?, depth: Int = 0) {
            self.node = node
            self.depth = depth
            let title = node.shortName + (node.label.map { " " + $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") } ?? "")
            textWidth = (title as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).width
            children = node.children.filter { visibleIDs?.contains($0.id) ?? true }.map { Item(node: $0, visibleIDs: visibleIDs, depth: depth + 1) }
        }
        var flattened: [Item] { [self] + children.flatMap(\.flattened) }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var store: WorkspaceStore
        weak var outline: NSOutlineView?
        private var snapshotID: UUID?
        private var query = ""
        private var hidingInternals = true
        private var onlyClickable = false
        private var presentationRevision: UInt?
        private var roots: [Item] = []
        private var items: [String: Item] = [:]
        private var synchronizing = false
        private var collapsedSearchItems: Set<String> = []
        private var expandedIDs: Set<String> = []
        private var issueNodeIDs: Set<String> = []
        private var selectionRevision: UInt?

        init(store: WorkspaceStore) { self.store = store }

        func synchronize(store: WorkspaceStore) {
            self.store = store
            guard let outline else { return }
            synchronizing = true
            defer { synchronizing = false }
            let rebuilt = snapshotID != store.snapshot.id || query != store.search || hidingInternals != store.hideInternalNodes || onlyClickable != store.onlyClickableNodes || presentationRevision != store.presentationRevision
            let issues = Set(store.issues.filter { $0.component.snapshotID == store.snapshot.id }.map(\.component.nodeID))
            let issuesChanged = issues != issueNodeIDs
            issueNodeIDs = issues
            if rebuilt {
                snapshotID = store.snapshot.id
                query = store.search
                hidingInternals = store.hideInternalNodes
                onlyClickable = store.onlyClickableNodes
                presentationRevision = store.presentationRevision
                collapsedSearchItems.removeAll()
                let visibleIDs = query.isEmpty ? nil : store.presentationIndex.matchingIDs(query)
                roots = store.presentationIndex.roots.filter { visibleIDs?.contains($0.id) ?? true }
                    .map { Item(node: $0, visibleIDs: visibleIDs) }
                items = Dictionary(uniqueKeysWithValues: roots.flatMap(\.flattened).map { ($0.node.id, $0) })
                outline.reloadData()
            }
            let selectionChanged = selectionRevision != store.selectionRevision
            if selectionChanged && !query.isEmpty {
                collapsedSearchItems.subtract(store.path.map(\.id))
            }
            if rebuilt || expandedIDs != store.expandedNodes || selectionChanged {
                for root in roots { synchronizeExpansion(root, outline: outline) }
                expandedIDs = store.expandedNodes
                updateContentWidth()
            }
            let selectedItem = store.selectedNodeID.flatMap { items[$0] }
            let row = selectedItem.map { outline.row(forItem: $0) } ?? -1
            let reveal = rebuilt || selectionChanged
            selectionRevision = store.selectionRevision
            let viewport = outline.enclosingScrollView?.contentView.bounds
            if row >= 0 {
                if outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                if reveal, let item = selectedItem, let viewport { revealSelection(item, row: row, viewport: viewport) }
            } else if store.selectedNodeID == nil, outline.selectedRow != -1 { outline.deselectAll(nil) }
            // Refresh row labels/issue indicators without destroying item identity or expansion state.
            guard issuesChanged && !rebuilt else { return }
            let rows = outline.rows(in: outline.visibleRect)
            for row in rows.location..<(rows.location + rows.length) {
                if let item = outline.item(atRow: row) as? Item,
                   let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                    configure(cell, for: item)
                }
            }
        }

        private func revealSelection(_ item: Item, row: Int, viewport: CGRect) {
            guard let outline, let scroll = outline.enclosingScrollView else { return }
            outline.layoutSubtreeIfNeeded()
            let rowRect = outline.rect(ofRow: row)
            var left = CGFloat(item.depth) * outline.indentationPerLevel + 16
            var right = left + 24 + item.textWidth
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView {
                cell.layoutSubtreeIfNeeded()
                if let icon = cell.imageView { left = icon.convert(icon.bounds, to: outline).minX }
                if let label = cell.textField {
                    right = label.convert(label.bounds, to: outline).minX + label.attributedStringValue.size().width + 4
                }
            }
            let disclosure = outline.frameOfOutlineCell(atRow: row)
            if !disclosure.isEmpty { left = min(left, disclosure.minX) }
            let target = CGRect(x: left, y: rowRect.minY, width: max(0, right - left), height: rowRect.height)
            let visible = CGRect(origin: viewport.origin, size: scroll.contentView.bounds.size)
            let origin = TreeSelectionViewport.origin(revealing: target, in: visible, documentSize: outline.bounds.size)
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func synchronizeExpansion(_ item: Item, outline: NSOutlineView) {
            guard !item.children.isEmpty else { return }
            let expanded = query.isEmpty ? store.expandedNodes.contains(item.node.id) : !collapsedSearchItems.contains(item.node.id)
            if expanded {
                if !outline.isItemExpanded(item) { outline.expandItem(item) }
                for child in item.children { synchronizeExpansion(child, outline: outline) }
            } else if outline.isItemExpanded(item) { outline.collapseItem(item) }
        }

        private func updateContentWidth() {
            guard let outline, let scroll = outline.enclosingScrollView as? HierarchyScrollView else { return }
            var width: CGFloat = 0
            for row in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: row) as? Item else { continue }
                width = max(width, item.textWidth + CGFloat(item.depth) * outline.indentationPerLevel + 72)
            }
            scroll.contentWidth = ceil(width)
            scroll.tile()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Item)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !(item as! Item).children.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let item = item as! Item
            let identifier = NSUserInterfaceItemIdentifier("nodeCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let icon = NSImageView()
                let label = NSTextField(labelWithString: "")
                icon.translatesAutoresizingMaskIntoConstraints = false
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.usesSingleLineMode = true
                label.cell?.wraps = false
                label.cell?.isScrollable = true
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(icon); cell.addSubview(label)
                cell.imageView = icon; cell.textField = label
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            configure(cell, for: item)
            return cell
        }

        private func configure(_ cell: NSTableCellView, for item: Item) {
            let node = item.node
            cell.imageView?.image = NSImage(systemSymbolName: node.kind == "ViewNode" ? "v.square" : "c.square",
                                           accessibilityDescription: node.kind == "ViewNode" ? "View" : "Compose")
            cell.imageView?.contentTintColor = .secondaryLabelColor
            let text = NSMutableAttributedString(string: node.shortName, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            if let label = node.label {
                let singleLine = label.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                text.append(NSAttributedString(string: " \(singleLine)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            if issueNodeIDs.contains(node.id) {
                text.append(NSAttributedString(string: "  •", attributes: [.foregroundColor: NSColor.controlAccentColor]))
            }
            cell.textField?.attributedStringValue = text
            cell.toolTip = node.displayName + (node.source.map { " · \($0.text)" } ?? "")
            cell.setAccessibilityLabel(node.displayName)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let outline, outline.selectedRow >= 0,
                  let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
            store.select(item.node.id)
            outline.window?.makeFirstResponder(outline)
        }

        @objc func doubleClick(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? Item,
                  !item.children.isEmpty else { return }
            if sender.isItemExpanded(item) { sender.collapseItem(item) } else { sender.expandItem(item) }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !synchronizing, let item = notification.userInfo?["NSObject"] as? Item else { return }
            store.expandedNodes.insert(item.node.id)
            collapsedSearchItems.remove(item.node.id)
            updateContentWidth()
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !synchronizing, let item = notification.userInfo?["NSObject"] as? Item else { return }
            store.expandedNodes.remove(item.node.id)
            if !query.isEmpty { collapsedSearchItems.insert(item.node.id) }
            updateContentWidth()
        }
    }
}

/// Keep the document as wide as the longest indented row, while filling a wider viewport.
private final class HierarchyScrollView: NSScrollView {
    var contentWidth: CGFloat = 0
    override func tile() {
        super.tile()
        guard let outline = documentView as? NSOutlineView, let column = outline.tableColumns.first else { return }
        let width = max(contentWidth, contentSize.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }
}
