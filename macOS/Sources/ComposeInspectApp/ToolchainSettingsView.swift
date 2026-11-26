import ComposeInspectCore
import SwiftUI

struct ToolchainSettingsView: View {
    @Bindable var settings: ToolchainSettings
    @Bindable var store: WorkspaceStore

    var body: some View {
        ScrollView { toolsPage }
            .frame(width: 580, height: 395)
            .task(id: settings.adbOverride) { await settings.validateADB() }
    }

    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工具环境").font(.system(size: 16, weight: .semibold))
                    Text("默认使用环境变量，手动填写的路径优先。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text("通过 ADB 连接设备。目标应用需在 debug 构建中通过 debugImplementation 接入 Compose Inspector SDK。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("采集组件详情", isOn: $store.componentDetails)
            Text("下次抓取时，按组件读取文字、样式、交互状态和列表视口。关闭时仅采集结构、边界和源码位置。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("仅采集有源码的组件", isOn: $store.onlySourceNodes)
            Text("下次抓取时，SDK 跳过没有源码文件名的组件，保留其有源码的子组件。关联工程后仅保留能唯一匹配工程文件的组件。关闭后重新抓取可查看全部组件。")
                .font(.caption).foregroundStyle(.secondary)
            adbSection
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("启动时自动读取用户 shell 配置中的 PATH 和工具环境变量，从 Finder 启动也可自动检测。修改终端配置后可重新读取环境。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("配置自动保存").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if settings.loadingEnvironment { ProgressView().controlSize(.small) }
                IconButton(title: "重新读取环境", systemImage: "arrow.clockwise") { Task { await settings.refreshEnvironment(); await settings.validateADB() } }
                    .controlSize(.small).disabled(settings.loadingEnvironment)
            }
            if !settings.environmentMessage.isEmpty {
                Text(settings.environmentMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
    }

    private var adbSection: some View {
        let resolution = settings.adbResolution
        let checking = settings.checkingADB
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ADB").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(settings.adbOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自动检测" : "手动配置")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                TextField("留空使用 ANDROID_HOME / PATH", text: $settings.adbOverride)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .accessibilityLabel("ADB 路径，留空使用环境变量")
                IconButton(title: "选择 ADB 可执行文件…", systemImage: "folder") { settings.chooseADB() }
                Button {
                    settings.adbOverride = ""
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("恢复环境变量自动检测").accessibilityLabel("恢复环境变量自动检测")
                    .disabled(settings.adbOverride.isEmpty)
            }.controlSize(.small)
            if let location = resolution.location {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.path).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Text("来源：\(location.source)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await settings.validateADB() }
                    } label: {
                        if checking { ProgressView().controlSize(.mini).frame(width: 28) }
                        else { Image(systemName: "stethoscope") }
                    }.controlSize(.small).disabled(checking)
                        .help("检测 ADB").accessibilityLabel("检测 ADB")
                }
            } else {
                Label(resolution.error ?? "未找到工具", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let result = settings.adbResult {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                    Text(result.message).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AppStyle.divider.opacity(0.5)))
    }
}
