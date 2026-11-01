import ComposeInspectCore
import SwiftUI

struct ToolchainSettingsView: View {
    @Bindable var settings: ToolchainSettings

    var body: some View {
        TabView {
            ScrollView { toolsPage }.tabItem { Label("工具环境", systemImage: "wrench.and.screwdriver") }
            capturePage.tabItem { Label("检查", systemImage: "viewfinder") }
        }.frame(width: 620, height: 580)
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
            toolSection(.adb, path: $settings.adbOverride, placeholder: "留空使用 ANDROID_HOME / PATH")
            toolSection(.java, path: $settings.javaOverride, placeholder: "留空使用 JAVA_HOME / PATH")
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("启动时自动读取用户 shell 配置中的 PATH 和工具环境变量，从 Finder 启动也可自动检测。修改终端配置后可重新读取环境。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("配置自动保存").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if settings.loadingEnvironment { ProgressView().controlSize(.small) }
                Button("重新读取环境") { Task { await settings.refreshEnvironment() } }
                    .controlSize(.small).disabled(settings.loadingEnvironment)
            }
            if !settings.environmentMessage.isEmpty {
                Text(settings.environmentMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("UI Inspector").font(.headline)
            Text("默认使用应用内置 JAR，通过设置中的 Java 运行。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField("留空使用内置 ui-inspector.jar", text: $settings.inspectorJarOverride).textFieldStyle(.roundedBorder)
                Button("选择…") { settings.chooseInspectorJar() }
            }.font(.system(size: 11))
            Text(settings.inspectorJar?.path ?? "未找到内置 JAR")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Toggle("抓取属性来源链（resolution-stack）", isOn: $settings.includeResolutionStack)
            Text("首次开启会修改设备的调试属性设置，并可能重启目标 Activity；该设备设置会持续保留。默认关闭。关闭此开关仅停止请求来源链，不会自动还原设备设置。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("组件参数、两种语义和系统组件默认抓取；来源链字段会完整解析。上游截断值按需继续读取，不递归遍历未知大小的集合。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(22)
    }

    private func toolSection(_ tool: ToolKind, path: Binding<String>, placeholder: String) -> some View {
        let resolution = settings.resolution(for: tool)
        let checking = settings.checking.contains(tool)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tool.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(path.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自动检测" : "手动配置")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                TextField(placeholder, text: path)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .accessibilityLabel("\(tool.displayName)路径，留空使用环境变量")
                Button("选择…") { settings.choose(tool) }
                Button {
                    settings.reset(tool)
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("恢复环境变量自动检测")
                    .disabled(path.wrappedValue.isEmpty)
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
                        Task { await settings.validate(tool) }
                    } label: {
                        if checking { ProgressView().controlSize(.mini).frame(width: 28) }
                        else { Text("检测") }
                    }.controlSize(.small).disabled(checking)
                }
            } else {
                Label(resolution.error ?? "未找到工具", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let result = settings.results[tool] {
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
