import Foundation

/// The single source of truth for every tool OpenToolbox knows about.
public enum ToolCatalog {
    public static let all: [ToolDescriptor] = developer + textAndFiles + imagesAndPDF + macUtilities + media

    public static func tool(_ id: ToolID) -> ToolDescriptor? {
        all.first { $0.id == id }
    }

    public static func tools(in category: ToolCategory, from tools: [ToolDescriptor] = all) -> [ToolDescriptor] {
        tools.filter { $0.category == category }
    }

    /// Engines needed by the given tools, deduplicated and in first-seen order.
    /// Several tools sharing one engine install it only once.
    public static func engines(requiredBy tools: [ToolDescriptor]) -> [EngineID] {
        var seen = Set<EngineID>()
        var result: [EngineID] = []
        for engine in tools.flatMap(\.requiredEngines) where seen.insert(engine).inserted {
            result.append(engine)
        }
        return result
    }

    /// Tools that depend on an engine.
    public static func tools(requiring engine: EngineID, from tools: [ToolDescriptor] = all) -> [ToolDescriptor] {
        tools.filter { $0.requiredEngines.contains(engine) }
    }

    // MARK: - Developer

    static let developer: [ToolDescriptor] = [
        ToolDescriptor(
            id: "dev.json-formatter", category: .developer,
            title: "JSON Formatter", summary: "Format, minify, and validate JSON.",
            symbolName: "curlybraces", keywords: ["json", "pretty", "minify", "validate", "beautify"]),
        ToolDescriptor(
            id: "dev.base64-hex", category: .developer,
            title: "Base64 / Hex", summary: "Encode and decode Base64, Base64URL, and hexadecimal.",
            symbolName: "number", keywords: ["base64", "hex", "encode", "decode", "base64url"]),
        ToolDescriptor(
            id: "dev.hash", category: .developer,
            title: "Hash Generator", summary: "Compute MD5, SHA-1, and SHA-2 digests of text or files.",
            symbolName: "number.square", keywords: ["md5", "sha1", "sha256", "sha512", "checksum", "digest"]),
        ToolDescriptor(
            id: "dev.uuid", category: .developer,
            title: "UUID Generator", summary: "Generate and inspect UUID v4 and v7 identifiers.",
            symbolName: "tag", keywords: ["uuid", "guid", "v4", "v7", "identifier"]),
        ToolDescriptor(
            id: "dev.jwt", category: .developer,
            title: "JWT Decoder", summary: "Decode JSON Web Token headers and claims.",
            symbolName: "key.horizontal", keywords: ["jwt", "token", "jws", "claims", "bearer"]),
        ToolDescriptor(
            id: "dev.timestamp", category: .developer,
            title: "Timestamp Converter", summary: "Convert Unix timestamps and ISO 8601 dates.",
            symbolName: "clock", keywords: ["unix", "epoch", "date", "time", "iso8601"]),
        ToolDescriptor(
            id: "dev.diff", category: .developer,
            title: "Diff Checker", summary: "Compare two texts line by line.",
            symbolName: "arrow.left.arrow.right", keywords: ["diff", "compare"]),
        ToolDescriptor(
            id: "dev.regex", category: .developer,
            title: "Regex Tester", summary: "Test regular expressions against sample text.",
            symbolName: "asterisk", keywords: ["regex", "regexp", "pattern", "match"]),
        ToolDescriptor(
            id: "dev.clean-links", category: .developer,
            title: "Clean Links", summary: "Strip tracking parameters from URLs.",
            symbolName: "link", keywords: ["url", "utm", "tracking", "link"]),
        ToolDescriptor(
            id: "dev.unicode", category: .developer,
            title: "Unicode Inspector", summary: "Inspect code points, names, and encodings of characters.",
            symbolName: "character", keywords: ["unicode", "utf8", "codepoint", "emoji"]),
        ToolDescriptor(
            id: "dev.lorem", category: .developer,
            title: "Lorem Ipsum", summary: "Generate placeholder text.",
            symbolName: "text.alignleft", keywords: ["lorem", "placeholder", "dummy"]),
        ToolDescriptor(
            id: "dev.password", category: .developer,
            title: "Password Generator", summary: "Generate strong random passwords.",
            symbolName: "lock.shield", keywords: ["password", "passphrase", "random"]),
        ToolDescriptor(
            id: "dev.csv-json", category: .developer,
            title: "CSV ↔ JSON", summary: "Convert between CSV and JSON.",
            symbolName: "tablecells", keywords: ["csv", "json", "table", "convert"]),
    ]

    // MARK: - Text & Files

