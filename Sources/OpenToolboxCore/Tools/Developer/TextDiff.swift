import Foundation

/// Line-based diff built on the standard library's Myers implementation (`CollectionDifference`).
public enum TextDiff {
    public struct Options: Equatable, Sendable {
        public var ignoreCase: Bool
        /// Treat lines that differ only in leading/trailing/repeated whitespace as equal.
        public var ignoreWhitespace: Bool

        public init(ignoreCase: Bool = false, ignoreWhitespace: Bool = false) {
            self.ignoreCase = ignoreCase
            self.ignoreWhitespace = ignoreWhitespace
        }
    }

    public enum Kind: Equatable, Sendable {
        case unchanged, added, removed
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var text: String
        /// 1-based line number in the original text (nil for added lines).
        public var oldNumber: Int?
        /// 1-based line number in the changed text (nil for removed lines).
        public var newNumber: Int?
    }

    public struct Summary: Equatable, Sendable {
        public var added: Int
        public var removed: Int
        public var unchanged: Int
        public var isIdentical: Bool { added == 0 && removed == 0 }
    }

    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if text.last?.isNewline == true { lines.removeLast() }
        return lines
    }

    public static func diff(_ old: String, _ new: String, options: Options = Options()) -> [Line] {
        let oldLines = lines(old)
        let newLines = lines(new)
        let oldKeys = oldLines.map { key($0, options) }
        let newKeys = newLines.map { key($0, options) }
        let difference = newKeys.difference(from: oldKeys)

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                result.append(
                    Line(id: result.count, kind: .removed, text: oldLines[oldIndex], oldNumber: oldIndex + 1, newNumber: nil))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                result.append(
                    Line(id: result.count, kind: .added, text: newLines[newIndex], oldNumber: nil, newNumber: newIndex + 1))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                result.append(
                    Line(
                        id: result.count, kind: .unchanged, text: newLines[newIndex], oldNumber: oldIndex + 1,
                        newNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }

    public static func summary(of lines: [Line]) -> Summary {
        Summary(
            added: lines.count { $0.kind == .added },
            removed: lines.count { $0.kind == .removed },
            unchanged: lines.count { $0.kind == .unchanged })
    }

    /// A unified-diff style rendering (`+`/`-`/space prefixes), handy for copying.
    public static func unifiedText(_ lines: [Line]) -> String {
        lines.map { line in
            switch line.kind {
            case .unchanged: " " + line.text
            case .added: "+" + line.text
            case .removed: "-" + line.text
            }
        }.joined(separator: "\n")
    }

    static func key(_ line: String, _ options: Options) -> String {
        var key = line
        if options.ignoreWhitespace {
            key = key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if options.ignoreCase { key = key.lowercased() }
        return key
    }
}
