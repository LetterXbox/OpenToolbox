import Foundation

public enum ByteEncodingError: Error, Equatable, LocalizedError {
    case invalidBase64
    case invalidHexCharacter(Character)
    case oddHexLength

    public var errorDescription: String? {
        switch self {
        case .invalidBase64: coreLocalized("The input is not valid Base64.")
        case .invalidHexCharacter(let character): coreLocalized("“\(String(character))” is not a hexadecimal digit.")
        case .oddHexLength: coreLocalized("Hexadecimal input must have an even number of digits.")
        }
    }
}

/// Base64, Base64URL, and hexadecimal encoding.
public enum ByteEncoding {
    public static func base64Encode(_ data: Data, urlSafe: Bool = false, padded: Bool = true) -> String {
        var text = data.base64EncodedString()
        if urlSafe {
            text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if !padded {
            while text.hasSuffix("=") { text.removeLast() }
        }
        return text
    }

    /// Decodes standard or URL-safe Base64. Whitespace and missing padding are tolerated.
    public static func base64Decode(_ text: String) throws -> Data {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch cleaned.count % 4 {
        case 0: break
        case 1: throw ByteEncodingError.invalidBase64
        default: cleaned += String(repeating: "=", count: 4 - cleaned.count % 4)
        }
        guard let data = Data(base64Encoded: cleaned) else { throw ByteEncodingError.invalidBase64 }
        return data
    }

    public static func hexEncode(_ data: Data, uppercase: Bool = false, separator: String = "") -> String {
        let digits: [Character] = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
        var parts: [String] = []
        parts.reserveCapacity(data.count)
        for byte in data {
            parts.append(String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]))
        }
        return parts.joined(separator: separator)
    }

    /// Decodes hexadecimal. Accepts `0x` prefixes and whitespace, `:`, `-`, or `,` separators.
    public static func hexDecode(_ text: String) throws -> Data {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "-" || $0 == "," })
        var digits: [UInt8] = []
        for token in tokens {
            var token = Substring(token)
            if token.hasPrefix("0x") || token.hasPrefix("0X") { token = token.dropFirst(2) }
            for character in token {
                guard let value = character.hexDigitValue else { throw ByteEncodingError.invalidHexCharacter(character) }
                digits.append(UInt8(value))
            }
        }
        guard digits.count.isMultiple(of: 2) else { throw ByteEncodingError.oddHexLength }
        var data = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            data.append(digits[index] << 4 | digits[index + 1])
        }
        return data
    }
}