    static let textAndFiles: [ToolDescriptor] = [
        ToolDescriptor(
            id: "text.word-counter", category: .textAndFiles,
            title: "Word Counter", summary: "Count words, characters, sentences, and lines.",
            symbolName: "textformat.123", keywords: ["count", "words", "characters"]),
        ToolDescriptor(
            id: "text.case-converter", category: .textAndFiles,
            title: "Case Converter", summary: "Convert text between camelCase, snake_case, Title Case, and more.",
            symbolName: "textformat", keywords: ["case", "camel", "snake", "kebab", "upper", "lower"]),
        ToolDescriptor(
            id: "text.qr-code", category: .textAndFiles,
            title: "QR Code", summary: "Generate and read QR codes.",
            symbolName: "qrcode", keywords: ["qr", "barcode", "scan"]),
        ToolDescriptor(
            id: "files.batch-rename", category: .textAndFiles,
            title: "Batch Rename", summary: "Rename many files with patterns and previews.",
            symbolName: "pencil.line", keywords: ["rename", "files", "batch"]),
        ToolDescriptor(
            id: "files.duplicates", category: .textAndFiles,
            title: "Find Duplicates", summary: "Find duplicate files by content.",
            symbolName: "doc.on.doc", keywords: ["duplicate", "dedupe", "files"]),
    ]

    // MARK: - Images & PDF

    static let imagesAndPDF: [ToolDescriptor] = [
        ToolDescriptor(
            id: "image.convert", category: .imagesAndPDF,
            title: "Convert Images", summary: "Convert, resize, and rotate images.",
            symbolName: "photo", keywords: ["image", "resize", "rotate", "heic", "png", "jpeg", "webp"]),
        ToolDescriptor(
            id: "image.strip-metadata", category: .imagesAndPDF,
            title: "Strip EXIF", summary: "Remove location and camera metadata from images.",
            symbolName: "eye.slash", keywords: ["exif", "metadata", "gps", "privacy"]),
        ToolDescriptor(
            id: "image.remove-background", category: .imagesAndPDF,
            title: "Remove Background", summary: "Lift subjects from photos on-device.",
            symbolName: "person.crop.rectangle", keywords: ["background", "cutout", "subject"]),
        ToolDescriptor(
            id: "image.blur-faces", category: .imagesAndPDF,
            title: "Blur Faces", summary: "Detect and blur faces on-device.",
            symbolName: "face.dashed", keywords: ["blur", "faces", "privacy", "anonymize"]),
        ToolDescriptor(
            id: "image.ocr", category: .imagesAndPDF,
            title: "Extract Text (OCR)", summary: "Recognize text in images and PDFs on-device.",
            symbolName: "text.viewfinder", keywords: ["ocr", "text", "recognize", "scan"]),
        ToolDescriptor(
            id: "pdf.organize", category: .imagesAndPDF,
            title: "Organize PDFs", summary: "Merge, split, and reorder PDF pages.",
            symbolName: "doc.richtext", keywords: ["pdf", "merge", "split", "pages"]),
        ToolDescriptor(
            id: "pdf.images", category: .imagesAndPDF,
            title: "Images ↔ PDF", summary: "Combine images into a PDF or export pages as images.",
            symbolName: "doc.badge.plus", keywords: ["pdf", "images", "export", "combine"]),
    ]

    // MARK: - Mac Utilities

    static let macUtilities: [ToolDescriptor] = [
        ToolDescriptor(
            id: "mac.keep-awake", category: .macUtilities,
            title: "Keep Awake", summary: "Prevent your Mac from sleeping for a while.",
            symbolName: "cup.and.saucer", keywords: ["caffeinate", "sleep", "awake"], availability: .planned),
        ToolDescriptor(
            id: "mac.battery", category: .macUtilities,
            title: "Battery Health", summary: "Show battery cycle count, capacity, and condition.",
            symbolName: "battery.75percent", keywords: ["battery", "cycles", "health"], availability: .planned),
        ToolDescriptor(
            id: "mac.network-speed", category: .macUtilities,
            title: "Network Speed Test", summary: "Measure network quality with Apple's networkQuality.",
            symbolName: "speedometer", keywords: ["speed", "network", "internet", "bandwidth"],
            availability: .planned),
        ToolDescriptor(
            id: "mac.eject", category: .macUtilities,
            title: "Eject All Disks", summary: "Eject every external and disk-image volume.",
            symbolName: "eject", keywords: ["eject", "unmount", "disk", "volume"], availability: .planned),
        ToolDescriptor(
            id: "mac.quarantine", category: .macUtilities,
            title: "Quarantine Helper", summary: "Inspect and clear the quarantine flag on downloaded files.",
            symbolName: "checkmark.shield", keywords: ["xattr", "quarantine", "gatekeeper"], availability: .planned),
        ToolDescriptor(
            id: "mac.hidden-settings", category: .macUtilities,
            title: "Hidden Settings", summary: "Toggle documented hidden macOS preferences.",
            symbolName: "gearshape.2", keywords: ["defaults", "hidden", "preferences", "tweaks"],
            availability: .planned),
    ]

    // MARK: - Media (on-demand engines)

    static let media: [ToolDescriptor] = [
        ToolDescriptor(
            id: "media.convert", category: .media,
            title: "Convert Video & Audio", summary: "Convert, compress, and trim media files.",
            symbolName: "film", keywords: ["video", "audio", "convert", "compress", "mp4", "mp3"],
            requiredEngines: [EngineCatalog.ffmpegID], availability: .planned),
        ToolDescriptor(
            id: "media.download", category: .media,
            title: "Download Video", summary: "Download videos from supported sites.",
            symbolName: "arrow.down.circle", keywords: ["download", "video", "youtube", "url"],
            requiredEngines: [EngineCatalog.ytDlpID, EngineCatalog.ffmpegID], availability: .planned),
    ]
}
