# OpenToolbox

An open-source, pure native macOS (Swift / SwiftUI) utility suite designed around privacy, speed, and **on-demand downloads**.

## Core Principles

- **100% Native macOS (macOS 15+):** Built with Swift and SwiftUI using Apple's native frameworks (Vision, PDFKit, AVFoundation, ScreenCaptureKit, ImageIO, Translation, etc.)—no Electron, no web wrappers.
- **On-Demand Engines & Models:** The core app stays lightweight. Pure-Swift and Apple-framework tools work out of the box (0 MB extra). Heavy external tools and AI models (`ffmpeg`, `yt-dlp`, `whisper.cpp`, `7zz`, etc.) are downloaded only when you explicitly choose to install a tool that needs them, verified with SHA-256 checksums, shared across tools, and removable with one click.
- **Private & Offline by Default:** No accounts, no telemetry, no file uploads. Files are processed locally on your Mac.
- **Originals Untouched:** File-processing tools write new outputs into a dedicated folder rather than overwriting source files.

## Roadmap

### Phase 1 (v0.1 — Core Shell & Built-In Tools)
- [x] Native SwiftUI app shell, sidebar, and quick command palette (`⌘K`)
- [x] Modular Tool & Engine Manager (enable/disable per tool, on-demand engine install/uninstall, disk usage, SHA-256 verification)
- [x] Developer utilities (JSON, Base64/Hex, Hash, UUID, JWT, Timestamp, Diff, Regex, Clean Links, Unicode Inspector, Lorem Ipsum, Password Generator, CSV ↔ JSON)
- [x] Text & File utilities (Word Counter, Case Converter, QR Code, Batch Rename, Find Duplicates)
- [x] Built-in Image & PDF tools via Apple frameworks (Convert/Resize/Rotate, Strip EXIF, Remove Background, Blur Faces, Merge/Split/Extract/Rotate PDF pages, Images ↔ PDF, OCR)
- [ ] Visual PDF page organizer (drag to reorder, delete pages)
- [x] Core Mac utilities (Keep Awake, Battery Health, Network Speed Test, Eject All Disks, Quarantine Helper, Hidden Settings)
- [ ] Release `.app` bundle built from an Xcode application target. Releases are unsigned for now: on first launch, approve the app in System Settings → Privacy & Security → **Open Anyway**.
- [ ] Later, optional: Developer ID signing and notarization

### v0.1.1 — Known v0.1 limitations to close
- [ ] Find Duplicates → Move to Trash: report "uncertain" instead of auto-recovering when the trashed item cannot be proven to be the reviewed file (two coincident races; see `docs/reviews/resolver-trash-recovery.md`)
- [ ] PDF exports: pin the calendar as well as the date per run, so a time-zone change mid-export cannot split outputs across two dated folders

### Phase 2 — On-Demand Media & Archive Engines
- [ ] `ffmpeg` engine — manifest schema and Engine Manager UI ready; verified builds not pinned yet (Video/Audio Compress, Convert, Trim, Mute, Extract Audio, Video to GIF, Media Info)
- [ ] `yt-dlp` engine — manifest schema and Engine Manager UI ready; verified builds not pinned yet (Download Video)
- [ ] `7zz` / `unar` engine (ZIP, 7z, RAR, TAR archives)

### Phase 3 — Advanced Editors, System Tools & Local AI
- [ ] Screenshot capture, annotation, beautify, and screen recording
- [ ] PDF signing, form filling, true redaction, and document conversion
- [ ] Local transcription (`whisper.cpp`), audio cleanup, and optional CLI / MCP integration
- [ ] System utilities (Clipboard History, Storage Explorer, App Uninstaller, Display Control, Mouse Fixes)

## Building

Requires macOS 15+ and Xcode 16 or later (Swift 6 toolchain).

```sh
swift build                 # build the core library and the app
swift test                  # run OpenToolboxCore unit tests (Swift Testing)
swift run OpenToolbox       # launch the app from the command line
```

You can also open `Package.swift` in Xcode and run the `OpenToolbox` scheme.

To build a universal, ad-hoc signed `OpenToolbox.app` with a release zip and a disk image (`.dmg`), run `scripts/package-app.sh <version>` on a Mac. The output goes to `.build/release-app/dist/`.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/OpenToolboxCore` | UI-free logic: tool catalog, engine manager (`EngineStore`), output-folder helper, and tool implementations. Fully unit-tested. |
| `Sources/OpenToolboxApp` | SwiftUI shell: sidebar, `⌘K` command palette, tool catalog, Engine Manager, and tool views. |
| `Tests/OpenToolboxCoreTests` | Unit tests. They never use the network or the real Application Support folder. |

### Conventions

- **Strings:** every user-facing literal goes through `L("…")` (app) or `coreLocalized("…")` (core) so it lands in the `Localizable.xcstrings` catalogs. English is the source language.
- **Engines:** manifests ship with the app (`EngineCatalog`). Each artifact is pinned per CPU architecture with an HTTPS URL, byte size, and SHA-256. Installs download to a staging folder, verify size and checksum, then move into `~/Library/Application Support/OpenToolbox/engines/<id>/` in one rename. Engines that have no verified pinned build yet are listed as "Coming soon" and cannot be installed.
- **Outputs:** file tools write to `<output folder>/<yyyy-MM-dd>/<tool>/` with collision-safe names, and never overwrite the source file.

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors and retain their own open-source licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
