# OpenToolbox

An open-source, pure native macOS (Swift / SwiftUI) utility suite designed around privacy, speed, and **on-demand downloads**.

## Core Principles

- **100% Native macOS (macOS 15+):** Built with Swift and SwiftUI using Apple's native frameworks (Vision, PDFKit, AVFoundation, ScreenCaptureKit, ImageIO, Translation, etc.)—no Electron, no web wrappers.
- **On-Demand Engines & Models:** The core app stays lightweight. Pure-Swift and Apple-framework tools work out of the box (0 MB extra). Heavy external tools and AI models (`ffmpeg`, `yt-dlp`, `whisper.cpp`, `7zz`, etc.) are downloaded only when you explicitly choose to install a tool that needs them, verified with SHA-256 checksums, shared across tools, and removable with one click.
- **Private & Offline by Default:** No accounts, no telemetry, no file uploads. Files are processed locally on your Mac.
- **Originals Untouched:** File-processing tools write new outputs into a dedicated folder rather than overwriting source files.

## Features

**Developer:** JSON Formatter, Base64 / Hex, Hash Generator, UUID Generator, JWT Decoder, Timestamp Converter, Diff Checker, Regex Tester, Clean Links, Unicode Inspector, Lorem Ipsum, Password Generator, CSV ↔ JSON.

**Text & Files:** Word Counter, Case Converter, QR Code, Batch Rename, Find Duplicates.

**Images & PDF** (Apple frameworks): Convert Images (format, resize, rotate), Strip EXIF, Remove Background, Blur Faces, Extract Text (OCR), Organize PDFs (merge, split, extract and rotate pages), Images ↔ PDF.

**Mac utilities:** Keep Awake, Battery Health, Network Speed Test, Eject All Disks, Quarantine Helper, Hidden Settings.

**App:** sidebar, Quick Open (`⌘K`), and an Engine Manager to enable or disable tools and to install or remove on-demand engines. Convert Video & Audio (`ffmpeg`) and Download Video (`yt-dlp`) are listed as "Coming soon" until verified engine builds are pinned.

## Install

1. Download the latest `OpenToolbox-<version>-macOS-universal.dmg` from [Releases](https://github.com/LetterXbox/OpenToolbox/releases) and open it.
2. Drag **OpenToolbox** onto the **Applications** folder.
3. Open it from Applications. Releases are not signed with an Apple Developer ID, so macOS blocks the first launch: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You do this once per version.

Requires macOS 15 or later, on Apple silicon or Intel. Each release lists the disk image's SHA-256 so you can check it with `shasum -a 256`.

## Known limitations

- Releases are not notarized (see Install).
- Switching to another tool resets the one you left and stops a running Network Speed Test.
- With two OpenToolbox windows open, `⌘K` shows Quick Open in both.

## Building

Requires macOS 15+ and Xcode 16 or later (Swift 6 toolchain).

```sh
swift build                 # build the core library and the app
swift test                  # run OpenToolboxCore unit tests (Swift Testing)
swift run OpenToolbox       # launch the app from the command line
```

You can also open `Package.swift` in Xcode and run the `OpenToolbox` scheme.

To build a universal, ad-hoc signed `OpenToolbox.app` and its release disk image (`.dmg`), run `scripts/package-app.sh <version>` on a Mac. The output goes to `.build/release-app/dist/`.

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

## Contributing

Issues and pull requests are welcome. Two rules apply to every contribution:

- **Clean room:** write everything from scratch with public Apple frameworks, standard open-source tools, and original code, UI text and assets. Never download, decompile or copy binaries, source code, icons or UI text from other utility apps, including the ones named below.
- **Engines stay separate:** external CLI engines are downloaded on demand as separate binaries, never bundled. Only free and open-source engines are used (for example `unar` / `7zz` instead of the non-free `unrar`).

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors and retain their own open-source licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
