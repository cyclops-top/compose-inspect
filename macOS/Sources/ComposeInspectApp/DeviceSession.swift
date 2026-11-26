import AppKit
import ComposeInspectCore
import Observation
import SwiftUI

@MainActor @Observable
final class DeviceSession {
    var devices: [ADBDevice] = []
    var selectedSerial: String? {
        didSet { if oldValue != selectedSerial { packageRefreshRevision = UUID() } }
    }
    var packages: [String] = []
    var packageName = ""
    var automaticallySelectForeground = true
    private(set) var resolvingCaptureTarget = false
    var discovering = false
    var capturing = false
    var progress = ""
    private(set) var captureStartedAt: Date?
    var showApplications = false
    var packageSearch = ""
    private var discoveryRevision = UUID()
    private var packageRefreshRevision = UUID()
    var selectedDevice: ADBDevice? { devices.first { $0.serial == selectedSerial } }

    func refresh(settings: ToolchainSettings) async throws {
        guard !discovering else { return }
        discovering = true
        let revision = UUID(); discoveryRevision = revision
        defer { if discoveryRevision == revision { discovering = false } }
        let client = InspectorClient(tools: try settings.resolvedTools())
        let found = try await client.devices()
        guard discoveryRevision == revision else { return }
        devices = found
        if !found.contains(where: { $0.serial == selectedSerial && $0.online }) {
            selectedSerial = found.filter(\.online).count == 1 ? found.first(where: \.online)?.serial : nil
            packages = []; packageName = ""
        }
        if selectedSerial != nil { try await refreshPackages(settings: settings) }
    }
    func selectDevice(_ serial: String, settings: ToolchainSettings) async throws {
        selectedSerial = serial; packageName = ""; packages = []
        try await refreshPackages(settings: settings)
    }
    func refreshPackages(settings: ToolchainSettings, selectForeground: Bool = false) async throws {
        let client = InspectorClient(tools: try settings.resolvedTools())
        try await refreshPackages(selectForeground: selectForeground) { serial in
            let packages = try await client.packages(serial: serial)
            let foreground: String?
            if selectForeground {
                foreground = try await client.foregroundPackage(serial: serial)
            } else {
                foreground = try? await client.foregroundPackage(serial: serial)
            }
            return (packages, foreground)
        }
    }

    func refreshPackages(selectForeground: Bool = false,
                         load: @MainActor (String) async throws -> (packages: [String], foreground: String?)) async throws {
        guard let serial = selectedSerial else { return }
        let revision = UUID()
        packageRefreshRevision = revision
        let previousPackage = packageName
        let result = try await load(serial)
        try Task.checkCancellation()
        guard packageRefreshRevision == revision, selectedSerial == serial else { return }
        packages = result.packages
        // A manual selection made during discovery takes precedence over the pending result.
        guard packageName == previousPackage else { return }
        if let foreground = result.foreground, result.packages.contains(foreground) {
            if selectForeground || packageName.isEmpty { packageName = foreground }
        } else if selectForeground {
            throw CommandFailure.failed("未找到可选择的前台应用，请在设备上打开目标应用后重试。")
        }
    }
    func prepareCaptureTarget(settings: ToolchainSettings) async throws {
        guard automaticallySelectForeground else { return }
        guard let serial = selectedSerial, selectedDevice?.online == true else {
            throw CommandFailure.configuration("请先选择在线设备。")
        }
        resolvingCaptureTarget = true
        defer { resolvingCaptureTarget = false }
        let client = InspectorClient(tools: try settings.resolvedTools())
        let foreground = try await client.foregroundPackage(serial: serial)
        try Task.checkCancellation()
        guard selectedSerial == serial, automaticallySelectForeground else { throw CancellationError() }
        guard let foreground, InspectorClient.validPackage(foreground) else {
            throw CommandFailure.failed("未找到前台应用，请在设备上打开目标应用后重试，或取消自动获取并手动选择。")
        }
        packageName = foreground
    }

    func capture(settings: ToolchainSettings, componentDetails: Bool = false, onlySourceNodes: Bool = false) async throws -> CapturedSnapshot {
        guard !capturing, let device = selectedDevice, device.online else { throw CommandFailure.configuration("请先选择在线设备。") }
        let package = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sdk = SDKInspectorClient(tools: try settings.resolvedTools())
        captureStartedAt = Date()
        capturing = true
        defer { capturing = false; progress = "" }
        return try await sdk.capture(serial: device.serial, package: package, deviceName: device.model,
                                     windowImages: true, componentDetails: componentDetails, onlySourceNodes: onlySourceNodes) { [weak self] value in
            await self?.setProgress(value)
        }
    }
    private func setProgress(_ value: String) { progress = value }
}

struct ApplicationPickerView: View {
    @Bindable var session: DeviceSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择应用").font(.headline)
            TextField("搜索或输入应用包名", text: $session.packageSearch).textFieldStyle(.roundedBorder)
            List(session.packages.filter { session.packageSearch.isEmpty || $0.localizedCaseInsensitiveContains(session.packageSearch) }, id: \.self) { package in
                Button { session.automaticallySelectForeground = false; session.packageName = package; dismiss() } label: {
                    HStack { Text(package).font(.system(size: 12, design: .monospaced)); Spacer(); if session.packageName == package { Image(systemName: "checkmark") } }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack {
                Text("目标应用需为可调试构建，并保持前台可见。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用输入的包名") { session.automaticallySelectForeground = false; session.packageName = session.packageSearch; dismiss() }
                    .disabled(!InspectorClient.validPackage(session.packageSearch))
            }
        }.padding(18).frame(width: 620, height: 440)
    }
}
