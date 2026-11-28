<p align="center">
  <img src="Design/AppIcon/AppIcon-1024.png" width="112" alt="OpenToolbox app icon">
</p>

<h1 align="center">OpenToolbox</h1>

<p align="center">
  <strong>74 everyday developer, text, image, PDF, media, and Mac utilities in one native macOS app.</strong>
</p>

<p align="center">
  <a href="https://github.com/LetterXbox/OpenToolbox/releases/latest"><img src="https://img.shields.io/github/v/release/LetterXbox/OpenToolbox?label=Latest%20Release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-Universal-informational" alt="Universal Binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-green" alt="GPL-3.0 License"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#tools">Tools</a> ·
  <a href="#privacy-and-network-access">Privacy</a> ·
  <a href="docs/KNOWN_LIMITATIONS.md">Known limitations</a> ·
  <a href="#build-from-source">Build</a>
</p>

---

OpenToolbox is a Swift and SwiftUI utility suite for macOS 15+. Built-in tools run locally on Apple frameworks, and tools that need external open-source CLI engines download them only when you ask.

- **Native macOS 15+.** Built with Swift, SwiftUI, and Apple frameworks with no Electron or web wrappers, packaged as a universal binary for Apple silicon and Intel.
- **Offline by default.** No accounts, telemetry, or file uploads. Built-in tools, including Translate, Transcribe, Summarize, and offline PDF conversion, process data locally on your Mac.
- **Originals untouched.** Exporting tools write collision-safe copies into `<output folder>/<yyyy-MM-dd>/<tool>/`. Existing files change only when you choose an in-place action (Batch Rename's **Rename in place** mode with undo, Find Duplicates moving selected copies to Trash, or Quarantine Helper).
- **On-demand engines.** Built-in tools need no extra downloads. Tools backed by external CLI binaries start disabled in the **Tool Catalog** and download pinned, SHA-256-verified builds only when you install them in **Engine Manager**.
- **Multi-window workflow.** Each window keeps its own tool state and `⌘K` **Quick Open** palette. Background jobs continue when you switch tools, and **Settings → General** adds optional menu bar mode, global `⌃⌥K` Quick Open, and launch at login (all off by default).

## Install

Requires **macOS 15 or later** (universal build; tested on Apple silicon only).

1. Download `OpenToolbox-<version>-macOS-universal.dmg` from [Releases](https://github.com/LetterXbox/OpenToolbox/releases) and open it.
2. Drag **OpenToolbox** into **Applications**.
3. Open **OpenToolbox**. Because releases are ad-hoc signed rather than notarized with an Apple Developer ID, click **Done** on the first-launch warning, then open **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once per version.

To verify a download against the SHA-256 digest shown on the release page, run:

```sh
shasum -a 256 OpenToolbox-<version>-macOS-universal.dmg
```

**Updates.** Choose **OpenToolbox → Check for Updates…** to check GitHub Releases manually, or opt in to daily checks, automatic downloads, or pre-release test builds in **Settings → Updates** (all off by default on full releases). OpenToolbox verifies each download's GitHub SHA-256 digest, bundle identifier, version, and code signature before staging it, and installs ready updates when you restart or quit (or choose **Restart to Update** in the menu bar).

## Tools

OpenToolbox includes 74 tools across five categories:

- **Developer (15).** JSON Formatter, Base64 / Hex, Hash Generator, UUID Generator, JWT Decoder, Timestamp Converter, Diff Checker, Regex Tester, Clean Links, Unicode Inspector, Lorem Ipsum, Password Generator, CSV ↔ JSON, Color Picker, and Coordinate Picker.
- **Text & Files (11).** Word Counter, Case Converter, QR Code, Batch Rename, Find Duplicates, Translate, Text to Speech, Transcribe, Summarize, Zip & Unzip (`7zz`), and Convert Documents.
- **Images & PDF (19).** Convert Images, Strip EXIF, Remove Background, Blur Faces, Extract Text (OCR), Organize PDFs, Images ↔ PDF, Watermark, Compress Images, Crop PDF, PDF Password, Fill & Flatten Forms, Scan Document, Web Page to PDF, Compress PDF (`ghostscript`), Markdown to PDF, Word to PDF, PowerPoint to PDF, and Excel to PDF.
- **Mac Utilities (9).** Keep Awake, Battery Health, Network Speed Test, Disk Speed Test, Eject All Disks, Quarantine Helper, Hidden Settings, Wi-Fi Password, and Reset Permissions.
- **Media (20).** Record Screen, Record Audio, Trim Audio, Extract Frames, and 16 on-demand tools using `ffmpeg`, `ffprobe`, or `yt-dlp`: Compress Video, Convert Video, Resize Video, Crop & Rotate Video, Trim Video, Merge Videos, Mute Video, Replace Audio, Change Video Speed, Video to GIF, Burn In Subtitles, Media Info, Convert Audio, Extract Audio, Clean Up Audio, and Download Video.

### On-demand engines

Engines are shared across tools, verified by SHA-256, stored under `~/Library/Application Support/OpenToolbox/engines/`, and removable in one click from **Engine Manager**:

| Engine | Version | License |
| --- | --- | --- |
| FFmpeg & FFprobe | 9.1 | GPL-3.0-or-later |
| yt-dlp (standalone macOS binary) | 2026.11.23 | GPL-3.0-or-later |
| 7-Zip (`7zz`) | 26.06 | LGPL-2.1-or-later, BSD-2-Clause, BSD-3-Clause, with upstream's unRAR license restriction for RAR decoding |
| Ghostscript | 10.07.1 | AGPL-3.0-or-later |

## Privacy and network access

OpenToolbox collects no telemetry and never uploads your files. It connects to the network only when you start an online action:

- Installing on-demand engines in **Engine Manager**
- Downloading a URL in Download Video or loading a URL in Web Page to PDF
- Running Network Speed Test
- Viewing or searching the Apple Maps view in Coordinate Picker
- Clicking **Find Network Scanners** in Scan Document
- Checking for or downloading updates (daily checks and automatic downloads are off by default)

On first use of a language, macOS may download an on-device language pack for Translate and (on macOS 26+) Transcribe.

## Known limitations

See [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) for signing, platform, tool, and updater limitations.

## Build from source

Requires **macOS 15 or later** and **Xcode 26 or later** (Swift 6 toolchain and macOS 26 SDK).

```sh
swift build                       # build the core library and app
swift test                        # run unit tests
swift run OpenToolbox             # launch the app
scripts/package-app.sh <version>  # build .app, .dmg, and .sha256 in .build/release-app/dist/
```

You can also open `Package.swift` in Xcode and run the `OpenToolbox` scheme. The codebase is organized into `Sources/OpenToolboxCore` (UI-free tools, catalog, and engine manager), `Sources/OpenToolboxApp` (SwiftUI shell and tool views), and `Tests/` (offline unit tests).

## Contributing

Issues and pull requests are welcome. Two rules apply to every contribution:

- **Clean room.** Build everything from scratch using public Apple frameworks, standard open-source tools, and original code, copy, and assets. Never download, inspect, decompile, or copy binaries, source code, icons, or UI text from other utility apps, including the inspiration apps below.
- **Separate free engines.** External CLI engines are downloaded on demand as separate binaries, never bundled, and must use free and open-source licenses (for example `7zz`, not standalone non-free `unrar`).

## Inspiration and credits

Inspired by native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/), built independently from scratch as a free, open-source alternative. On-demand engines remain the work of their respective authors under their own licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
