import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum DocumentTextError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): coreLocalized("“\(name)” could not be read as text.")
        case .empty(let name): coreLocalized("“\(name)” has no text.")
        }
    }
}

/// Plain text from documents: text, Markdown, RTF, Word, OpenDocument and PDF. HTML is not
/// read, because importing it can load images and styles from the network.
public enum DocumentText {
    public static let readableTypes: [UTType] = [
        .plainText, .rtf, .rtfd, .pdf,
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"), UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }

    public static func read(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw DocumentTextError.unreadable(name) }
            if document.isLocked { throw PDFToolError.locked(name) }
            text = PDFTools.text(of: document)
        } else if type?.conforms(to: .plainText) == true {
            guard let data = try? Data(contentsOf: url) else { throw DocumentTextError.unreadable(name) }
            text = String(decoding: data, as: UTF8.self)
        } else {
            guard let documentType = richTextType(for: type),
                let attributed = try? NSAttributedString(
                    url: url, options: [.documentType: documentType], documentAttributes: nil)
            else { throw DocumentTextError.unreadable(name) }
            text = attributed.string
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentTextError.empty(name) }
        return trimmed
    }

    /// The importer for each rich text format, named explicitly so a file is never sniffed as
    /// HTML, which AppKit would load images and styles for.
    static func richTextType(for type: UTType?) -> NSAttributedString.DocumentType? {
        guard let type else { return nil }
        let formats: [(String, NSAttributedString.DocumentType)] = [
            ("public.rtf", .rtf), ("com.apple.rtfd", .rtfd), ("com.apple.flat-rtfd", .rtfd),
            ("org.openxmlformats.wordprocessingml.document", .officeOpenXML), ("com.microsoft.word.doc", .docFormat),
            ("org.oasis-open.opendocument.text", .openDocument),
        ]
        return formats.first { UTType($0.0).map(type.conforms(to:)) ?? false }?.1
    }

    /// Splits text into pieces of at most `limit` characters, breaking between paragraphs,
    /// then sentences, then words, so each piece fits a language model's context.
    public static func chunks(_ text: String, limit: Int) -> [String] {
        let limit = max(limit, 1)
        var result: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            current = ""
        }
        func add(_ piece: String, separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= limit {
                current += separator + piece
            } else {
                flush()
                current = piece
            }
        }
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if paragraph.count <= limit {
                add(paragraph, separator: "\n\n")
                continue
            }
            for sentence in sentences(paragraph) {
                if sentence.count <= limit {
                    add(sentence, separator: " ")
                } else {
                    for word in sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                        if word.count <= limit {
                            add(word, separator: " ")
                        } else {
                            flush()
                            var rest = Substring(word)
                            while !rest.isEmpty {
                                result.append(String(rest.prefix(limit)))
                                rest = rest.dropFirst(limit)
                            }
                        }
                    }
                }
            }
        }
        flush()
        return result
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [text] : result
    }
}
