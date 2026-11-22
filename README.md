<p align="center">
  <img src="Design/AppIcon/AppIcon-1024.png" width="128" alt="OpenToolbox app icon">
</p>

<h1 align="center">OpenToolbox</h1>

<p align="center">
  <strong>Everyday developer, text, image, PDF, and Mac utilities in one native macOS app.</strong>
</p>

<p align="center">
  <a href="https://github.com/LetterXbox/OpenToolbox/releases/latest"><img src="https://img.shields.io/github/v/release/LetterXbox/OpenToolbox?label=Latest%20Release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-Universal-informational" alt="Universal Binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-green" alt="GPL-3.0 License"></a>
</p>

---

OpenToolbox brings 33 everyday utilities together in a single Swift and SwiftUI app for macOS 15+. Everything built in runs locally on your Mac using Apple frameworks, and file tools always write to a dedicated output folder so your originals stay untouched.

## Why OpenToolbox

- **Pure native macOS (macOS 15+):** Built with Swift, SwiftUI, and Apple frameworks (Vision, PDFKit, ImageIO)—no Electron, no web wrappers, and universal binaries for Apple silicon and Intel.
- **Private and offline by default:** No accounts, no telemetry, and no file uploads. All processing happens on your Mac. OpenToolbox connects to the network only when you explicitly start an online action (downloading on-demand engines, running Network Speed Test, or checking for updates), plus an optional daily update check that is off by default.
- **Originals stay untouched:** File tools write new, collision-safe files into `<output folder>/<yyyy-MM-dd>/<tool>/` rather than overwriting your source files.
- **On-demand external engines:** Built-in tools work out of the box with zero extra downloads. External CLI engines are never bundled; when available, they download only on request, are verified by SHA-256, shared across tools, and removable in one click.

## Highlights

- **Fast navigation:** Browse tools in the sidebar, jump anywhere with **Quick Open (`⌘K`)**, and enable or disable tools in the **Engine Manager**.
- **Tools keep their state:** Switching to another tool preserves your inputs and lets running work continue. Active tools show a spinner in the sidebar; when background work finishes out of view, a dot marks the tool and macOS posts a notification.
- **Independent windows:** Each OpenToolbox window maintains its own tool state, selection, and Quick Open palette.
- **Menu bar, global hotkey & login:** In **Settings → General**, you can enable a menu bar icon (keeping OpenToolbox running when the last window closes), trigger Quick Open from any app with `⌃⌥K`, and launch OpenToolbox at login. All three are off by default.

## Included Tools

### Developer

| Tool | Description |
| --- | --- |
| **JSON Formatter** | Format, minify, and validate JSON. |
| **Base64 / Hex** | Encode and decode Base64, Base64URL, and hexadecimal. |
| **Hash Generator** | Compute MD5, SHA-1, and SHA-2 digests of text or files. |
| **UUID Generator** | Generate and inspect UUID v4 and v7 identifiers. |
| **JWT Decoder** | Decode JSON Web Token headers and claims. |
| **Timestamp Converter** | Convert Unix timestamps and ISO 8601 dates. |
| **Diff Checker** | Compare two texts line by line. |
| **Regex Tester** | Test regular expressions against sample text. |
| **Clean Links** | Strip tracking parameters from URLs. |
| **Unicode Inspector** | Inspect code points, names, and encodings of characters. |
| **Lorem Ipsum** | Generate placeholder text. |
| **Password Generator** | Generate strong random passwords. |
| **CSV ↔ JSON** | Convert between CSV and JSON. |

### Text & Files

| Tool | Description |
| --- | --- |
| **Word Counter** | Count words, characters, sentences, and lines. |
| **Case Converter** | Convert text between `camelCase`, `snake_case`, Title Case, and more. |
| **QR Code** | Generate and read QR codes. |
| **Batch Rename** | Rename many files with patterns, live previews, and undo. |
| **Find Duplicates** | Find duplicate files by content and safely move selected copies to Trash. |

### Images & PDF

Powered on-device by Apple's Vision, PDFKit, and ImageIO frameworks:

| Tool | Description |
| --- | --- |
| **Convert Images** | Convert, resize, and rotate images. |
| **Strip EXIF** | Remove location and camera metadata from images. |
| **Remove Background** | Lift subjects from photos on-device. |
| **Blur Faces** | Detect and blur faces on-device. |
| **Extract Text (OCR)** | Recognize text in images and PDFs on-device. |
| **Organize PDFs** | Merge, split, extract, reorder, and rotate PDF pages. |
| **Images ↔ PDF** | Combine images into a PDF or export PDF pages as images. |
| **Watermark** | Add a text or image watermark to images and PDFs (9 positions or tiled, adjustable size, opacity, and diagonal angle). PDF pages stay vector and text stays searchable. |

### Mac Utilities

| Tool | Description |
| --- | --- |
| **Keep Awake** | Prevent your Mac from sleeping for a set duration. |
| **Battery Health** | Show battery cycle count, capacity, and condition. |
| **Network Speed Test** | Measure network quality with Apple's `networkQuality`. |
| **Disk Speed Test** | Measure a drive's sequential write and read speed with an uncached test file that is always cleaned up afterward. |
| **Eject All Disks** | Eject every external and disk-image volume. |
| **Quarantine Helper** | Inspect and clear the quarantine flag on downloaded files. |
| **Hidden Settings** | Toggle documented hidden macOS preferences. |

### Media (Coming Soon)

