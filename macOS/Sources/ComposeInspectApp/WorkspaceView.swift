import SwiftUI
import AppKit
import ComposeInspectCore

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @Environment(ToolchainSettings.self) private var tools

    var body: some View {
        VStack(spacing: 0) {
            PersistentSplitView(name: "workspace", horizontal: false, flexiblePane: 0, panes: [
                .init(minimum: 260) {
                    PersistentSplitView(name: "inspection", horizontal: true, flexiblePane: 1, panes: [
                        .init(minimum: 180, preferred: 240) { HierarchyView(store: store) },
                        .init(minimum: 260) { PreviewView(store: store) },
                        .init(minimum: 255, preferred: 300) { InspectorView(store: store) }
                    ])
                },
                .init(minimum: 170, preferred: 230) { IssuesWorkspaceView(store: store) }
            ])
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
                    .disabled(store.deviceSession.capturing)
                    .help("使用设置中的 ADB 查找设备，离线与未授权设备不可抓取")
                    Menu {
                        Button("选择或输入应用包名…") { store.deviceSession.showApplications = true }
                        Button("刷新应用列表与前台应用") {
                            Task {
                                do { try await store.deviceSession.refreshPackages(settings: tools) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                    } label: { HStack(spacing: 5) { Image(systemName: "app"); Text(store.deviceSession.packageName.isEmpty ? "选择应用" : store.deviceSession.packageName) } }
                    .disabled(store.deviceSession.capturing)
                }.font(.system(size: 12))
            }
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.deviceSession.capturing {
                    ProgressView().controlSize(.small)
                    Button("取消") { store.deviceSession.cancel() }
                } else {
                    Button { Task { await store.capture(settings: tools) } } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 30)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .opacity(canCapture ? 1 : 0.4)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("获取界面")
                        .disabled(!canCapture)
                }
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { store.deviceSession.showApplications }, set: { store.deviceSession.showApplications = $0 })) {
            ApplicationPickerView(session: store.deviceSession)
        }
        .sheet(item: $store.rawPresentation) { RawJSONView(presentation: $0) }
        .onChange(of: [store.deviceSession.selectedSerial ?? "", store.deviceSession.packageName]) { _, _ in store.targetChanged() }
        .task {
            await tools.loadEnvironmentIfNeeded()
            do { try await store.deviceSession.refresh(settings: tools) }
            catch { store.notice = "设备发现失败：\(error.localizedDescription)" }
        }
    }

    private var canCapture: Bool {
        store.deviceSession.selectedDevice?.online == true && !store.deviceSession.packageName.isEmpty
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(store.snapshot.captureMetadata == nil ? Color.secondary : Color.green).frame(width: 5, height: 5)
            Text(store.deviceSession.capturing ? store.deviceSession.progress : store.notice).lineLimit(1)
            Spacer()
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

struct PersistentSplitPane {
    let minimum: CGFloat
    let preferred: CGFloat?
    let content: AnyView
    init<Content: View>(minimum: CGFloat, preferred: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minimum = minimum; self.preferred = preferred; self.content = AnyView(content())
    }
}

/// Own the native split views so their identities and saved divider sizes survive SwiftUI updates.
struct PersistentSplitView: NSViewControllerRepresentable {
    let name: String
    let horizontal: Bool
    let flexiblePane: Int
    let panes: [PersistentSplitPane]
    @Environment(ToolchainSettings.self) private var tools

    func makeNSViewController(context: Context) -> PersistedSplitController {
        let controller = PersistedSplitController()
        controller.storageKey = "layout.split." + name
        controller.horizontal = horizontal
        controller.flexiblePane = flexiblePane
        controller.configure(panes: panes, tools: tools)
        return controller
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
                let item = NSSplitViewItem(viewController: host)
                item.minimumThickness = pane.minimum
                item.holdingPriority = NSLayoutConstraint.Priority(rawValue: index == flexiblePane ? 250 : 260)
                addSplitViewItem(item)
                hosts.append(host)
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
        guard !restored, !applying, view.window != nil, splitView.bounds.width > 0, splitView.bounds.height > 0 else { return }
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
