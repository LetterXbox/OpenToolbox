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
        ToolDescriptor(
            id: "dev.color-picker", category: .developer,
            title: "Color Picker", summary: "Pick a color anywhere on screen and copy it as hex, RGB, or HSL.",
            symbolName: "eyedropper", keywords: ["color", "colour", "picker", "eyedropper", "hex", "rgb", "hsl"],
            availability: .planned),
        ToolDescriptor(
            id: "dev.coordinates", category: .developer,
            title: "Coordinate Picker", summary: "Find a place on a map and copy its latitude and longitude.",
            symbolName: "mappin.and.ellipse", keywords: ["coordinates", "latitude", "longitude", "gps", "map", "location", "geo"],
            availability: .planned),
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
        ToolDescriptor(
            id: "text.translate", category: .textAndFiles,
            title: "Translate", summary: "Translate text on-device with Apple Translation.",
            symbolName: "translate", keywords: ["translate", "translation", "language"],
            availability: .planned),
        ToolDescriptor(
            id: "text.speech", category: .textAndFiles,
            title: "Text to Speech", summary: "Read text aloud or save it as an audio file.",
            symbolName: "speaker.wave.2", keywords: ["speech", "speak", "voice", "tts", "read aloud", "audio"],
            availability: .planned),
        ToolDescriptor(
            id: "text.transcribe", category: .textAndFiles,
            title: "Transcribe", summary: "Turn speech in audio and video files into text, on-device.",
            symbolName: "waveform", keywords: ["transcribe", "transcript", "speech", "subtitles", "srt", "dictation"],
            availability: .planned),
        ToolDescriptor(
            id: "text.summarize", category: .textAndFiles,
            title: "Summarize", summary: "Summarize text and documents on-device with Apple Intelligence.",
            symbolName: "sparkles", keywords: ["summarize", "summary", "tldr", "ai", "apple intelligence"],
            availability: .planned),
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
            title: "Organize PDFs", summary: "Merge, split, extract, delete, and rotate PDF pages.",
            symbolName: "doc.richtext", keywords: ["pdf", "merge", "split", "pages", "delete", "remove", "rotate"]),
        ToolDescriptor(
            id: "pdf.images", category: .imagesAndPDF,
            title: "Images ↔ PDF", summary: "Combine images into a PDF or export pages as images.",
            symbolName: "doc.badge.plus", keywords: ["pdf", "images", "export", "combine"]),
        ToolDescriptor(
            id: "image.watermark", category: .imagesAndPDF,
            title: "Watermark", summary: "Add a text or image watermark to images and PDFs.",
            symbolName: "signature", keywords: ["watermark", "stamp", "logo", "copyright", "draft", "pdf"]),
        ToolDescriptor(
            id: "image.compress", category: .imagesAndPDF,
            title: "Compress Images", summary: "Make images smaller by lowering quality or size.",
            symbolName: "arrow.down.right.and.arrow.up.left", keywords: ["compress", "shrink", "smaller", "optimize", "jpeg", "heic", "size"]),
        ToolDescriptor(
            id: "pdf.crop", category: .imagesAndPDF,
            title: "Crop PDF", summary: "Trim the margins of PDF pages.",
            symbolName: "crop", keywords: ["pdf", "crop", "margins", "trim"],
            availability: .planned),
        ToolDescriptor(
            id: "pdf.password", category: .imagesAndPDF,
            title: "PDF Password", summary: "Add a password to a PDF or remove one.",
            symbolName: "lock.doc", keywords: ["pdf", "password", "encrypt", "decrypt", "unlock", "protect"]),
        ToolDescriptor(
            id: "pdf.forms", category: .imagesAndPDF,
            title: "Fill & Flatten Forms", summary: "Fill in PDF forms and flatten them into the page.",
            symbolName: "rectangle.and.pencil.and.ellipsis", keywords: ["pdf", "form", "fill", "flatten", "fields"],
            availability: .planned),
        ToolDescriptor(
            id: "pdf.scan", category: .imagesAndPDF,
            title: "Scan Document", summary: "Scan pages from a scanner or an iPhone into a PDF.",
            symbolName: "doc.viewfinder", keywords: ["scan", "scanner", "document", "iphone", "continuity camera", "pdf"],
            availability: .planned),
        ToolDescriptor(
            id: "pdf.web", category: .imagesAndPDF,
            title: "Web Page to PDF", summary: "Save a web page as a PDF.",
            symbolName: "globe", keywords: ["web", "webpage", "url", "html", "pdf", "save"],
            availability: .planned),
    ]

    // MARK: - Mac Utilities

    static let macUtilities: [ToolDescriptor] = [
        ToolDescriptor(
            id: "mac.keep-awake", category: .macUtilities,
            title: "Keep Awake", summary: "Prevent your Mac from sleeping for a while.",
            symbolName: "cup.and.saucer", keywords: ["caffeinate", "sleep", "awake"]),
        ToolDescriptor(
            id: "mac.battery", category: .macUtilities,
            title: "Battery Health", summary: "Show battery cycle count, capacity, and condition.",
            symbolName: "battery.75percent", keywords: ["battery", "cycles", "health"]),
        ToolDescriptor(
            id: "mac.network-speed", category: .macUtilities,
            title: "Network Speed Test", summary: "Measure network quality with Apple's networkQuality.",
            symbolName: "speedometer", keywords: ["speed", "network", "internet", "bandwidth"]),
        ToolDescriptor(
            id: "mac.disk-speed", category: .macUtilities,
            title: "Disk Speed Test", summary: "Measure a drive's sequential write and read speed.",
            symbolName: "internaldrive", keywords: ["disk", "drive", "ssd", "speed", "benchmark", "read", "write"]),
        ToolDescriptor(
            id: "mac.eject", category: .macUtilities,
            title: "Eject All Disks", summary: "Eject every external and disk-image volume.",
            symbolName: "eject", keywords: ["eject", "unmount", "disk", "volume"]),
        ToolDescriptor(
            id: "mac.quarantine", category: .macUtilities,
            title: "Quarantine Helper", summary: "Inspect and clear the quarantine flag on downloaded files.",
            symbolName: "checkmark.shield", keywords: ["xattr", "quarantine", "gatekeeper"]),
        ToolDescriptor(
            id: "mac.hidden-settings", category: .macUtilities,
            title: "Hidden Settings", summary: "Toggle documented hidden macOS preferences.",
            symbolName: "gearshape.2", keywords: ["defaults", "hidden", "preferences", "tweaks"]),
        ToolDescriptor(
            id: "mac.wifi", category: .macUtilities,
            title: "Wi-Fi Password", summary: "Show a saved Wi-Fi password and share it as a QR code.",
            symbolName: "wifi", keywords: ["wifi", "wi-fi", "password", "network", "qr", "share"],
            availability: .planned),
        ToolDescriptor(
            id: "mac.permissions", category: .macUtilities,
            title: "Reset Permissions", summary: "Reset the privacy permissions an app has been given or denied.",
            symbolName: "hand.raised", keywords: ["permissions", "privacy", "tcc", "tccutil", "camera", "microphone", "screen recording", "reset"],
            availability: .planned),
    ]

    // MARK: - Media

    static let media: [ToolDescriptor] = [
        ToolDescriptor(
            id: "media.record-screen", category: .media,
            title: "Record Screen", summary: "Record the whole screen, a window, or an app.",
            symbolName: "record.circle", keywords: ["record", "screen", "recording", "capture", "video"],
            availability: .planned),
        ToolDescriptor(
            id: "media.record-audio", category: .media,
            title: "Record Audio", summary: "Record sound from a microphone.",
            symbolName: "mic", keywords: ["record", "audio", "microphone", "voice", "memo"],
            availability: .planned),
        ToolDescriptor(
            id: "media.trim-audio", category: .media,
            title: "Trim Audio", summary: "Cut the start and end off an audio file.",
            symbolName: "scissors", keywords: ["trim", "cut", "audio", "clip"],
            availability: .planned),
        ToolDescriptor(
            id: "media.frames", category: .media,
            title: "Extract Frames", summary: "Save frames from a video as images.",
            symbolName: "photo.stack", keywords: ["frames", "video", "stills", "thumbnails", "images"],
            availability: .planned),
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
