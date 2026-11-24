import Foundation

/// A tap is available only when a Compose layout and a uniquely labelled accessibility action agree.
public struct ClickTarget: Sendable {
    public let package: String
    public let serial: String
    public let pid: Int64
    public let label: String
    public let point: CGPoint
    public let screen: CGSize

    public init(node: InspectorNode, snapshot: InspectorSnapshot) throws {
        guard node.isClickable, node.clickTargetID != nil, let metadata = snapshot.captureMetadata,
              let doc = snapshot.document, doc.root["captureBackend"]?.string == "sdk",
              let pid = doc.root["sdkCapture"]?["pid"]?.int64,
              let bounds = doc.root.value(at: node.id)?["bounds"],
              let x = bounds["x"]?.double, let y = bounds["y"]?.double,
              let width = bounds["width"]?.double, let height = bounds["height"]?.double,
              width > 0, height > 0 else { throw CommandFailure.failed("组件缺少已确认的点击布局。") }
        var labels = Set<String>()
        var pending = [node]
        while let current = pending.popLast() {
            if current.id != node.id, current.isClickable, current.clickTargetID != node.clickTargetID { continue }
            if let label = current.label, !label.isEmpty { labels.insert(label) }
            pending.append(contentsOf: current.children)
        }
        guard labels.count == 1, let label = labels.first else {
            throw CommandFailure.failed("点击目标需要一个可唯一辨认的文本或描述。")
        }
        self.label = label
        self.pid = pid
        serial = metadata.serial
        package = snapshot.packageName
        screen = snapshot.pixelSize
        point = CGPoint(x: floor(x + width / 2), y: floor(y + height / 2))
        guard CGRect(origin: .zero, size: screen).contains(point) else { throw CommandFailure.failed("目标中心超出截图。") }
    }
}

struct VerificationHierarchy {
    let nodes: [XMLElement]
    let rotation: Int

    init(_ bytes: Data) throws {
        guard bytes.count <= 8 * 1024 * 1024 else { throw CommandFailure.failed("无障碍窗口数据超出大小限制。") }
        let text = String(decoding: bytes, as: UTF8.self)
        guard let end = text.range(of: "</hierarchy>", options: .backwards),
              !text.contains("<!DOCTYPE") else { throw CommandFailure.failed("无法读取当前无障碍窗口。") }
        let doc = try XMLDocument(xmlString: String(text[..<end.upperBound]), options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "hierarchy",
              let rotation = root.attribute(forName: "rotation")?.stringValue.flatMap(Int.init) else {
            throw CommandFailure.failed("无障碍窗口信息不完整。")
        }
        self.rotation = rotation
        nodes = try root.nodes(forXPath: ".//node").compactMap { $0 as? XMLElement }
    }

    func matches(_ text: String, in package: String) -> [XMLElement] {
        nodes.filter { $0.attr("package") == package && ($0.attr("text") == text || $0.attr("content-desc") == text) }
    }

    func check(_ target: ClickTarget) throws {
        let labels = matches(target.label, in: target.package)
        guard labels.count == 1, var node = labels.first, node.box?.contains(target.point) == true else {
            throw CommandFailure.failed("目标文本已移动、消失或重复，请重新获取界面。")
        }
        while node.attr("clickable") != "true", let parent = node.parent as? XMLElement { node = parent }
        let hits = nodes.filter { $0.attr("clickable") == "true" && $0.box?.contains(target.point) == true }
        guard hits.count == 1, hits.first === node, node.attr("enabled") == "true",
              node.attr("package") == target.package else {
            throw CommandFailure.failed("点击位置没有唯一且启用的无障碍动作。")
        }
    }
}

private extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    var box: CGRect? {
        guard let value = attr("bounds"), let match = value.wholeMatch(of: /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/),
              let x = Double(match.1), let y = Double(match.2), let r = Double(match.3), let b = Double(match.4),
              r >= x, b >= y else { return nil }
        return CGRect(x: x, y: y, width: r-x, height: b-y)
    }
}

