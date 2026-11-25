import SwiftUI
import AppKit
import ComposeInspectCore

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @Environment(ToolchainSettings.self) private var tools
    @State private var showingCaptureMethod = false

    var body: some View {
        VStack(spacing: 0) {
            PersistentSplitView(name: "workspace", horizontal: false, flexiblePane: 0, spaced: true, panes: [
                .init(minimum: 260) {
                    PersistentSplitView(name: "inspection", horizontal: true, flexiblePane: 1, spaced: true, panes: [
                        .init(minimum: 180, preferred: 240) { HierarchyView(store: store).workspacePanel() },
                        .init(minimum: 260) { PreviewView(store: store).workspacePanel() },
                        .init(minimum: 255, preferred: 300) { InspectorView(store: store).workspacePanel() }
                    ])
                },
                .init(minimum: 170, preferred: 170) { IssuesWorkspaceView(store: store) }
            ])
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .workspaceSurround))
            statusBar
        }
        .frame(minWidth: 940, minHeight: 670)
        .background(AppStyle.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 14) {
                    Menu {
                        Button("刷新设备") { refreshDevices() }
                        Divider()
                        ForEach(store.deviceSession.devices) { device in
                            Button("\(device.model) · \(device.serial)\(device.online ? "" : " · " + device.state)") {
                                Task {
                                    do { try await store.deviceSession.selectDevice(device.serial, settings: tools) }
                                    catch { store.errorMessage = error.localizedDescription }
                                }
                            }.disabled(!device.online)
                        }
                    } label: { HStack(spacing: 5) { Image(systemName: "iphone"); Text(store.deviceSession.selectedDevice?.model ?? "选择设备") } }
                    .disabled(store.isCapturing || store.deviceSession.resolvingCaptureTarget)
                    .help("使用设置中的 ADB 查找设备，离线与未授权设备不可抓取")
                    Menu {
                        Toggle("截图前自动获取前台应用", isOn: Binding(
                            get: { store.deviceSession.automaticallySelectForeground },
                            set: { store.deviceSession.automaticallySelectForeground = $0 }
                        ))
                        Divider()
                        Button("选择或输入应用包名…") { store.deviceSession.showApplications = true }
                            .disabled(store.deviceSession.automaticallySelectForeground)
                        Button("定位前台应用（刷新列表）") {
                            Task {
                                do { try await store.deviceSession.refreshPackages(settings: tools, selectForeground: true) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }.disabled(store.deviceSession.automaticallySelectForeground)
                        .help("按前台 Activity 定位主应用；其他应用的悬浮窗请通过应用列表手动选择。")
                    } label: { HStack(spacing: 5) { Image(systemName: "app"); Text(store.deviceSession.automaticallySelectForeground ? "自动获取前台应用" : (store.deviceSession.packageName.isEmpty ? "选择应用" : store.deviceSession.packageName)) } }
                    .disabled(store.isCapturing || store.deviceSession.resolvingCaptureTarget)
                }.font(.system(size: 12))
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .automatic) { Spacer() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    if let metadata = store.snapshot.captureMetadata {
                        Button { showingCaptureMethod.toggle() } label: {
                            Label("SDK 采集信息", systemImage: "bolt.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                        }
                        .help("查看当前结果的采集方式")
                        .popover(isPresented: $showingCaptureMethod) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("本次通过 SDK 获取")
                                    .font(.headline)
                                Text(metadata.packageName).font(.caption).foregroundStyle(.secondary)
                                Text("采集耗时：\(max(0, metadata.finishedAt.timeIntervalSince(metadata.startedAt)), specifier: "%.1f") 秒")
                                    .font(.caption)
                                ForEach(metadata.diagnostics.filter { $0.hasPrefix("耗时：") || $0.hasPrefix("传输：") }, id: \.self) { detail in
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(width: 380)
                        }
                    }
                    Button {
                        if store.isCapturing { store.stopCapture() }
                        else { Task { await store.capture(settings: tools) } }
                    } label: {
                        Image(systemName: store.isCapturing ? "stop.fill" : "camera.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 30)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .opacity(canCapture || store.isCapturing ? 1 : 0.4)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(store.isCapturing ? "停止获取界面" : "获取界面")
                        .help(store.isCapturing ? "停止本次获取界面" : (store.issues.isEmpty ? "获取当前界面" : "抓取新界面并清空当前 \(store.issues.count) 条问题"))
                        .disabled(!canCapture && !store.isCapturing)
                }
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { store.deviceSession.showApplications }, set: { store.deviceSession.showApplications = $0 })) {
            ApplicationPickerView(session: store.deviceSession)
        }
        .sheet(isPresented: Binding(get: { tools.managingProjects }, set: { tools.managingProjects = $0 })) {
            RecentProjectsView(settings: tools)
        }
        .sheet(item: $store.rawPresentation) { RawJSONView(presentation: $0) }
        .task {
            await tools.loadEnvironmentIfNeeded()
            await tools.checkStartupEnvironment()
            do { try await store.deviceSession.refresh(settings: tools) }
            catch { store.notice = "设备发现失败：\(error.localizedDescription)" }
        }
    }

    private var canCapture: Bool {
        store.deviceSession.selectedDevice?.online == true && !store.deviceSession.resolvingCaptureTarget &&
            (store.deviceSession.automaticallySelectForeground || !store.deviceSession.packageName.isEmpty)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if store.isCapturing {
                ProgressView().controlSize(.mini)
                Text(store.captureProgressText)
                    .lineLimit(1)
                if store.deviceSession.capturing, let start = store.deviceSession.captureStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("已耗时 \(max(0, Int(context.date.timeIntervalSince(start)))) 秒").monospacedDigit()
                    }
                }
            } else {
                Circle().fill(store.snapshot.captureMetadata == nil ? Color.secondary : Color.green).frame(width: 5, height: 5)
                Text(store.notice).lineLimit(1)
            }
            Spacer()
            if !tools.androidProjectPath.isEmpty {
                Label((tools.androidProjectPath as NSString).lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(tools.androidProjectPath)
                Divider().frame(height: 10)
            }
            Text(store.hideInternalNodes ? "\(store.presentationIndex.nodes.count) / \(store.snapshotIndex.nodes.count) 个节点" : "\(store.snapshotIndex.nodes.count) 个节点")
            if store.snapshot.captureMetadata != nil {
                Divider().frame(height: 10)
                Text(store.snapshot.capturedAt, style: .time)
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 25)
        .overlay(alignment: .top) { Divider() }
    }
    private func refreshDevices() {
        Task {
            do { try await store.deviceSession.refresh(settings: tools) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

private extension NSColor {
    static let workspaceSurround = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 0.24 : 0.89, alpha: 1)
    }
}

extension View {
    func workspacePanel() -> some View {
        let outline = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppStyle.background)
            .clipShape(outline)
            .overlay { outline.strokeBorder(AppStyle.divider.opacity(0.3), lineWidth: 0.5).allowsHitTesting(false) }
            .background(Color(nsColor: .workspaceSurround))
    }
}

private final class WorkspaceSplitView: NSSplitView {
    var bottomHeight: NSLayoutConstraint?
    var didDragDivider: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let bottomHeight else { super.mouseDown(with: event); return }
        bottomHeight.isActive = false
        super.mouseDown(with: event)
        bottomHeight.constant = arrangedSubviews[1].frame.height
        bottomHeight.isActive = true
        didDragDivider?()
    }

    override func setPosition(_ position: CGFloat, ofDividerAt index: Int) {
        if let bottomHeight, bottomHeight.isActive, index == 0 {
            bottomHeight.constant = max(0, bounds.height - position - dividerThickness)
        }
        super.setPosition(position, ofDividerAt: index)
    }

    override var dividerThickness: CGFloat { 5 }
    override func drawDivider(in rect: NSRect) {
        NSColor.workspaceSurround.setFill()
        rect.fill()
    }
}

