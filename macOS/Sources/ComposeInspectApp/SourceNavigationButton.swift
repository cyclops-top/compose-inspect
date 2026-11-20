import AppKit
import ComposeInspectCore
import SwiftUI

enum AndroidSourceFiles {
    // Called off the main actor. Re-enumerate on each request so moves and new duplicates are visible.
    static func matches(file: String, project: URL) async throws -> [String] {
        let name = (file as NSString).lastPathComponent
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var directories = [""]
        var results: [String] = []
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            let entries = try FileManager.default.contentsOfDirectory(at: project.appendingPathComponent(directory),
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            for url in entries {
                let filename = url.lastPathComponent
                let relative = directory.isEmpty ? filename : directory + "/" + filename
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true, values.isSymbolicLink != true, filename != "build" {
                    directories.append(relative)
                } else if filename == name, values.isRegularFile == true {
                    results.append(relative)
                }
            }
        }
        return results.sorted()
    }
}

struct SourceNavigationButton: View {
    let source: SourceAnchor?
    let project: String
    let inherited: Bool
    let index: ProjectSourceIndex?
    let copy: (String) -> Void
    let showNotice: (String) -> Void
    @State private var searching = false
    @State private var candidates: [String] = []
    @State private var choosing = false
    @State private var failure: String?

    private static let studio = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.android.studio")
    private static let icon = studio.map { NSWorkspace.shared.icon(forFile: $0.path) }
    private var title: String {
        if project.isEmpty { return "复制源码路径" }
        return inherited && source != nil ? "在 Android Studio 中打开父组件调用处" : "在 Android Studio 中打开"
    }

    var body: some View {
        Button {
            guard let source else { return }
            if project.isEmpty { copy(source.text) } else { searching = true }
        } label: {
            HStack {
                if searching {
                    ProgressView().controlSize(.mini)
                } else if !project.isEmpty, let icon = Self.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: project.isEmpty ? "doc.on.doc" : "hammer")
                }
                Text(title)
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(source == nil || searching)
        .help(source == nil ? "没有可用的源码位置" : (project.isEmpty ? "粘贴到 Android Studio 的文件搜索框" : title))
        .contextMenu {
            if let source { Button("复制源码路径") { copy(source.text) } }
        }
        .task(id: searching) {
            guard searching, let source else { return }
            defer { searching = false }
            do {
                let matches: [String]
                if let index {
                    guard index.project == project, index.status.isEmpty else {
                        showNotice(index.status.isEmpty ? "工程源码索引正在切换" : index.status)
                        return
                    }
                    matches = index.matches(source)
                } else {
                    matches = try await AndroidSourceFiles.matches(file: source.file, project: URL(fileURLWithPath: project))
                }
                try Task.checkCancellation()
                if matches.isEmpty { showNotice("工程中未找到 " + source.file) }
                else if matches.count == 1 && (index == nil || index?.confirms(source) == true) { open(matches[0]) }
                else { candidates = matches; choosing = true }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                if !Task.isCancelled { showNotice(error.localizedDescription) }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择源码文件").font(.headline)
                List(candidates, id: \.self) { path in
                    Button {
                        choosing = false
                        open(path)
                    } label: {
                        Text(path)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                HStack { Spacer(); Button("取消") { choosing = false }.keyboardShortcut(.cancelAction) }
            }.padding().frame(width: 560, height: 320)
        }
        .alert("无法打开源码", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func open(_ relativePath: String) {
        if let index, let source, index.project != project || !index.matches(source).contains(relativePath) {
            showNotice("工程源码已变化，请重新选择调用处。")
            return
        }
        let file = URL(fileURLWithPath: project).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            showNotice("未找到 " + file.lastPathComponent + "，文件可能已移动或删除。")
            return
        }
        guard let studio = Self.studio, let launcher = Bundle(url: studio)?.executableURL else {
            failure = "未找到 Android Studio。"
            return
        }
        let process = Process()
        process.executableURL = launcher
        process.arguments = [project] + (source?.line.map { ["--line", String($0)] } ?? []) + [file.path]
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                Task { @MainActor in failure = "Android Studio 启动器返回错误（\(process.terminationStatus)）。" }
            }
        }
        do { try process.run() } catch { failure = error.localizedDescription }
    }
}