extension InspectorClient {
    func hierarchy(serial: String, timeout: TimeInterval = 6) async throws -> VerificationHierarchy {
        let result = try await adb(["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"], timeout: timeout)
        return try VerificationHierarchy(result.stdout)
    }

    public func expectedTextVisible(_ text: String, target: ClickTarget, timeout: TimeInterval) async throws -> Bool {
        let hierarchy = try await hierarchy(serial: target.serial, timeout: timeout)
        return !hierarchy.matches(text, in: target.package).isEmpty
    }

    public func checkTap(_ target: ClickTarget, expected: String) async throws {
        let hierarchy = try await hierarchy(serial: target.serial)
        try hierarchy.check(target)
        guard hierarchy.matches(expected, in: target.package).isEmpty else {
            throw CommandFailure.failed("预期文本已存在，无法用它验证本次点击。")
        }
        let input = try await adb(["-s", target.serial, "shell", "dumpsys", "input"], timeout: 3)
        try Self.checkInputWindows(String(decoding: input.stdout, as: UTF8.self), target: target, rotation: hierarchy.rotation)
    }

    static func checkInputWindows(_ dump: String, target: ClickTarget, rotation: Int) throws {
        let unavailable = CommandFailure.failed("无法确认显示屏、前台输入窗口或遮挡情况，本次停止。")
        guard let focus = dump.components(separatedBy: "\n  FocusedWindows:\n").last?.components(separatedBy: "\n  FocusRequests:").first,
              let match = focus.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /displayId=0, name='([^'\n]+)'/),
              match.1.contains(" " + target.package + "/"),
              let display = dump.components(separatedBy: "\n  Display: 0\n").dropFirst().first,
              let header = display.components(separatedBy: "\n    Windows:\n").first,
              header.contains("logicalSize=\(Int(target.screen.width))x\(Int(target.screen.height))\n"),
              header.contains("ROT_\(rotation * 90)") else { throw unavailable }
        let activeDisplays = Set(dump.split(separator: "\n").filter { $0.contains("Viewport ") && $0.contains("isActive=[1]") }
            .compactMap { $0.firstMatch(of: /displayId=(\d+),/)?.1 })
        guard activeDisplays == ["0"] else { throw unavailable }
        var expectedIndex = 0
        for line in display.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard let prefix = row.firstMatch(of: /^(\d+): name=(.*?), id=/) else { continue }
            guard Int(prefix.1) == expectedIndex, row.contains(", displayId=0,"),
                  let config = row.firstMatch(of: /, inputConfig=([^,]+),/) else { throw unavailable }
            let flags = Set(config.1.components(separatedBy: " | "))
            expectedIndex += 1
            if prefix.2 == match.1 {
                guard row.contains(", ownerPid=\(target.pid),"), !flags.contains("NOT_TOUCHABLE"),
                      !flags.contains("NOT_VISIBLE"), let region = row.firstMatch(of: /touchableRegion=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\],/),
                      let x = Double(region.1), let y = Double(region.2), let r = Double(region.3), let b = Double(region.4),
                      CGRect(x: x, y: y, width: r-x, height: b-y).contains(target.point) else { throw unavailable }
                return
            }
            if flags.contains("NOT_VISIBLE") || (flags.contains("TRUSTED_OVERLAY") && flags.contains("SPY")) { continue }
            guard let frame = row.firstMatch(of: /frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/),
                  let x = Double(frame.1), let y = Double(frame.2), let r = Double(frame.3), let b = Double(frame.4),
                  !CGRect(x: x, y: y, width: r-x, height: b-y).contains(target.point),
                  (row.contains("touchableRegion=<empty>") || flags.contains("NOT_TOUCHABLE") ||
                    row.contains("touchableRegion=\(frame.0.dropFirst("frame=".count)),")) else { throw unavailable }
        }
        throw unavailable
    }
}
