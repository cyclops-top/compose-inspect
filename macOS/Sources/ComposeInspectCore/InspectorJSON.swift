import Foundation

/// Number tokens stay exact. Original dump bytes are archived separately, including key order and whitespace.
public indirect enum InspectorJSON: Codable, Equatable, Sendable {
    case object([String: InspectorJSON]), array([InspectorJSON]), string(String), number(String), bool(Bool), null
    public subscript(_ key: String) -> InspectorJSON? { object?[key] }
    public var object: [String: InspectorJSON]? { if case .object(let v) = self { v } else { nil } }
    public var array: [InspectorJSON]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var int64: Int64? { if case .number(let v) = self { Int64(v) } else { nil } }
    public var double: Double? { if case .number(let v) = self { Double(v) } else { nil } }
    public var boolean: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var display: String {
        switch self {
        case .string(let v), .number(let v): v
        case .bool(let v): v ? "true" : "false"
        case .null: "null"
        case .array, .object: jsonString()
        }
    }
    public func jsonString(pretty: Bool = false, level: Int = 0) -> String {
        enum Work {
            case value(InspectorJSON, Int)
            case text(String)
        }
        let encoder = JSONEncoder()
        func quote(_ value: String) -> String {
            if value.utf8.allSatisfy({ $0 >= 32 && $0 != 34 && $0 != 92 && $0 != 47 }) {
                return "\"" + value + "\""
            }
            return String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        var pending: [Work] = [.value(self, level)]
        var output = ""
        while let work = pending.popLast() {
            switch work {
            case .text(let text): output += text
            case .value(let value, let depth):
                switch value {
                case .number(let token): output += token
                case .string(let string): output += quote(string)
                case .null: output += "null"
                case .bool(let bool): output += bool ? "true" : "false"
                case .array(let values):
                    guard !values.isEmpty else { output += "[]"; continue }
                    output += pretty ? "[\n" : "["
                    pending.append(.text(pretty ? "\n" + String(repeating: "  ", count: depth) + "]" : "]"))
                    for index in values.indices.reversed() {
                        if index < values.count - 1 { pending.append(.text(pretty ? ",\n" : ",")) }
                        pending.append(.value(values[index], depth + 1))
                        if pretty { pending.append(.text(String(repeating: "  ", count: depth + 1))) }
                    }
                case .object(let values):
                    guard !values.isEmpty else { output += "{}"; continue }
                    let keys = values.keys.sorted()
                    output += pretty ? "{\n" : "{"
                    pending.append(.text(pretty ? "\n" + String(repeating: "  ", count: depth) + "}" : "}"))
                    for index in keys.indices.reversed() {
                        if index < keys.count - 1 { pending.append(.text(pretty ? ",\n" : ",")) }
                        pending.append(.value(values[keys[index]]!, depth + 1))
                        pending.append(.text((pretty ? String(repeating: "  ", count: depth + 1) : "") + quote(keys[index]) + (pretty ? ": " : ":")))
                    }
                }
            }
        }
        return output
    }

    public func value(at pointer: String) -> InspectorJSON? {
        if pointer.isEmpty { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let part = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let values): guard let next = values[part] else { return nil }; current = next
            case .array(let values): guard let index = Int(part), values.indices.contains(index) else { return nil }; current = values[index]
            default: return nil
            }
        }
        return current
    }
    public static func parse(_ data: Data) throws -> InspectorJSON {
        var parser = JSONParser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("JSON 尾部包含多余内容") }
        return result
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    func error(_ message: String) -> NSError { NSError(domain: "ComposeInspect.JSON", code: index, userInfo: [NSLocalizedDescriptionKey: "\(message)（字节 \(index)）"]) }
    mutating func whitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 9, 10, 13, 32: index += 1
            default: return
            }
        }
    }
    mutating func take(_ char: UInt8) -> Bool { whitespace(); if index < bytes.count && bytes[index] == char { index += 1; return true }; return false }
    mutating func value(depth: Int) throws -> InspectorJSON {
        whitespace()
        guard depth < 512, index < bytes.count else { throw error("JSON 不完整或嵌套过深") }
        switch bytes[index] {
        case 123:
            index += 1; var values: [String: InspectorJSON] = [:]
            if take(125) { return .object(values) }
            while true {
                whitespace(); let key = try string()
                guard take(58) else { throw error("对象缺少冒号") }
                values[key] = try value(depth: depth + 1)
                if take(125) { return .object(values) }
                guard take(44) else { throw error("对象缺少逗号") }
            }
        case 91:
            index += 1; var values: [InspectorJSON] = []
            if take(93) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1))
                if take(93) { return .array(values) }
                guard take(44) else { throw error("数组缺少逗号") }
            }
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return .number(try number())
        default: throw error("无效的 JSON 值")
        }
    }
    mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw error("预期 JSON 字符串") }
        let start = index; index += 1
        var escaped = false
        while index < bytes.count {
            let char = bytes[index]; index += 1
            if char == 34 {
                if !escaped {
                    guard let value = String(bytes: bytes[(start + 1)..<(index - 1)], encoding: .utf8) else {
                        throw error("无效的 UTF-8 字符串")
                    }
                    return value
                }
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            guard char >= 32 else { throw error("字符串包含未转义控制字符") }
            if char == 92 {
                escaped = true
                guard index < bytes.count else { throw error("字符串转义不完整") }
                index += 1
            }
        }
        throw error("字符串未闭合")
    }
    mutating func literal(_ literal: String) throws {
        let token = Array(literal.utf8)
        guard index + token.count <= bytes.count, Array(bytes[index..<(index + token.count)]) == token else { throw error("无效的 JSON 常量") }
        index += token.count
    }
    mutating func number() throws -> String {
        let start = index
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw error("数值不完整") }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw error("无效的整数") }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1; let first = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > first else { throw error("小数缺少数字") }
        }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            let first = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > first else { throw error("指数缺少数字") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

public struct InspectorDocument: Codable, Equatable, Sendable {
    public let originalJSON: Data
    public let root: InspectorJSON
    public init(data: Data) throws {
        originalJSON = data; root = try InspectorJSON.parse(data)
        guard root.object != nil else { throw SnapshotImportError.schema("根节点必须为对象") }
    }
    /// Reuse an already validated tree without a second serialization/parser round trip.
    init(root: InspectorJSON) {
        self.root = root
        originalJSON = Data(root.jsonString().utf8)
    }
    public var windows: [InspectorJSON] { root["windows"]?.array ?? [] }
    public var displays: [InspectorJSON] { root["displays"]?.array ?? [] }
    public func window(for pointer: String) -> InspectorJSON? {
        let parts = pointer.split(separator: "/")
        guard parts.count >= 2, parts[0] == "windows", let index = Int(parts[1]), windows.indices.contains(index) else { return nil }
        return windows[index]
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(data: container.decode(Data.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(originalJSON)
    }
}
