import ComposeInspectCore
import AppKit
import SwiftUI

struct IssuesWorkspaceView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        PersistentSplitView(name: "issues.columns", horizontal: true, flexiblePane: 2, spaced: true, panes: [
            .init(minimum: 180, preferred: 250) { issueList.workspacePanel() },
            .init(minimum: 220, preferred: 350) { aiPreview.workspacePanel() },
            .init(minimum: 230) { editor.workspacePanel() }
        ])
    }

    private var issueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("问题列表").font(.system(size: 12, weight: .medium))
                Text("\(store.issues.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { store.clearIssues() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("清空所有问题").disabled(store.issues.isEmpty)
            }.padding(.horizontal, 12).frame(height: 33)
            if store.issues.isEmpty {
                EmptyState(icon: "text.bubble", title: "还没有问题", subtitle: "")
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(store.issues.enumerated()), id: \.element.id) { index, issue in
                            CurrentIssueRow(store: store, issue: issue, index: index)
                        }
                    }.padding(.horizontal, 7).padding(.bottom, 56)
                }
            }
        }.background(AppStyle.sidebar)
            .overlay(alignment: .bottomTrailing) {
                copyButton("复制全部问题", disabled: store.issues.isEmpty) { store.copyAllIssues() }
            }
    }

    private var aiPreview: some View {
        let text = store.currentText
        return SelectableLocatorText(text: text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.15)).accessibilityLabel("AI 定位文本预览")
            .overlay(alignment: .bottomTrailing) {
                copyButton("复制 AI 定位信息（⌘⌥C）", disabled: text.isEmpty) {
                    store.copyCurrentLocator()
                }
            }
    }

    private func copyButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc").font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(AppStyle.divider.opacity(0.6)) }
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }.buttonStyle(.plain).disabled(disabled)
            .help(title).accessibilityLabel(title)
            .padding(12)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.selectedNode.map { "当前组件 · \($0.displayName)" } ?? "选择组件后输入描述")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            if store.selectedNode != nil, let key = store.selectedKey {
                let revision = store.issueEditRevision
                HStack {
                    Text(store.sourceSummary)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 5)
                    Text(store.currentIssue == nil ? "未记录" : "已自动记录")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                SectionCaption(text: "问题描述 / 期望修改")
                ComponentTextEditor(component: key, text: store.description) { text, key in
                    store.edit(text, for: key, revision: revision)
                }.id(revision)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppStyle.divider.opacity(0.6)))
                    .frame(minHeight: 60, maxHeight: .infinity)
                Text("描述可选；留空也能复制组件定位信息。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                EmptyState(icon: "cursorarrow.click", title: "先选择一个组件", subtitle: "在截图或组件树中选择后，直接输入描述。")
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct SelectableLocatorText: NSViewRepresentable {
    let text: String

    final class Coordinator { var source: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.contentInsets.bottom = 56
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.drawsBackground = false
        editor.setAccessibilityLabel("AI 定位文本预览")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let displayed = text.isEmpty ? "选中组件即可复制定位信息；也可补充修改要求。" : text
        // Preserve selection and scroll position during unrelated workspace updates.
        if context.coordinator.source != text {
            editor.textStorage?.setAttributedString(LocatorMarkdownRenderer.render(displayed))
            context.coordinator.source = text
        }
    }
}

private struct CurrentIssueRow: View {
    @Bindable var store: WorkspaceStore
    let issue: ComponentIssue
    let index: Int
    @State private var hovering = false

    var body: some View {
        let node = store.snapshots[issue.component.snapshotID]?.node(issue.component.nodeID)
        return ZStack(alignment: .trailing) {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            store.selectIssue(issue)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(node?.displayName ?? "来源组件不可用").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if !issue.parameterIDs.isEmpty { Text("\(issue.parameterIDs.count) 项").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }
                    Text(issue.excerpt).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(8).padding(.trailing, 24).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.selectedKey == issue.component ? AppStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu { Button("删除此问题", role: .destructive) { store.remove(issue) } }
        Button { store.remove(issue) } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).padding(.trailing, 10)
            .accessibilityLabel("删除问题 \(index + 1)")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
        }.background(IssueHoverRegion { hovering = $0 })
    }
}

private struct IssueHoverRegion: NSViewRepresentable {
    let changed: (Bool) -> Void
    init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
    func makeNSView(context: Context) -> IssueHoverTrackingView {
        let view = IssueHoverTrackingView()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: IssueHoverTrackingView, context: Context) { view.changed = changed }
}

private final class IssueHoverTrackingView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}
