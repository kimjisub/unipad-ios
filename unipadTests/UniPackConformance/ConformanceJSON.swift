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
            guard bytes.count - position >= 4, let code = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16) else { throw ParseError.unexpected(position) }
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
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value):
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"\"]".utf8)
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        case .array(let values): return "[" + values.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { key in
                JSONValue.string(key).serialized() + ":" + values[key]!.serialized()
            }.joined(separator: ",") + "}"
        }
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
