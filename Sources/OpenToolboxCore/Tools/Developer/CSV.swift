import Foundation

public enum CSVError: Error, Equatable, LocalizedError {
    case unterminatedQuote(line: Int)
    case notAnArrayOfObjects

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote(let line): coreLocalized("A quoted field starting on line \(line) is never closed.")
        case .notAnArrayOfObjects: coreLocalized("JSON must be an array of objects (or an array of arrays) to convert to CSV.")
        }
    }
}

/// RFC 4180 CSV parsing and writing, plus CSV ↔ JSON conversion.
public enum CSV {
    /// Parses CSV into rows of fields. Handles quoted fields, doubled quotes, and CRLF/LF line endings.
    public static func parse(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var line = 1
        var quoteStartLine = 1
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func endField() {
            row.append(field)
            field = ""
            fieldWasQuoted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character.isNewline { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty && !fieldWasQuoted:
                inQuotes = true
                fieldWasQuoted = true
                quoteStartLine = line
            case delimiter:
                endField()
            case "\r\n", "\n", "\r":
                endRow()
                line += 1
            default:
                field.append(character)
            }
        }
        if inQuotes { throw CSVError.unterminatedQuote(line: quoteStartLine) }
        if !field.isEmpty || fieldWasQuoted || !row.isEmpty { endRow() }
        return rows
    }

    /// Picks the most likely delimiter among `,`, `;`, tab, and `|` from the first line.
    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { !$0.isNewline }
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
    }

    public static func write(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\n")
    }

    static func escape(_ field: String, delimiter: Character) -> String {
        let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains(where: \.isNewline)
            || field.first == " " || field.last == " "
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Conversion

    public struct ToJSONOptions: Equatable, Sendable {
        /// Use the first row as object keys; otherwise output an array of arrays.
        public var firstRowIsHeader: Bool
        /// Turn `123`, `1.5`, `true`, `false`, and empty cells into JSON numbers, booleans, and null.
        public var inferTypes: Bool

        public init(firstRowIsHeader: Bool = true, inferTypes: Bool = true) {
            self.firstRowIsHeader = firstRowIsHeader
            self.inferTypes = inferTypes
        }
    }

    public static func toJSON(
        _ text: String,
        delimiter: Character? = nil,
        options: ToJSONOptions = ToJSONOptions(),
        indent: JSONIndent? = .twoSpaces
    ) throws -> String {
        let rows = try parse(text, delimiter: delimiter ?? detectDelimiter(text))
        let value: JSONValue
        if options.firstRowIsHeader, let header = rows.first {
            let keys = uniqueKeys(header)
            value = .array(
                rows.dropFirst().map { row -> JSONValue in
                    JSONValue.object(
                        keys.enumerated().map { index, key in
                            JSONMember(key: key, value: cell(index < row.count ? row[index] : "", infer: options.inferTypes))
                        })
                })
        } else {
            value = .array(rows.map { JSONValue.array($0.map { cell($0, infer: options.inferTypes) }) })
        }
        return JSONFormatter.serialize(value, indent: indent)
    }

    public static func fromJSON(_ text: String, delimiter: Character = ",") throws -> String {
        guard case .array(let elements) = try JSONParser.parse(text) else { throw CSVError.notAnArrayOfObjects }
        if elements.allSatisfy({ if case .array = $0 { true } else { false } }) {
            let rows = elements.map { element -> [String] in
                guard case .array(let cells) = element else { return [] }
                return cells.map(fieldText)
            }
            return write(rows, delimiter: delimiter)
        }
        var keys: [String] = []
        var seen = Set<String>()
        var objects: [[JSONMember]] = []
        for element in elements {
            guard case .object(let members) = element else { throw CSVError.notAnArrayOfObjects }
            objects.append(members)
            for member in members where seen.insert(member.key).inserted {
                keys.append(member.key)
            }
        }
        let rows = [keys] + objects.map { members in
            keys.map { key in members.last(where: { $0.key == key }).map { fieldText($0.value) } ?? "" }
        }
        return write(rows, delimiter: delimiter)
    }

    static func uniqueKeys(_ header: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return header.enumerated().map { index, raw in
            let base = raw.isEmpty ? "column\(index + 1)" : raw
            let count = counts[base, default: 0] + 1
            counts[base] = count
            return count == 1 ? base : "\(base)_\(count)"
        }
    }

    static func cell(_ text: String, infer: Bool) -> JSONValue {
        guard infer else { return .string(text) }
        switch text {
        case "": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            // Only plain JSON number syntax; keeps "007" and "1e5x" as strings.
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == text, let number = try? JSONParser.parse(text),
                case .number = number
            {
                return number
            }
            return .string(text)
        }
    }

    static func fieldText(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): string
        case .number(let lexeme): lexeme
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        case .array, .object: JSONFormatter.serialize(value, indent: nil)
        }
    }
}
