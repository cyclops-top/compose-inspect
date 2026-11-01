import ComposeInspectCore
import SwiftUI

struct NodeFilterSettingsView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var className = ""
    @State private var validationMessage = ""

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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Compose 内部实现") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Text 内部的 BasicText", isOn: $store.filterConfiguration.hideTextImplementation)
                            Toggle("已知 Layout / ReusableComposeNode 实现", isOn: $store.filterConfiguration.hideLayoutImplementation)
                            Toggle("无独立内容的列表组合包装", isOn: $store.filterConfiguration.hideCompositionWrappers)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Android View 类名") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach($store.filterConfiguration.viewRules) { $rule in
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle(isOn: $rule.enabled) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(rule.shortName).font(.system(size: 12))
                                            Text(rule.className).font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        store.filterConfiguration.viewRules.removeAll { $0.id == rule.id }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .help("移除 \(rule.className)").accessibilityLabel("移除 \(rule.className)")
                                }
                            }
                            if store.filterConfiguration.viewRules.isEmpty {
                                Text("尚无类名规则，可在下方添加或恢复默认。")
                                    .foregroundStyle(.secondary)
                            }
                        }.padding(6)
                    }
                }.padding(.trailing, 8)
            }
            HStack {
                TextField("添加类名，例如 android.widget.ViewAnimator", text: $className)
                    .textFieldStyle(.roundedBorder).onSubmit(addRule)
                Button("添加", action: addRule).disabled(className.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(validationMessage.isEmpty
                 ? "完整类名精确匹配；简单类名匹配各包下的同名 View。添加后自动勾选。"
                 : validationMessage)
                .font(.system(size: 11)).foregroundStyle(validationMessage.isEmpty ? Color.secondary : Color.orange)
            HStack {
                Button("恢复默认") {
                    store.restoreDefaultFilters()
                    validationMessage = ""
                }
                Spacer()
                Text("立即生效 · 自动保存").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.toggleStyle(.checkbox).padding(20).frame(width: 600, height: 680)
    }

    private func addRule() {
        if store.filterConfiguration.addViewRule(className) {
            className = ""
            validationMessage = ""
        } else {
            validationMessage = "请输入有效类名，使用点分隔包名；支持字母、数字、下划线和 $。"
        }
    }
}