struct PersistentSplitPane {
    let minimum: CGFloat
    let preferred: CGFloat?
    let content: AnyView
    init<Content: View>(minimum: CGFloat, preferred: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minimum = minimum; self.preferred = preferred; self.content = AnyView(content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
}

/// Own the native split views so their identities and saved divider sizes survive SwiftUI updates.
struct PersistentSplitView: NSViewControllerRepresentable {
    let name: String
    let horizontal: Bool
    let flexiblePane: Int
    var spaced = false
    let panes: [PersistentSplitPane]
    @Environment(ToolchainSettings.self) private var tools

    func makeNSViewController(context: Context) -> PersistedSplitController {
        let controller = PersistedSplitController()
        if spaced { controller.splitView = WorkspaceSplitView() }
        controller.storageKey = "layout.split." + name
        controller.horizontal = horizontal
        controller.flexiblePane = flexiblePane
        controller.configure(panes: panes, tools: tools)
        return controller
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: PersistedSplitController,
                      context: Context) -> CGSize? {
        // A divider changes the allocation inside its parent, never the size of the parent itself.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSViewController(_ controller: PersistedSplitController, context: Context) {
        controller.configure(panes: panes, tools: tools)
    }
}

final class PersistedSplitController: NSSplitViewController {
    var storageKey = ""
    var horizontal = true
    var flexiblePane = 0
    private var panes: [PersistentSplitPane] = []
    private var hosts: [NSHostingController<AnyView>] = []
    private var restored = false
    private var applying = false

    func configure(panes: [PersistentSplitPane], tools: ToolchainSettings) {
        self.panes = panes
        if hosts.isEmpty {
            splitView.isVertical = horizontal
            splitView.dividerStyle = .thin
            for (index, pane) in panes.enumerated() {
                let host = NSHostingController(rootView: AnyView(pane.content.environment(tools)))
                host.sizingOptions = []
                let item = NSSplitViewItem(viewController: host)
                item.minimumThickness = pane.minimum
                item.holdingPriority = NSLayoutConstraint.Priority(rawValue: index == flexiblePane ? 250 : 260)
                addSplitViewItem(item)
                hosts.append(host)
            }
            if !horizontal, let split = splitView as? WorkspaceSplitView,
               panes.count == 2, let preferred = panes[1].preferred {
                let saved = UserDefaults.standard.array(forKey: storageKey) as? [Double]
                let height = saved?.count == 2 ? saved?[1] : nil
                let desired = height.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? preferred
                let constraint = hosts[1].view.heightAnchor.constraint(equalToConstant: max(panes[1].minimum, desired))
                constraint.priority = .defaultHigh
                constraint.isActive = true
                split.bottomHeight = constraint
                split.didDragDivider = { [weak self] in self?.saveSizes() }
                return
            }
            NotificationCenter.default.addObserver(self, selector: #selector(dividersChanged), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        } else {
            for (index, pane) in panes.enumerated() where index < hosts.count {
                hosts[index].rootView = AnyView(pane.content.environment(tools))
                splitViewItems[index].minimumThickness = pane.minimum
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard (splitView as? WorkspaceSplitView)?.bottomHeight == nil,
              !restored, !applying, view.window != nil, splitView.bounds.width > 0, splitView.bounds.height > 0 else { return }
        applying = true
        let length = horizontal ? splitView.bounds.width : splitView.bounds.height
        let available = max(0, length - CGFloat(max(0, panes.count - 1)) * splitView.dividerThickness)
        let saved = UserDefaults.standard.array(forKey: storageKey) as? [Double]
        let sizes = SplitLayoutSizing.restored(saved: saved, preferred: panes.map { $0.preferred.map(Double.init) },
                                              minimum: panes.map { Double($0.minimum) }, available: Double(available), flexible: flexiblePane)
        var position: CGFloat = 0
        for index in 0..<max(0, sizes.count - 1) {
            position += CGFloat(sizes[index])
            splitView.setPosition(position, ofDividerAt: index)
            position += splitView.dividerThickness
        }
        splitView.layoutSubtreeIfNeeded()
        restored = true
        applying = false
        saveSizes()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.needsLayout = true
    }

    @objc private func dividersChanged(_ notification: Notification) {
        guard restored, !applying else { return }
        saveSizes()
    }
    private func saveSizes() {
        let sizes = splitView.arrangedSubviews.map { Double(horizontal ? $0.frame.width : $0.frame.height) }
        guard sizes.count == panes.count, sizes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        UserDefaults.standard.set(sizes, forKey: storageKey)
    }
}

private struct RecentProjectsView: View {
    let settings: ToolchainSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理最近工程").font(.headline)
            if settings.recentProjects.isEmpty {
                Text("暂无最近工程").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(settings.recentProjects, id: \.self) { path in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text((path as NSString).lastPathComponent)
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if path == settings.androidProjectPath {
                            Label("当前", systemImage: "checkmark").foregroundStyle(.secondary)
                        } else {
                            IconButton(title: "切换到 \((path as NSString).lastPathComponent)", systemImage: "arrow.right.circle") {
                                settings.openProject(path)
                                if settings.androidProjectPath == path { dismiss() }
                            }
                        }
                        Button { settings.forgetProject(path) } label: { Image(systemName: "minus.circle") }
                            .help("从最近记录中移除").accessibilityLabel("从最近记录中移除 " + path)
                    }.padding(.vertical, 3)
                }
            }
            HStack {
                IconButton(title: "清空最近记录", systemImage: "trash") { settings.clearRecentProjects() }.disabled(settings.recentProjects.isEmpty)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560, height: 350)
    }
}
