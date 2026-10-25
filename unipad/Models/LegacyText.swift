import CoreFoundation
import Foundation

/// Text that is neither UTF-8 nor marked UTF-16: packs were written on Korean Windows, so it is read
/// as CP949 (a superset of EUC-KR). Android and the web read it the same way and never refuse it: a
/// byte that does not start a CP949 character becomes U+FFFD and the ASCII around it is kept, so the
/// numbers and `key=` of a file saved in another code page still parse.
nonisolated enum LegacyText {
    static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0422))

    static func cp949(_ data: Data) -> String {
        if let text = String(data: data, encoding: cp949) { return text }
        let bytes = [UInt8](data)
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                scalars.append(Unicode.Scalar(byte))
                index += 1
            } else if index + 1 < bytes.count,
                      let pair = String(data: Data(bytes[index...index + 1]), encoding: cp949) {
                scalars.append(contentsOf: pair.unicodeScalars)
                index += 2
            } else {
                scalars.append("\u{FFFD}")
                index += 1
            }
        }
        return String(scalars)
    }
}