- **Convert Video & Audio** (`ffmpeg`) and **Download Video** (`yt-dlp`) appear in the app as **"Coming soon"** until verified, SHA-256-pinned engine builds are ready.

## Install

Requires **macOS 15 or later** (universal build for Apple silicon and Intel).

1. Download the latest `OpenToolbox-<version>-macOS-universal.dmg` from [Releases](https://github.com/LetterXbox/OpenToolbox/releases) and open it.
2. Drag **OpenToolbox** into **Applications**.
3. Open **OpenToolbox** from Applications. Because releases are ad-hoc signed and not notarized with an Apple Developer ID, macOS blocks the first launch: click **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once per version.

GitHub displays each release asset's SHA-256 digest on the release page so you can verify your download:

```sh
shasum -a 256 OpenToolbox-<version>-macOS-universal.dmg
```

## Updates

Choose **OpenToolbox → Check for Updates…** to check GitHub Releases manually. In **Settings → Updates**, you can optionally turn on daily automatic checks and automatic download and install (both are off by default).

- **Verification:** Updates install only after the disk image matches the SHA-256 digest published by GitHub and the app bundle inside passes bundle-identifier, version, and code-signature checks. Before downloading and again right before swapping the app, OpenToolbox verifies that the installed copy on disk is still the copy that launched and that the downloaded binary matches what was verified across every architecture.
- **Installing:** Updates replace the app when you restart or quit. While OpenToolbox is running in the menu bar, a ready update also appears as **Restart to Update**. If an install fails on quit, OpenToolbox reports why on the next launch.
- **Read-only / translocated locations:** If OpenToolbox cannot write to its own folder or is running from a temporary location, the update window links to the GitHub release page instead.
- **Immediate settings effect:** Turning on automatic checks triggers a check right away; turning off automatic download and install cancels any in-progress automatic download and discards an uninstalled automatic update.

## Known Limitations

- **Not notarized / ad-hoc signed:** Releases require **Open Anyway** on first launch (see [Install](#install)). Because the signature is ad-hoc, it proves the app bundle is intact rather than publisher identity; trust in an update rests on the GitHub release.
- **Closing windows during active jobs:** Closing a window stops a Network Speed Test, Disk Speed Test, or duplicate scan running in that window. File batches already under way (such as image conversion or watermarking) finish as long as OpenToolbox remains running; with the menu bar icon off, closing the last window quits the app.
- **Watermark format limits:** Animated GIFs and multipage TIFFs are rejected. Watermarked PDFs keep vector graphics and searchable text, but links, form fields, comments, and outlines are not preserved as interactive elements.
- **Updates apply on restart/quit:** While OpenToolbox stays open in the menu bar, a downloaded update waits until you choose **Restart to Update** or quit.
- **Multiple copies from one folder:** Running two copies of OpenToolbox from the same folder at once causes the later instance to remove a staged update prepared by the first; run **Check for Updates…** again to re-download it.
- **Startup bundle swap race:** OpenToolbox records its on-disk app bundle at launch. If something replaces the app on disk at that exact moment, a subsequent update from that session replaces the new copy instead.
- **Unreported DMG mount path:** If macOS reports an update disk image without its file path, OpenToolbox cannot eject it, leaving it mounted (hidden and read-only) until you restart.

## Building from Source

Requires **macOS 15 or later** and **Xcode 16 or later** (Swift 6 toolchain).

```sh
swift build                 # build the core library and the app
swift test                  # run OpenToolboxCore unit tests (Swift Testing)
swift run OpenToolbox       # launch the app from the command line
```

You can also open `Package.swift` in Xcode and run the `OpenToolbox` scheme.

To package a universal, ad-hoc signed `OpenToolbox.app`, `.dmg`, and `.sha256` on a Mac:

```sh
scripts/package-app.sh <version>
```

Build artifacts are written to `.build/release-app/dist/`.

### Project Layout

| Path | Contents |
| --- | --- |
| `Sources/OpenToolboxCore` | UI-free logic: tool catalog, engine manager (`EngineStore`), output-folder helper, and tool implementations. Fully unit-tested. |
| `Sources/OpenToolboxApp` | SwiftUI shell: sidebar, `⌘K` command palette, tool catalog, Engine Manager, and tool views. |
| `Tests/OpenToolboxCoreTests` | Unit tests. Never use the network or the real Application Support folder. |

### Conventions

- **Localization:** User-facing strings go through `L("…")` (app) or `coreLocalized("…")` (core) into `Localizable.xcstrings` catalogs, with English as the source language.
- **Engines:** Manifests live in `EngineCatalog` with per-architecture HTTPS URLs, byte sizes, and SHA-256 checksums. Downloads stage, verify size and digest, then atomically move into `~/Library/Application Support/OpenToolbox/engines/<id>/`. Unpinned engines stay marked **"Coming soon"** and cannot be installed.
- **Outputs:** File tools write to `<output folder>/<yyyy-MM-dd>/<tool>/` with collision-safe filenames and never overwrite originals.

## Contributing

Issues and pull requests are welcome. Every contribution follows two core rules:

- **Clean room:** Build everything from scratch using public Apple frameworks, standard open-source tools, and original code, UI copy, and assets. Never download, decompile, or copy binaries, source code, icons, or UI text from other utility apps, including the inspiration apps below.
- **Separate free engines:** External CLI engines are downloaded on demand as separate binaries—never bundled—and must be free and open-source (for example, `unar` or `7zz` instead of non-free `unrar`).

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors under their own licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
