import Foundation

/// Ranks tools for the quick command palette.
public enum CommandSearch {
    /// Returns tools matching `query`, best first. An empty query returns `tools` unchanged.
    public static func rank(_ query: String, in tools: [ToolDescriptor]) -> [ToolDescriptor] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return tools }

        let scored: [(index: Int, score: Int, tool: ToolDescriptor)] = tools.enumerated().compactMap { index, tool in
            let value = Self.score(needle: needle, tool: tool)
            return value > 0 ? (index: index, score: value, tool: tool) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.tool)
    }

    /// Higher is better; 0 means no match.
    static func score(needle: String, tool: ToolDescriptor) -> Int {
        let titles = [normalize(tool.localizedTitle), normalize(tool.titleKey)]
        var best = 0
        for title in titles {
            if title == needle {
                best = max(best, 1000)
            } else if title.hasPrefix(needle) {
                best = max(best, 800)
            } else if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                best = max(best, 600)
            } else if title.contains(needle) {
                best = max(best, 400)
            }
        }
        if tool.keywords.contains(where: { normalize($0).hasPrefix(needle) }) {
            best = max(best, 500)
        }
        if best == 0, titles.contains(where: { isSubsequence(needle, of: $0) }) {
            best = 100
        }
        return best
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle where character != " " {
            var found = false
            while let next = iterator.next() {
                if next == character {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }
}
