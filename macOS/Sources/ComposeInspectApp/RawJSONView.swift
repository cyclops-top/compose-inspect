import AppKit
import ComposeInspectCore
import SwiftUI
import UniformTypeIdentifiers

struct RawJSONPresentation: Identifiable {
    let id = UUID()
    let title: String
    let document: InspectorDocument
    var nodePointer: String? = nil
    var metadata: CaptureMetadata? = nil
}

struct RawJSONView: View {
    let presentation: RawJSONPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "完整 JSON"
    @State private var exportError: String?
    private var scopes: [String] {
        var values = ["完整 JSON"]
        if presentation.nodePointer != nil { values = ["节点", "窗口", "完整 JSON"] }
        if presentation.metadata != nil { values += ["采集信息", "原始采集"] }
        return values
    }
    private var data: Data {
        switch scope {
        case "节点":
            return Data((presentation.document.root.value(at: presentation.nodePointer ?? "")?.jsonString(pretty: true) ?? "null").utf8)
        case "窗口":
            return Data((presentation.document.window(for: presentation.nodePointer ?? "")?.jsonString(pretty: true) ?? "null").utf8)
        case "采集信息": return (try? JSONEncoder().encode(presentation.metadata)) ?? Data()
        case "原始采集": return presentation.metadata?.baselineJSON ?? Data()
        default: return presentation.document.originalJSON
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(presentation.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(data.count.formatted()) 字节").font(.caption).foregroundStyle(.secondary)
            }
            Picker("查看范围", selection: $scope) { ForEach(scopes, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            ReadOnlyJSONText(text: String(decoding: data, as: UTF8.self))
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppStyle.divider))
            HStack {
                Spacer()
                IconButton(title: "关闭 JSON 窗口", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
                IconButton(title: "导出 JSON…", systemImage: "square.and.arrow.up") { export() }
                IconButton(title: "复制 JSON", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
            }
        }.padding(18).frame(width: 850, height: 590)
            .onAppear { scope = presentation.nodePointer == nil ? "完整 JSON" : "节点" }
            .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("好") { exportError = nil }
            } message: { Text(exportError ?? "") }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "compscope.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { exportError = error.localizedDescription }
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
