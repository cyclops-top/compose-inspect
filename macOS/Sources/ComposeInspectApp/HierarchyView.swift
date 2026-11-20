import CoreText
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
            HStack(spacing: 6) {
                Toggle("精简", isOn: $store.hideInternalNodes)
                    .disabled(store.onlyClickableNodes)
                    .help(store.onlyClickableNodes ? "仅可点击模式必须开启精简" : "隐藏内部实现及 Android 宿主容器，保留子组件")
                Toggle("仅可点击", isOn: $store.onlyClickableNodes)
                    .help("保留窗口根节点及具有点击动作的组件，并自动开启精简")
                Toggle("仅有源码", isOn: $store.onlySourceNodes)
                    .help("保留窗口根节点和自身有源码位置的组件；SDK 已关联工程时，仅显示能匹配工程文件的组件")
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
            if store.searchesAllComponents {
                Button("正在搜索全部组件 · 恢复筛选") { store.searchesAllComponents = false }
                    .font(.caption)
            }
            NativeHierarchyView(store: store)
                .overlay {
                    if store.searchMatches?.isEmpty == true {
                        VStack(spacing: 8) {
                            Text("未找到“\(store.search)”").lineLimit(3)
                            if (store.hideInternalNodes || store.onlySourceNodes) && !store.searchesAllComponents {
                                Button("在全部组件中搜索") { store.searchesAllComponents = true }
                            }
                        }.font(.callout).padding().multilineTextAlignment(.center)
                    }
                }
            HStack(spacing: 5) {
                Text("数字表示层级 · 根节点为 0").font(.system(size: 10))
                Spacer()
            }.foregroundStyle(.tertiary).padding(12)
        }.background(AppStyle.sidebar)
            .sheet(isPresented: $showingFilterConfiguration) { NodeFilterSettingsView(store: store) }
    }
}

