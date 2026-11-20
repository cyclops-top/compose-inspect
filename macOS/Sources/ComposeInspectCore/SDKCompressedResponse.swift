import Foundation
import zlib

/// Bounded streaming inflate for the negotiated gzip-json-v1 response.
enum SDKCompressedResponse {
    static func decode(_ compressed: Data, maxBytes: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CommandFailure.failed("无法初始化 SDK 解压缩。")
        }
        defer { inflateEnd(&stream) }
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            while true {
                try Task.checkCancellation()
                let status = chunk.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard produced <= maxBytes - result.count else {
                    throw CommandFailure.failed("SDK 解压后响应超过大小限制。")
                }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, result.last == 10 else {
                        throw CommandFailure.failed("SDK 压缩响应包含多余数据或缺少结束标记。")
                    }
                    result.removeLast()
                    return
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else {
                    throw CommandFailure.failed("SDK 压缩响应损坏或不完整。")
                }
            }
        }
        return result
    }

    static func frameLength(_ bytes: Data, maxBytes: Int) throws -> Int? {
        guard bytes.count >= 4 else { return nil }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, Int(count) <= maxBytes else {
            throw CommandFailure.failed("SDK 压缩响应长度无效或超过大小限制。")
        }
        return Int(count) + 4
    }
}
