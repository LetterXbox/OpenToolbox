import Foundation

/// A parsed JSON document that keeps object key order and number lexemes exactly
/// (unlike `JSONSerialization`, which reorders keys and may round numbers).
public enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written in the source, for example `1.50e3`.
    case number(String)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let lexeme) = self else { return nil }
        return Double(lexeme)
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public struct JSONParseError: Error, Equatable, Sendable, LocalizedError {
    public enum Reason: Equatable, Sendable {
        case emptyInput
        case unexpectedCharacter(String)
        case unexpectedEnd
        case invalidNumber
        case invalidEscape
        case invalidUnicodeEscape
        case controlCharacterInString
        case trailingData
        case nestingTooDeep
    }

    public var reason: Reason
    /// Byte offset into the UTF-8 input.
    public var offset: Int
    /// 1-based line.
    public var line: Int
    /// 1-based column, counted in characters.
    public var column: Int

    public var errorDescription: String? {
        let detail: String = switch reason {
        case .emptyInput: coreLocalized("The input is empty.")
        case .unexpectedCharacter(let character): coreLocalized("Unexpected character “\(character)”.")
        case .unexpectedEnd: coreLocalized("Unexpected end of input.")
        case .invalidNumber: coreLocalized("Invalid number.")
        case .invalidEscape: coreLocalized("Invalid escape sequence in string.")
        case .invalidUnicodeEscape: coreLocalized("Invalid Unicode escape in string.")
        case .controlCharacterInString: coreLocalized("Unescaped control character in string.")
        case .trailingData: coreLocalized("Unexpected data after the JSON value.")
        case .nestingTooDeep: coreLocalized("The document is nested too deeply.")
        }
        if reason == .emptyInput { return detail }
        return coreLocalized("Line \(line), column \(column): \(detail)")
    }
}

/// Strict RFC 8259 parser.
public struct JSONParser {
    public static let maximumDepth = 512

