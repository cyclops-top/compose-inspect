import CoreServices
import Foundation
import Observation
import ComposeInspectCore

/// Only the serial worker mutates the catalog. The UI receives immutable snapshots.
private struct SourceCatalog: Sendable {
    var files: [String: [String: Int32?]] = [:]

    static func hash(_ name: String) -> Int32 {
        let signed = name.utf16.reduce(Int32.zero) { $0 &* 31 &+ Int32($1) }
        return signed < 0 ? 0 &- signed : signed
    }

    // Skip comments and strings before the package directive (including @file annotations).
    private static let header = try! NSRegularExpression(pattern:
        #"(?ms)/\*|//[^\r\n]*|""".*?"""|"(?:\\.|[^"\\])*"|\bpackage\s+((?:`[^`\r\n]+`|[\p{L}_][\p{L}\p{M}\p{N}_]*)(?:\s*\.\s*(?:`[^`\r\n]+`|[\p{L}_][\p{L}\p{M}\p{N}_]*))*)|(?<!:)\b(?:import|class|fun|interface|object|val|var)\b"#)

    static func packageHash(in url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = String(data: data, encoding: .utf8) else { return nil }
        let text = source as NSString
        var offset = 0
        while let token = header.firstMatch(in: source, range: NSRange(location: offset, length: text.length - offset)) {
            if token.range(at: 1).location != NSNotFound {
                let name = text.substring(with: token.range(at: 1)).components(separatedBy: ".").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                }.joined(separator: ".")
                return hash(name)
            }
            offset = NSMaxRange(token.range)
            let matched = text.substring(with: token.range)
            if matched == "/*" {
                let nested = url.pathExtension == "kt"
                var depth = 1
                while offset + 1 < text.length && depth > 0 {
                    let first = text.character(at: offset)
                    let second = text.character(at: offset + 1)
                    if first == 42 && second == 47 { // */
                        depth -= 1
                        offset += 2
                    } else if nested && first == 47 && second == 42 { // /*
                        depth += 1
                        offset += 2
                    } else {
                        offset += 1
                    }
                }
                guard depth == 0 else { return nil }
            } else if matched.first?.isLetter == true {
                return nil
            }
        }
        return nil
    }

    mutating func refresh(_ path: String, root: URL, subtree: Bool) {
        let relative = String(path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") || $0 == "build" }) else { return }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if subtree {
            if relative.isEmpty { files.removeAll() }
            else {
                let prefix = relative + "/"
                files = files.compactMapValues { entries in
                    let retained = entries.filter { !$0.key.hasPrefix(prefix) && $0.key != relative }
                    return retained.isEmpty ? nil : retained
                }
            }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func isSource(_ url: URL) -> Bool { ["kt", "java"].contains(url.pathExtension) }
        if isSource(url) {
            files[url.lastPathComponent]?.removeValue(forKey: relative)
            if (try? url.resourceValues(forKeys: keys)).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true {
                files[url.lastPathComponent, default: [:]].updateValue(Self.packageHash(in: url), forKey: relative)
            }
        }
        guard subtree, let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true,
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in enumerator {
            if file.lastPathComponent == "build" { enumerator.skipDescendants(); continue }
            guard isSource(file), let info = try? file.resourceValues(forKeys: keys),
                  info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let entry = String(file.path.dropFirst(root.path.count + 1))
            files[file.lastPathComponent, default: [:]].updateValue(Self.packageHash(in: file), forKey: entry)
        }
    }
}

private final class SourceWatcher: @unchecked Sendable {
    let root: URL
    let queue = DispatchQueue(label: "CompScope.source-index", qos: .utility)
    private var catalog = SourceCatalog()
    private var stream: FSEventStreamRef?
    let publish: @Sendable (SourceCatalog) -> Void

    init(root: URL, publish: @escaping @Sendable (SourceCatalog) -> Void) {
        self.root = root
        self.publish = publish
    }

    private final class Context {
        weak var owner: SourceWatcher?
        init(_ owner: SourceWatcher) { self.owner = owner }
    }

    func start() -> Bool {
        let callback = Context(self)
        defer { withExtendedLifetime(callback) {} }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
                                           retain: { _ = Unmanaged<Context>.fromOpaque($0!).retain(); return $0 },
                                           release: { Unmanaged<Context>.fromOpaque($0!).release() }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            guard let owner = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().owner else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            var changed = false
            for i in 0..<count {
                let flag = Int(flags[i])
                if flag & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                    owner.catalog.refresh(owner.root.path, root: owner.root, subtree: true)
                    changed = true
                    break
                }
                let path = paths[i]
                guard path == owner.root.path || path.hasPrefix(owner.root.path + "/") else { continue }
                let recursive = flag & (kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs) != 0
                guard recursive || path.hasSuffix(".kt") || path.hasSuffix(".java") else { continue }
                owner.catalog.refresh(path, root: owner.root, subtree: recursive)
                changed = true
            }
            if changed { owner.publish(owner.catalog) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
              FSEventStreamCreateFlags(flags)) else { return false }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); return false }
        queue.async {
            self.catalog.refresh(self.root.path, root: self.root, subtree: true)
            self.publish(self.catalog)
        }
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

@MainActor @Observable
final class ProjectSourceIndex {
    private var catalog = SourceCatalog()
    @ObservationIgnored private var watcher: SourceWatcher?
    @ObservationIgnored var onCatalogChange: (() -> Void)?
    private var generation = UUID()
    private(set) var project = ""
    private(set) var status = ""

    deinit { watcher?.stop() }

    func open(_ path: String) {
        guard path != project else { return }
        watcher?.stop()
        watcher = nil
        generation = UUID()
        catalog = SourceCatalog()
        project = path
        onCatalogChange?()
        status = ""
        guard !path.isEmpty else { return }
        // FileManager enumeration and FSEvents both use the physical path (e.g. /private/var).
        guard let physicalPath = realpath(path, nil) else {
            status = "无法访问工程源码目录"
            return
        }
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
        let revision = generation
        let watcher = SourceWatcher(root: root) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.generation == revision else { return }
                self.catalog = snapshot
                self.onCatalogChange?()
                self.status = ""
            }
        }
        self.watcher = watcher
        status = watcher.start() ? "正在建立工程源码索引…" : "无法监听工程源码目录"
    }

    func matches(_ source: SourceAnchor) -> [String] {
        let name = (source.file as NSString).lastPathComponent
        guard let entries = catalog.files[name] else { return [] }
        guard let hash = source.packageHash, hash != -1 else { return entries.keys.sorted() }
        return entries.compactMap { $0.value == hash ? $0.key : nil }.sorted()
    }

    func confirms(_ source: SourceAnchor?) -> Bool {
        guard let source else { return false }
        return uniqueFile(for: source) != nil
    }

    func uniqueFile(for source: SourceAnchor) -> String? {
        if source.packageHash == nil || source.packageHash == -1 { return nil }
        let paths = matches(source)
        return paths.count == 1 ? paths.first : nil
    }
}