/// Native row selection happens on the first mouse-down. Double-action only changes expansion,
/// so single selection is never delayed by waiting for a possible double-click gesture.
struct NativeHierarchyView: NSViewRepresentable {
    let store: WorkspaceStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = CompactHierarchyOutlineView()
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
        scroll.usesPredominantAxisScrolling = false
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
        var children: [Item] = []
        var depth: Int
        let hierarchyDepth: Int
        var continuesParentChain = false
        let textWidth: CGFloat
        init(node: InspectorNode, depth: Int) {
            self.node = node
            self.depth = depth
            self.hierarchyDepth = depth
            let title = node.shortName + (node.label.map { " " + $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") } ?? "")
            textWidth = (title as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).width
                + max(0, (String(depth) as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)]).width + 4 - 14)
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var store: WorkspaceStore
        weak var outline: NSOutlineView?
        private var snapshotID: UUID?
        private var query = ""
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
            let treeChanged = snapshotID != store.snapshot.id || presentationRevision != store.presentationRevision
            let rebuilt = treeChanged || query != store.search
            let issues = Set(store.issues.filter { $0.component.snapshotID == store.snapshot.id }.map(\.component.nodeID))
            let issuesChanged = issues != issueNodeIDs
            issueNodeIDs = issues
            if rebuilt {
                snapshotID = store.snapshot.id
                query = store.search
                presentationRevision = store.presentationRevision
                collapsedSearchItems.removeAll()
                let index = store.presentationIndex
                if treeChanged {
                    // Item identity and text measurements survive search edits.
                    items = Dictionary(uniqueKeysWithValues: index.nodes.map {
                        ($0.id, Item(node: $0, depth: index.depths[$0.id] ?? 0))
                    })
                    // Keep display depths stable while searching; only real branches indent.
                    var pending = index.roots.compactMap { items[$0.id] }
                    for root in pending { root.depth = 0 }
                    while let parent = pending.popLast() {
                        let singleChild = parent.node.children.count == 1
                        for node in parent.node.children {
                            guard let child = items[node.id] else { continue }
                            child.depth = parent.depth + (singleChild ? 0 : 1)
                            child.continuesParentChain = singleChild
                            pending.append(child)
                        }
                    }
                }
                let visibleIDs = store.searchMatches
                for item in items.values {
                    item.children = item.node.children.compactMap {
                        visibleIDs?.contains($0.id) == false ? nil : items[$0.id]
                    }
                }
                roots = index.roots.compactMap { visibleIDs?.contains($0.id) == false ? nil : items[$0.id] }
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
                   let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? HierarchyNodeCellView {
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
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? HierarchyNodeCellView {
                cell.layoutSubtreeIfNeeded()
                left = cell.depthLabel.convert(cell.depthLabel.bounds, to: outline).minX
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
            outline.needsLayout = true
            outline.needsDisplay = true
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
            let cell: HierarchyNodeCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? HierarchyNodeCellView { cell = reused }
            else {
                cell = HierarchyNodeCellView()
                cell.identifier = identifier
                let depthLabel = cell.depthLabel
                depthLabel.translatesAutoresizingMaskIntoConstraints = false
                depthLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
                depthLabel.textColor = .tertiaryLabelColor
                depthLabel.alignment = .center
                depthLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.usesSingleLineMode = true
                label.cell?.wraps = false
                label.cell?.isScrollable = true
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(depthLabel); cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    depthLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    cell.depthWidth,
                    depthLabel.heightAnchor.constraint(equalToConstant: 14),
                    depthLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.leadingAnchor.constraint(equalTo: depthLabel.trailingAnchor, constant: 5),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            configure(cell, for: item)
            return cell
        }

        private func configure(_ cell: HierarchyNodeCellView, for item: Item) {
            let node = item.node
            cell.depthLabel.stringValue = String(item.hierarchyDepth)
            cell.depthWidth.constant = max(14, ceil(cell.depthLabel.intrinsicContentSize.width) + 4)
            cell.depthLabel.toolTip = "层级 \(item.hierarchyDepth)"
            cell.depthLabel.setAccessibilityLabel("层级 \(item.hierarchyDepth)")
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
            cell.setAccessibilityLabel(node.displayName + "，层级 \(item.hierarchyDepth)")
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

private final class HierarchyDepthLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        // Center the visible digit outlines rather than NSTextField's baseline box.
        if let context = NSGraphicsContext.current?.cgContext {
            let text = NSAttributedString(string: stringValue, attributes: [
                .font: font ?? NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: textColor ?? NSColor.tertiaryLabelColor,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.saveGState()
            if isFlipped {
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
            }
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: bounds.midX - inkBounds.midX,
                                           y: bounds.midY - inkBounds.midY)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        NSColor.tertiaryLabelColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()
    }
}

private final class HierarchyNodeCellView: NSTableCellView {
    let depthLabel = HierarchyDepthLabel(labelWithString: "")
    lazy var depthWidth = depthLabel.widthAnchor.constraint(equalToConstant: 14)
}

/// Preserve the native hierarchy for navigation and accessibility, but lay out single-child
/// chains in one column. Disclosure hit targets and cell contents use the same offset.
final class CompactHierarchyOutlineView: NSOutlineView {
    @MainActor private final class DisclosureImages: NSObject {
        let normal: NSImage?
        let alternate: NSImage?
        init(_ button: NSButton) {
            normal = button.image
            alternate = button.alternateImage
        }
    }
    private let disclosureImages = NSMapTable<NSButton, DisclosureImages>.weakToStrongObjects()
    private lazy var chainDot: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 4.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    override func layout() {
        super.layout()
        enumerateAvailableRowViews { rowView, row in
            guard let item = self.item(atRow: row) as? NativeHierarchyView.Item else { return }
            let showsDot = item.node.children.count == 1 && self.isItemExpanded(item)
            var pending = rowView.subviews
            while let view = pending.popLast() {
                pending.append(contentsOf: view.subviews)
                guard let button = view as? NSButton,
                      [NSOutlineView.disclosureButtonIdentifier, NSOutlineView.showHideButtonIdentifier].contains(button.identifier) else { continue }
                let original: DisclosureImages
                if let saved = self.disclosureImages.object(forKey: button) { original = saved }
                else {
                    original = DisclosureImages(button)
                    self.disclosureImages.setObject(original, forKey: button)
                }
                // Keep AppKit's button, action, hit area and accessibility behavior intact.
                button.image = showsDot ? self.chainDot : original.normal
                button.alternateImage = showsDot ? self.chainDot : original.alternate
            }
        }
    }

    private func indentationAdjustment(at row: Int) -> CGFloat {
        guard row >= 0, let item = item(atRow: row) as? NativeHierarchyView.Item else { return 0 }
        return CGFloat(level(forItem: item) - item.depth) * indentationPerLevel
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if column == outlineTableColumn.flatMap({ tableColumns.firstIndex(of: $0) }) {
            let adjustment = indentationAdjustment(at: row)
            frame.origin.x -= adjustment
            frame.size.width += adjustment
        }
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        if !frame.isEmpty { frame.origin.x -= indentationAdjustment(at: row) }
        return frame
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let visibleRows = rows(in: dirtyRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            guard let item = item(atRow: row) as? NativeHierarchyView.Item else { continue }
            let rowFrame = rect(ofRow: row)
            // The incoming segment uses the parent's disclosure position, including for leaves.
            if item.continuesParentChain, row > 0 {
                let parentDisclosure = frameOfOutlineCell(atRow: row - 1)
                if !parentDisclosure.isEmpty {
                    let x = parentDisclosure.midX
                    lines.move(to: NSPoint(x: x, y: rowFrame.minY - intercellSpacing.height))
                    lines.line(to: NSPoint(x: x, y: rowFrame.midY - 7))
                }
            }
            if item.node.children.count == 1, !item.children.isEmpty, isItemExpanded(item) {
                let disclosure = frameOfOutlineCell(atRow: row)
                if !disclosure.isEmpty {
                    lines.move(to: NSPoint(x: disclosure.midX, y: rowFrame.midY + 7))
                    lines.line(to: NSPoint(x: disclosure.midX, y: rowFrame.maxY))
                }
            }
        }
        lines.stroke()
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
