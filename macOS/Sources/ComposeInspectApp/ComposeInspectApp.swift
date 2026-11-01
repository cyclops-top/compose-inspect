import AppKit
import SwiftUI

@main
struct ComposeInspectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WorkspaceStore()
    @State private var toolchain = ToolchainSettings()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(store: store)
                .environment(toolchain)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1080, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("设置…") }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("检查") {
                Button("取消选择") { store.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(store.selectedNodeID == nil)
                Divider()
                Toggle("显示组件线框", isOn: $store.showWireframes).keyboardShortcut("b", modifiers: [.command, .shift])
                Button("适合窗口") { store.fitImage() }.keyboardShortcut("0")
                Divider()
                Button("复制全部问题") { store.copyAllIssues() }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(store.issues.isEmpty)
            }
        }
        Settings {
            ToolchainSettingsView(settings: toolchain)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private var escapeMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let window = event.window, window == NSApp.keyWindow,
                      window.title == "ComposeInspect", window.attachedSheet == nil,
                      let store = self?.store, store.selectedNodeID != nil else { return false }
                // Let the input method dismiss its composition before clearing selection.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                store.clearSelection()
                return true
            }
            return handled ? nil : event
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
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