    private let bytes: [UInt8]
    private var index = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        parser.skipWhitespace()
        guard parser.index < parser.bytes.count else { throw parser.error(.emptyInput) }
        let value = try parser.parseDocument()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error(.trailingData) }
        return value
    }

    // MARK: Values

    /// An open container while parsing. The parser keeps these on an explicit
    /// stack instead of recursing, so deep documents cannot overflow small
    /// thread stacks (background tasks get 512 KB).
    private enum Container {
        case array([JSONValue])
        case object([JSONMember], key: String)
    }

    private mutating func parseDocument() throws -> JSONValue {
        var stack: [Container] = []

        while true {
            // Parse one value, or open a container and continue with its first child.
            skipWhitespace()
            guard index < bytes.count else { throw error(.unexpectedEnd) }
            var value: JSONValue
            switch bytes[index] {
            case UInt8(ascii: "{"):
                // Empty containers count toward the depth limit too.
                guard stack.count < Self.maximumDepth else { throw error(.nestingTooDeep) }
                index += 1
                skipWhitespace()
                if peek() == UInt8(ascii: "}") {
                    index += 1
                    value = .object([])
                } else {
                    stack.append(.object([], key: try parseObjectKey()))
                    continue
                }
            case UInt8(ascii: "["):
                // Empty containers count toward the depth limit too.
                guard stack.count < Self.maximumDepth else { throw error(.nestingTooDeep) }
                index += 1
                skipWhitespace()
                if peek() == UInt8(ascii: "]") {
                    index += 1
                    value = .array([])
                } else {
                    stack.append(.array([]))
                    continue
                }
            case UInt8(ascii: "\""):
                value = .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                value = .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                value = .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                value = .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                value = try parseNumber()
            default:
                throw unexpectedCharacterError()
            }

            // Attach the finished value to its parent, closing containers as they end.
            while true {
                guard let parent = stack.popLast() else { return value }
                skipWhitespace()
                switch parent {
                case .array(var elements):
                    elements.append(value)
                    switch peek() {
                    case UInt8(ascii: ","):
                        index += 1
                        stack.append(.array(elements))
                    case UInt8(ascii: "]"):
                        index += 1
                        value = .array(elements)
                        continue
                    default:
                        throw unexpectedCharacterError()
                    }
                case .object(var members, let key):
                    members.append(JSONMember(key: key, value: value))
                    switch peek() {
                    case UInt8(ascii: ","):
                        index += 1
                        skipWhitespace()
                        stack.append(.object(members, key: try parseObjectKey()))
                    case UInt8(ascii: "}"):
                        index += 1
                        value = .object(members)
                        continue
                    default:
                        throw unexpectedCharacterError()
                    }
                }
                break  // A new sibling value follows.
            }
        }
    }

    /// Parses `"key"` and the following `:`.
    private mutating func parseObjectKey() throws -> String {
        guard peek() == UInt8(ascii: "\"") else { throw unexpectedCharacterError() }
        let key = try parseString()
        skipWhitespace()
        guard peek() == UInt8(ascii: ":") else { throw unexpectedCharacterError() }
        index += 1
        return key
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error(.unexpectedEnd) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    index -= 2
                    throw error(.invalidEscape)
                }
            case 0x00..<0x20:
                throw error(.controlCharacterInString)
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw error(.unexpectedEnd)
    }

    /// Parses the hex digits after `\u`, including a following low surrogate if needed.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let start = index - 2
        let high = try readHex4()
        if (0xD800...0xDBFF).contains(high) {
            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
            else {
                index = start
                throw error(.invalidUnicodeEscape)
            }
            index += 2
            let low = try readHex4()
            guard (0xDC00...0xDFFF).contains(low) else {
                index = start
                throw error(.invalidUnicodeEscape)
            }
            let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { throw error(.invalidUnicodeEscape) }
            return scalar
        }
        guard let scalar = Unicode.Scalar(high) else {
            index = start
            throw error(.invalidUnicodeEscape)
        }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error(.unexpectedEnd) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue else {
                throw error(.invalidUnicodeEscape)
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), isDigit(first) else { throw error(.invalidNumber) }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = peek(), isDigit(next) { throw error(.invalidNumber) }
        } else {
            skipDigits()
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            guard let next = peek(), isDigit(next) else { throw error(.invalidNumber) }
            skipDigits()
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard let next = peek(), isDigit(next) else { throw error(.invalidNumber) }
            skipDigits()
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    // MARK: Helpers

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.utf8 {
            guard index < bytes.count else { throw error(.unexpectedEnd) }
            guard bytes[index] == expected else { throw unexpectedCharacterError() }
            index += 1
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private mutating func skipDigits() {
        while let byte = peek(), isDigit(byte) { index += 1 }
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private func unexpectedCharacterError() -> JSONParseError {
        guard index < bytes.count else { return error(.unexpectedEnd) }
        // Decode the full (possibly multi-byte) character at the error position.
        var end = index + 1
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        let character = String(decoding: bytes[index..<end], as: UTF8.self)
        return error(.unexpectedCharacter(character))
    }

    private func error(_ reason: JSONParseError.Reason) -> JSONParseError {
        let offset = min(index, bytes.count)
        var line = 1
        var lineStart = 0
        for position in 0..<offset where bytes[position] == 0x0A {
            line += 1
            lineStart = position + 1
        }
        let column = String(decoding: bytes[lineStart..<offset], as: UTF8.self).count + 1
        return JSONParseError(reason: reason, offset: offset, line: line, column: column)
    }
}

/// Indentation used when pretty-printing.
public enum JSONIndent: Hashable, Sendable, CaseIterable, Identifiable {
    case twoSpaces
    case fourSpaces
    case tab

    public var id: Self { self }

    var unit: String {
        switch self {
        case .twoSpaces: "  "
        case .fourSpaces: "    "
        case .tab: "\t"
        }
    }
}

/// Pretty-prints and minifies JSON without changing key order or number formatting.
public enum JSONFormatter {
    public static func prettyPrinted(_ text: String, indent: JSONIndent = .twoSpaces, sortKeys: Bool = false) throws
        -> String
    {
        serialize(try JSONParser.parse(text), indent: indent, sortKeys: sortKeys)
    }

    public static func minified(_ text: String, sortKeys: Bool = false) throws -> String {
        serialize(try JSONParser.parse(text), indent: nil, sortKeys: sortKeys)
    }

    /// Serializes `value`; `indent == nil` produces the most compact form.
    /// Uses an explicit work stack rather than recursion so deep documents are stack-safe.
    public static func serialize(_ value: JSONValue, indent: JSONIndent?, sortKeys: Bool = false) -> String {
        enum Work {
            case value(JSONValue, level: Int)
            case key(String)
            case literal(String)
            case newline(level: Int)
        }

        let unit = indent?.unit
        var output = ""
        var work: [Work] = [.value(value, level: 0)]

        while let item = work.popLast() {
            switch item {
            case .literal(let text):
                output += text
            case .key(let key):
                writeString(key, into: &output)
                output += unit == nil ? ":" : ": "
            case .newline(let level):
                if let unit {
                    output += "\n"
                    output += String(repeating: unit, count: level)
                }
            case .value(let value, let level):
                switch value {
                case .null: output += "null"
                case .bool(let flag): output += flag ? "true" : "false"
                case .number(let lexeme): output += lexeme
                case .string(let string): writeString(string, into: &output)
                case .array(let elements):
                    guard !elements.isEmpty else {
                        output += "[]"
                        continue
                    }
                    output += "["
                    var children: [Work] = []
                    for (position, element) in elements.enumerated() {
                        if position > 0 { children.append(.literal(",")) }
                        children.append(.newline(level: level + 1))
                        children.append(.value(element, level: level + 1))
                    }
                    children.append(.newline(level: level))
                    children.append(.literal("]"))
                    work.append(contentsOf: children.reversed())
                case .object(let members):
                    guard !members.isEmpty else {
                        output += "{}"
                        continue
                    }
                    let ordered = sortKeys ? members.sorted { $0.key < $1.key } : members
                    output += "{"
                    var children: [Work] = []
                    for (position, member) in ordered.enumerated() {
                        if position > 0 { children.append(.literal(",")) }
                        children.append(.newline(level: level + 1))
                        children.append(.key(member.key))
                        children.append(.value(member.value, level: level + 1))
                    }
                    children.append(.newline(level: level))
                    children.append(.literal("}"))
                    work.append(contentsOf: children.reversed())
                }
            }
        }
        return output
    }

    static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{00}"..."\u{1F}":
                output += "\\u" + String(format: "%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
