# OpenToolbox

An open-source, pure native macOS (Swift / SwiftUI) utility suite designed around privacy, speed, and **on-demand downloads**.

## Core Principles

- **100% Native macOS (macOS 15+):** Built with Swift and SwiftUI using Apple's native frameworks (Vision, PDFKit, AVFoundation, ScreenCaptureKit, ImageIO, Translation, etc.)—no Electron, no web wrappers.
- **On-Demand Engines & Models:** The core app stays lightweight. Pure-Swift and Apple-framework tools work out of the box (0 MB extra). Heavy external tools and AI models (`ffmpeg`, `yt-dlp`, `whisper.cpp`, `7zz`, etc.) are downloaded only when you explicitly choose to install a tool that needs them, verified with SHA-256 checksums, shared across tools, and removable with one click.
- **Private & Offline by Default:** No accounts, no telemetry, no file uploads. Files are processed locally on your Mac.
- **Originals Untouched:** File-processing tools write new outputs into a dedicated folder rather than overwriting source files.

## Roadmap

### Phase 1 (v0.1 — Core Shell & Built-In Tools)
- [ ] Native SwiftUI app shell, sidebar, and quick command palette (`⌘K`)
- [ ] Modular Tool & Engine Manager (install/uninstall per tool/engine, disk usage, SHA-256 verification)
- [ ] Developer utilities (JSON, Base64/Hex, Hash, UUID, JWT, Timestamp, Diff, Regex, Clean Links, Unicode Inspector, Lorem Ipsum, Password Generator, CSV ↔ JSON)
- [ ] Text & File utilities (Word Counter, Case Converter, QR Code, Batch Rename, Find Duplicates)
- [ ] Built-in Image & PDF tools via Apple frameworks (Convert/Resize/Rotate, Strip EXIF, Remove Background, Blur Faces, Merge/Split/Organize PDF, Images ↔ PDF, OCR)
- [ ] Core Mac utilities (Keep Awake, Battery Health, Network Speed Test, Eject All Disks, Quarantine Helper, Hidden Settings)

### Phase 2 — On-Demand Media & Archive Engines
- [ ] `ffmpeg` engine (Video/Audio Compress, Convert, Trim, Mute, Extract Audio, Video to GIF, Media Info)
- [ ] `yt-dlp` engine (Download Video)
- [ ] `7zz` / `unar` engine (ZIP, 7z, RAR, TAR archives)

### Phase 3 — Advanced Editors, System Tools & Local AI
- [ ] Screenshot capture, annotation, beautify, and screen recording
- [ ] PDF signing, form filling, true redaction, and document conversion
- [ ] Local transcription (`whisper.cpp`), audio cleanup, and optional CLI / MCP integration
- [ ] System utilities (Clipboard History, Storage Explorer, App Uninstaller, Display Control, Mouse Fixes)

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors and retain their own open-source licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
