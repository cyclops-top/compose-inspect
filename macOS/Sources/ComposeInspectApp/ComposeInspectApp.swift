import AppKit
import SwiftUI

@main
struct ComposeInspectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WorkspaceStore()
    @State private var toolchain = ToolchainSettings()

    var body: some Scene {
        Window("CompScope", id: "workspace") {
            WorkspaceView(store: store)
                .environment(toolchain)
                .onAppear { appDelegate.store = store }
                .onChange(of: toolchain.androidProjectPath, initial: true) { _, path in store.projectSources.open(path) }
                .sheet(isPresented: $toolchain.showEnvironmentSetup) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("抓取环境需要配置", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text("请选择 Android SDK 中的 adb 可执行文件。")
                            .font(.callout)
                        ToolchainSettingsView(settings: toolchain, store: store)
                        HStack {
                            Spacer()
                            Button("稍后配置") { toolchain.showEnvironmentSetup = false }
                            Button("完成") { toolchain.showEnvironmentSetup = false }
                                .disabled(toolchain.adbResult?.succeeded != true || toolchain.checkingADB)
                        }
                    }.padding(20)
                }
        }
        .defaultSize(width: 1080, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("设置…") }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("打开 Android 工程…") { toolchain.chooseAndroidProject() }
                    .keyboardShortcut("o")
                Menu("打开最近工程") {
                    ForEach(toolchain.recentProjects, id: \.self) { path in
                        Button {
                            toolchain.openProject(path)
                        } label: {
                            let name = (path as NSString).lastPathComponent
                            let duplicate = toolchain.recentProjects.contains {
                                $0 != path && ($0 as NSString).lastPathComponent == name
                            }
                            let title = duplicate ? (path as NSString).abbreviatingWithTildeInPath : name
                            if path == toolchain.androidProjectPath { Label(title, systemImage: "checkmark") }
                            else { Text(title) }
                        }
                    }
                    Divider()
                    Button("管理最近工程…") { toolchain.managingProjects = true }
                }
                Button("关闭当前工程") { toolchain.closeProject() }
                    .disabled(toolchain.androidProjectPath.isEmpty)
            }
            CommandMenu("检查") {
                Button(store.pickingColor ? "退出取色" : "取消选择") { store.handleEscape() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(!store.pickingColor && store.selectedNodeID == nil)
                Divider()
                Toggle("显示组件线框", isOn: $store.showWireframes).keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(store.pickingColor)
                Button("适合窗口") { store.fitImage() }.keyboardShortcut("0")
                Divider()
                Button("复制当前组件") { store.copyCurrentLocator() }
                    .keyboardShortcut("c", modifiers: [.command, .option]).disabled(store.selectedNodeID == nil)
                Button("选择父组件") { if let id = store.selectedParentID { store.select(id) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(store.selectedParentID == nil)
                Button("上一个重叠组件") { store.cycleHitCandidate(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .option]).disabled(store.hitCandidates.count < 2)
                Button("下一个重叠组件") { store.cycleHitCandidate(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option]).disabled(store.hitCandidates.count < 2)
                Divider()
                Button("复制全部问题") { store.copyAllIssues() }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(store.issues.isEmpty)
            }
        }
        Settings {
            ToolchainSettingsView(settings: toolchain, store: store)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private var escapeMonitor: Any?
    private var titleBarMonitor: Any?
    private var previousFrame: NSRect?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        titleBarMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleTitleBarDoubleClick(event) ?? false
            }
            return handled ? nil : event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let window = event.window, window == NSApp.keyWindow,
                      window.title == "CompScope", window.attachedSheet == nil,
                      let store = self?.store, store.pickingColor || store.selectedNodeID != nil else { return false }
                // Let the input method dismiss its composition before clearing selection.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                if !event.isARepeat { store.handleEscape() }
                return true
            }
            return handled ? nil : event
        }
    }
    func handleTitleBarDoubleClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2, let window = event.window, window.title == "CompScope",
              window.attachedSheet == nil, !window.styleMask.contains(.fullScreen),
              let screen = window.screen else { return false }
        let point = event.locationInWindow
        guard point.y >= window.contentLayoutRect.maxY,
              point.y < window.frame.height else { return false }

        // Leave the standard window buttons and the app's toolbar controls to AppKit.
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let controls = buttons.compactMap { window.standardWindowButton($0) }
        let items = (window.toolbar?.visibleItems ?? []).filter {
            $0.itemIdentifier != .space && $0.itemIdentifier != .flexibleSpace
        }.compactMap(\.view)
        guard !(controls + items).contains(where: { view in
            view.convert(view.bounds, to: nil).contains(point)
        }) else { return false }
        let available = screen.visibleFrame
        if let previousFrame, window.frame.equalTo(available) {
            window.setFrame(previousFrame, display: true)
            self.previousFrame = nil
        } else {
            guard !window.frame.equalTo(available) else { return false }
            previousFrame = window.frame
            window.setFrame(available, display: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let titleBarMonitor { NSEvent.removeMonitor(titleBarMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum AppStyle {
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let divider = Color(nsColor: .separatorColor)
    static let selected = Color.accentColor.opacity(0.12)
}

struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .help(title)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 23, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
