import Foundation

/// A JSON value with exact equality: `true` and `1` are different values, which NSNumber-based
/// comparison of JSONSerialization output would not distinguish.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // Swift String equality folds canonical Unicode spellings. JSON observations must preserve
    // the original archive name, even when two entries have identical contents.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            let keysA = a.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let keysB = b.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return keysA.count == keysB.count && zip(keysA, keysB).allSatisfy {
                $0.utf8.elementsEqual($1.utf8) && a[$0] == b[$1]
            }
        default: return false
        }
    }

    /// Foundation's JSON reader drops a byte order mark at the start of a string value, which would
    /// change the bytes of the BOM cases, so the text is read by this small parser instead.
    init(data: Data) throws {
        var parser = Parser(bytes: Array(data))
        self = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw ParseError.unexpected(parser.position) }
    }

    enum ParseError: Error {
        case unexpected(Int)
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { position >= bytes.count }

        mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        mutating func value() throws -> JSONValue {
            skipWhitespace()
            guard position < bytes.count else { throw ParseError.unexpected(position) }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard bytes.count - position >= expected.count, Array(bytes[position..<position + expected.count]) == expected else { throw ParseError.unexpected(position) }
            position += expected.count
        }

        mutating func number() throws -> JSONValue {
            let start = position
            while position < bytes.count, bytes[position] == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
            guard let number = Int(String(decoding: bytes[start..<position], as: UTF8.self)) else { throw ParseError.unexpected(start) }
            return .int(number)
        }

        mutating func array() throws -> JSONValue {
            position += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            while true {
                items.append(try value())
                skipWhitespace()
                guard position < bytes.count else { throw ParseError.unexpected(position) }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                guard bytes[position] == UInt8(ascii: "]") else { throw ParseError.unexpected(position) }
                position += 1
                return .array(items)
            }
        }

        mutating func object() throws -> JSONValue {
            position += 1
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw ParseError.unexpected(position) }
                let key = try string()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw ParseError.unexpected(position) }
                position += 1
                members[key] = try value()
                skipWhitespace()
                guard position < bytes.count else { throw ParseError.unexpected(position) }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                guard bytes[position] == UInt8(ascii: "}") else { throw ParseError.unexpected(position) }
                position += 1
                return .object(members)
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - position >= 4,
                  bytes[position..<position + 4].allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }),
                  let code = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16) else { throw ParseError.unexpected(position) }
            position += 4
            return code
        }

        mutating func string() throws -> String {
            position += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flushRaw() {
                scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
                raw.removeAll()
            }
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "\"") {
                    flushRaw()
                    return String(scalars)
                }
                guard byte == UInt8(ascii: "\\") else { raw.append(byte); continue }
                flushRaw()
                guard position < bytes.count else { break }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "b"): scalars.append("\u{8}")
                case UInt8(ascii: "f"): scalars.append("\u{C}")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                        position += 2
                        let low = try hex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw ParseError.unexpected(position) }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw ParseError.unexpected(position) }
                    scalars.append(scalar)
                default: scalars.append(Unicode.Scalar(escape))
                }
            }
            throw ParseError.unexpected(position)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Compact JSON with sorted keys, so the same value always prints the same.
    func serialized() -> String {
        var text = ""
        appendJSON(to: &text)
        return text
    }

    private func appendJSON(to text: inout String) {
        switch self {
        case .null: text += "null"
        case .bool(let value): text += value ? "true" : "false"
        case .int(let value): text += String(value)
        case .string(let value): Self.appendQuoted(value, to: &text)
        case .array(let values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                value.appendJSON(to: &text)
            }
            text += "]"
        case .object(let values):
            text += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { text += "," }
                Self.appendQuoted(key, to: &text)
                text += ":"
                values[key]!.appendJSON(to: &text)
            }
            text += "}"
        }
    }

    /// Match JSONSerialization's default escaping without creating autoreleased Foundation
    /// objects for every key and string in a pack. Keep Unicode scalars in their original form.
    private static func appendQuoted(_ value: String, to text: inout String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x2F: text += "\\/"
            case 0x08: text += "\\b"
            case 0x0C: text += "\\f"
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0..<0x20:
                text += "\\u00"
                let hex = Array("0123456789abcdef".utf8)
                text.unicodeScalars.append(Unicode.Scalar(hex[Int(scalar.value >> 4)]))
                text.unicodeScalars.append(Unicode.Scalar(hex[Int(scalar.value & 0xF)]))
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}
