import AppKit
import ComposeInspectCore
import SwiftUI
import UniformTypeIdentifiers

struct RawJSONPresentation: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let document: InspectorDocument
    var nodePointer: String? = nil
    var metadata: CaptureMetadata? = nil
}

struct JSONFile: Sendable {
    let url: URL
    let size: UInt64
    let preview: String
    static let previewLimit = 32 * 1024

    func export(to destination: URL) throws {
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: directory) }
        let staged = directory.appendingPathComponent(destination.lastPathComponent)
        try manager.copyItem(at: url, to: staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}

actor JSONFiles {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var files: [String: JSONFile] = [:]
    private var copied = Set<URL>()

    deinit {
        if copied.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        } else {
            for file in files.values where !copied.contains(file.url) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    func retainForPaste(_ url: URL) { copied.insert(url) }

    func file(for scope: String, presentation: RawJSONPresentation) throws -> JSONFile {
        if let file = files[scope] { return file }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("CompScope-" + scope + ".json")
        switch scope {
        case "节点", "窗口":
            let pointer = presentation.nodePointer ?? ""
            let value = scope == "节点" ? presentation.document.root.value(at: pointer) : presentation.document.window(for: pointer)
            try (value ?? .null).writeJSON(to: url, pretty: true)
        case "采集信息": try JSONEncoder().encode(presentation.metadata).write(to: url)
        case "原始采集": try (presentation.metadata?.baselineJSON ?? Data()).write(to: url)
        default: try presentation.document.originalJSON.write(to: url)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var prefix = try handle.read(upToCount: JSONFile.previewLimit) ?? Data()
        if size > prefix.count {
            // A valid capture may end mid-scalar at the preview boundary.
            for _ in 0..<3 where String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
        }
        let file = JSONFile(url: url, size: size, preview: String(decoding: prefix, as: UTF8.self))
        files[scope] = file
        return file
    }
}

struct RawJSONView: View {
    let presentation: RawJSONPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String
    @State private var files = JSONFiles()
    @State private var loadedScope: String?
    @State private var loaded: JSONFile?
    private var current: JSONFile? { loadedScope == scope ? loaded : nil }

    init(presentation: RawJSONPresentation) {
        self.presentation = presentation
        _scope = State(initialValue: presentation.nodePointer == nil ? "完整 JSON" : "节点")
    }
    @State private var exportError: String?
    private var scopes: [String] {
        var values = ["完整 JSON"]
        if presentation.nodePointer != nil { values = ["节点", "窗口", "完整 JSON"] }
        if presentation.metadata != nil { values += ["采集信息", "原始采集"] }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(presentation.title).font(.headline).lineLimit(1)
                Spacer()
                if let file = current {
                    Text("\(file.size.formatted()) 字节" + (file.size > JSONFile.previewLimit ? " · 预览前 32 KiB" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("查看范围", selection: $scope) { ForEach(scopes, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            ReadOnlyJSONText(text: current?.preview ?? "正在准备预览…")
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppStyle.divider))
            HStack {
                Spacer()
                IconButton(title: "关闭 JSON 窗口", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
                IconButton(title: "导出 JSON…", systemImage: "square.and.arrow.up") {
                    if let file = current { export(file) }
                }.disabled(current == nil)
                IconButton(title: "复制 JSON 文件", systemImage: "doc.on.doc") {
                    guard let file = current else { return }
                    Task {
                        await files.retainForPaste(file.url)
                        NSPasteboard.general.clearContents()
                        if !NSPasteboard.general.writeObjects([file.url as NSURL]) {
                            exportError = "无法将文件复制到剪贴板。"
                        }
                    }
                }.disabled(current == nil)
            }
        }.padding(18).frame(width: 850, height: 590)
            .task(id: scope) {
                let selected = scope
                do {
                    let file = try await files.file(for: selected, presentation: presentation)
                    try Task.checkCancellation()
                    loaded = file
                    loadedScope = selected
                } catch {
                    if !Task.isCancelled { exportError = error.localizedDescription }
                }
            }
            .alert("JSON 文件操作失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("好") { exportError = nil }
            } message: { Text(exportError ?? "") }
    }
    private func export(_ file: JSONFile) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "compscope.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await Task.detached { try file.export(to: url) }.value }
            catch { exportError = error.localizedDescription }
        }
    }
}

private struct ReadOnlyJSONText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.drawsBackground = false; editor.textColor = .labelColor
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let editor = scroll.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
}
