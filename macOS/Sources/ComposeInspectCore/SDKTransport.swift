import Foundation
import Darwin

/// A bounded, cancellable, newline-delimited exchange over an ADB-created loopback forward.
/// No Python/netcat runtime is needed by the desktop app.
enum SDKTransport {
    static func request(port: UInt16, command: String, timeout: TimeInterval, maxBytes: Int = 32 * 1024 * 1024,
                        compressed: Bool = false, componentDetails: Bool = false, windowImages: Bool = false, onlySourceNodes: Bool = false, sourceKeys: [String]? = nil) async throws -> Data {
        var options: [String: Any] = ["command": command, "windowImages": windowImages, "onlySourceNodes": onlySourceNodes]
        if command == "capture-gzip" { options["geometryOnly"] = !componentDetails }
        options["sourceKeys"] = sourceKeys
        var request = try JSONSerialization.data(withJSONObject: options)
        if request.count >= 4 * 1024 * 1024 {
            options.removeValue(forKey: "sourceKeys")
            request = try JSONSerialization.data(withJSONObject: options)
        }
        request.append(10)
        let worker = Task.detached(priority: .userInitiated) {
            try exchange(port: port, request: request, timeout: timeout, maxBytes: maxBytes, compressed: compressed)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    private static func exchange(port: UInt16, request: Data, timeout: TimeInterval, maxBytes: Int, compressed: Bool) throws -> Data {
        try Task.checkCancellation()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("创建连接") }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw failure("设置连接") }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw failure("设置连接") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func wait(_ events: Int16) throws {
            while true {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CommandFailure.failed("SDK 响应超时。") }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let status = poll(&descriptor, 1, 100)
                if status > 0 { return }
                if status < 0 && errno != EINTR { throw failure("等待响应") }
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw failure("连接 SDK") }
            try wait(Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw CommandFailure.failed("目标应用没有可连接的 SDK。")
            }
        }
        var sent = 0
        while sent < request.count {
            try wait(Int16(POLLOUT))
            let count = request.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
            if count > 0 { sent += count }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw failure("发送 SDK 请求") }
        }
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            try wait(Int16(POLLIN))
            let count = recv(fd, &bytes, bytes.count, 0)
            if count == 0 { throw CommandFailure.failed("SDK 连接已关闭，未收到完整响应。") }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw failure("读取 SDK 响应")
            }
            guard response.count + count <= maxBytes + (compressed ? 4 : 0) else { throw CommandFailure.failed("SDK 响应超过大小限制。") }
            if compressed {
                response.append(contentsOf: bytes[..<count])
                if let length = try SDKCompressedResponse.frameLength(response, maxBytes: maxBytes) {
                    guard response.count <= length else { throw CommandFailure.failed("SDK 返回了多余的压缩响应数据。") }
                    if response.count == length {
                        return try SDKCompressedResponse.decode(Data(response.dropFirst(4)), maxBytes: maxBytes)
                    }
                }
                continue
            }
            if let newline = bytes[..<count].firstIndex(of: 10) {
                guard newline == count - 1 else { throw CommandFailure.failed("SDK 返回了多余的响应数据。") }
                response.append(contentsOf: bytes[..<newline])
                return response
            }
            response.append(contentsOf: bytes[..<count])
        }
    }

    private static func failure(_ operation: String) -> CommandFailure {
        .failed("\(operation)失败：\(String(cString: strerror(errno)))")
    }
}
