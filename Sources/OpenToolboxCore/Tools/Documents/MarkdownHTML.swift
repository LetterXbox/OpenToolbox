import Foundation
import Markdown

/// Converts Markdown (including GFM tables, strikethrough, and task lists) into
/// self-contained, offline print-ready HTML using `swift-markdown`.
public enum MarkdownHTML {
    public static func renderDocument(_ markdown: String, title: String? = nil) -> String {
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor()
        visitor.visit(document)
        let heading = title.map(escapeHTML) ?? "Markdown Document"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:;">
        <title>\(heading)</title>
        <style>
        :root { color-scheme: light; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.65;
            color: #1c1c1e;
            background: #ffffff;
            margin: 0;
            padding: 24px 32px;
            word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            line-height: 1.25;
            margin: 1.2em 0 0.5em;
            color: #111111;
        }
        h1 { font-size: 2em; border-bottom: 1px solid #e5e5ea; padding-bottom: 0.25em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid #e5e5ea; padding-bottom: 0.2em; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1.05em; }
        p { margin: 0.65em 0; }
        a { color: #0a66c2; text-decoration: none; }
        code {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 0.9em;
            background: #f2f2f7;
            padding: 0.15em 0.35em;
            border-radius: 4px;
        }
        pre {
            background: #f2f2f7;
            padding: 12px 14px;
            border-radius: 6px;
            overflow-x: auto;
            margin: 0.8em 0;
        }
        pre code {
            background: transparent;
            padding: 0;
            font-size: 0.86em;
            line-height: 1.5;
        }
        blockquote {
            margin: 0.8em 0;
            padding: 0.2em 1em;
            border-left: 3px solid #c7c7cc;
            color: #555558;
        }
        ul, ol { margin: 0.6em 0; padding-left: 1.8em; }
        li { margin: 0.25em 0; }
        li.task-item { list-style-type: none; margin-left: -1.2em; }
        hr { border: 0; border-top: 1px solid #d1d1d6; margin: 1.4em 0; }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        th, td { border: 1px solid #d1d1d6; padding: 6px 10px; text-align: left; }
        th { background: #f2f2f7; font-weight: 600; }
        img { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(visitor.html)
        </body>
        </html>
        """
    }

    public static func renderBody(_ markdown: String) -> String {
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor()
        visitor.visit(document)
        return visitor.html
    }

    static func escapeHTML(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&#39;")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func sanitizedLinkURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        guard ["http", "https", "mailto"].contains(scheme) else { return nil }
        return trimmed
    }

    private struct HTMLVisitor: MarkupWalker {
        var html = ""
        private var currentColumnAlignments: [Table.ColumnAlignment?] = []
        private var currentCellIndex = 0
        private var inTableHead = false

        mutating func visitHeading(_ heading: Heading) {
            let level = min(max(heading.level, 1), 6)
            html.append("<h\(level)>")
            descendInto(heading)
            html.append("</h\(level)>\n")
        }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            html.append("<p>")
            descendInto(paragraph)
            html.append("</p>\n")
        }

        mutating func visitText(_ text: Text) {
            html.append(MarkdownHTML.escapeHTML(text.string))
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) {
            html.append("\n")
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) {
            html.append("<br>\n")
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            html.append("<em>")
            descendInto(emphasis)
            html.append("</em>")
        }

        mutating func visitStrong(_ strong: Strong) {
            html.append("<strong>")
            descendInto(strong)
            html.append("</strong>")
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            html.append("<del>")
            descendInto(strikethrough)
            html.append("</del>")
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            html.append("<code>")
            html.append(MarkdownHTML.escapeHTML(inlineCode.code))
            html.append("</code>")
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            if let language = codeBlock.language, !language.isEmpty {
                let safeLang = language.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                html.append("<pre><code class=\"language-\(safeLang)\">")
            } else {
                html.append("<pre><code>")
            }
            html.append(MarkdownHTML.escapeHTML(codeBlock.code))
            html.append("</code></pre>\n")
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            html.append("<blockquote>\n")
            descendInto(blockQuote)
            html.append("</blockquote>\n")
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
            html.append("<ul>\n")
            descendInto(unorderedList)
            html.append("</ul>\n")
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            if orderedList.startIndex != 1 {
                html.append("<ol start=\"\(orderedList.startIndex)\">\n")
            } else {
                html.append("<ol>\n")
            }
            descendInto(orderedList)
            html.append("</ol>\n")
        }

        mutating func visitListItem(_ listItem: ListItem) {
            if let checkbox = listItem.checkbox {
                let mark = checkbox == .checked ? "&#9745;" : "&#9744;"
                html.append("<li class=\"task-item\">\(mark) ")
            } else {
                html.append("<li>")
            }
            descendInto(listItem)
            html.append("</li>\n")
        }

        mutating func visitLink(_ link: Link) {
            if let safe = MarkdownHTML.sanitizedLinkURL(link.destination) {
                html.append("<a href=\"\(MarkdownHTML.escapeHTML(safe))\">")
                descendInto(link)
                html.append("</a>")
            } else {
                descendInto(link)
            }
        }

        mutating func visitImage(_ image: Image) {
            let alt = image.plainText
            if let source = image.source, source.lowercased().hasPrefix("data:image/") {
                html.append("<img src=\"\(MarkdownHTML.escapeHTML(source))\" alt=\"\(MarkdownHTML.escapeHTML(alt))\">")
            } else if !alt.isEmpty {
                html.append("<span>[\(MarkdownHTML.escapeHTML(alt))]</span>")
            }
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            html.append("<hr>\n")
        }

        mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
            html.append("<pre><code>\(MarkdownHTML.escapeHTML(htmlBlock.rawHTML))</code></pre>\n")
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            html.append(MarkdownHTML.escapeHTML(inlineHTML.rawHTML))
        }

        mutating func visitTable(_ table: Table) {
            let previous = currentColumnAlignments
            currentColumnAlignments = table.columnAlignments
            html.append("<table>\n")
            descendInto(table)
            html.append("</table>\n")
            currentColumnAlignments = previous
        }

        mutating func visitTableHead(_ tableHead: Table.Head) {
            inTableHead = true
            html.append("<thead>\n<tr>")
            currentCellIndex = 0
            descendInto(tableHead)
            html.append("</tr>\n</thead>\n")
            inTableHead = false
        }

        mutating func visitTableBody(_ tableBody: Table.Body) {
            html.append("<tbody>\n")
            descendInto(tableBody)
            html.append("</tbody>\n")
        }

        mutating func visitTableRow(_ tableRow: Table.Row) {
            html.append("<tr>")
            currentCellIndex = 0
            descendInto(tableRow)
            html.append("</tr>\n")
        }

        mutating func visitTableCell(_ tableCell: Table.Cell) {
            let tag = inTableHead ? "th" : "td"
            let alignment = currentCellIndex < currentColumnAlignments.count ? currentColumnAlignments[currentCellIndex] : nil
            let style: String = switch alignment {
            case .left: " style=\"text-align: left\""
            case .center: " style=\"text-align: center\""
            case .right: " style=\"text-align: right\""
            case nil: ""
            }
            html.append("<\(tag)\(style)>")
            descendInto(tableCell)
            html.append("</\(tag)>")
            currentCellIndex += 1
        }
    }
}
