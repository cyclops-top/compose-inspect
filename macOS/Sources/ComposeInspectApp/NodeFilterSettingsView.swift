import ComposeInspectCore
import SwiftUI

struct NodeFilterSettingsView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("精简规则").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("勾选后隐藏对应节点，其子节点提升显示。窗口根节点始终保留；仅在开启“精简”时生效。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !store.hideInternalNodes {
                Text("当前未开启精简，规则已保存；开启精简后生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Text 内部的 BasicText", isOn: $store.filterConfiguration.hideTextImplementation)
                Toggle("已知 Layout / ReusableComposeNode 实现", isOn: $store.filterConfiguration.hideLayoutImplementation)
                Toggle("无独立内容的组合包装（含单内容槽）", isOn: $store.filterConfiguration.hideCompositionWrappers)
                Toggle("Compose 宿主", isOn: $store.filterConfiguration.hideComposeHosts)
            }
            IconButton(title: "恢复默认规则", systemImage: "arrow.counterclockwise") { store.restoreDefaultFilters() }
                .disabled(store.filterConfiguration == .defaults)
        }
        .padding(18)
        .frame(width: 420)
    }
}
