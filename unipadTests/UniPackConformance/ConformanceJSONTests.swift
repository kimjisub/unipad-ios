import Foundation
import Testing

@Suite(.serialized)
struct ConformanceJSONTests {
    private func foundationString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    @Test func everyUnicodeScalarKeepsFoundationsBytes() throws {
        // Compare UTF-8, since String equality treats composed and decomposed text as equal.
        for start in stride(from: 0, through: 0x10FFFF, by: 4096) {
            try autoreleasepool {
                let scalars = (start..<min(start + 4096, 0x110000)).compactMap(Unicode.Scalar.init)
                let value = String(String.UnicodeScalarView(scalars))
                let expected = try foundationString(value)
                #expect(Array(JSONValue.string(value).serialized().utf8) == Array(expected.utf8))
            }
        }
    }

    @Test func nestedValuesKeepSortedKeysAndExactEscapes() throws {
        let text = "\u{FEFF}e\u{301}/\"\\\n\r\t\u{8}\u{C}\u{0}\u{1F}\u{2028}\u{2029}😀"
        let quoted = try foundationString(text)
        let value: JSONValue = .object([
            "z": .array([.null, .bool(true), .bool(false), .int(Int.min), .int(Int.max)]),
            text: .object(["/": .string(text)]),
            "a": .array([]),
        ])
        let expected = "{\"a\":[],\"z\":[null,true,false,\(Int.min),\(Int.max)],\(quoted):{\"\\/\":\(quoted)}}"
        #expect(Array(value.serialized().utf8) == Array(expected.utf8))
        #expect(try JSONValue(data: Data(value.serialized().utf8)) == value)
        #expect(JSONValue.string("").serialized() == "\"\"")
        #expect(JSONValue.object([:]).serialized() == "{}")
    }

    @Test func manyStringsDoNotRetainLargeSerializationTemporaries() throws {
        try autoreleasepool {
            let value = JSONValue.array(Array(repeating: .object(["file": "sounds/kick.wav"]), count: 100_000))
            _ = JSONValue.string("warmup").serialized()
            let before = try #require(TestProcessMemory.physicalFootprint(), "could not measure the process footprint")
            let text = value.serialized()
            let after = try #require(TestProcessMemory.physicalFootprint(), "could not measure the process footprint")
            #expect(text.utf8.count == 2_800_001)
            #expect(after < before + 64 * 1024 * 1024,
                    "serializing 100,000 small objects retained \(after > before ? after - before : 0) bytes")
        }
    }
}
