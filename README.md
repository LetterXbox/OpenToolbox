<p align="center">
  <img src="Design/AppIcon/AppIcon-1024.png" width="128" alt="OpenToolbox app icon">
</p>

<h1 align="center">OpenToolbox</h1>

<p align="center">
  <strong>Everyday developer, text, image, PDF, media, and Mac utilities in one native macOS app.</strong>
</p>

<p align="center">
  <a href="https://github.com/LetterXbox/OpenToolbox/releases/latest"><img src="https://img.shields.io/github/v/release/LetterXbox/OpenToolbox?label=Latest%20Release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-Universal-informational" alt="Universal Binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-green" alt="GPL-3.0 License"></a>
</p>

---

OpenToolbox brings 74 everyday utilities together in a single Swift and SwiftUI app for macOS 15+. Built-in tools run locally on your Mac using Apple frameworks, and tools that need heavier open-source engines (**FFmpeg**, **FFprobe**, **yt-dlp**, **7-Zip**, and **Ghostscript**) download them only when you ask. Tools that export processed files write to a dedicated output folder so your originals stay untouched (except when you explicitly act on existing files, such as choosing **Rename in place** in Batch Rename, moving selected copies to Trash in Find Duplicates, or clearing the quarantine flag in Quarantine Helper).

## Why OpenToolbox

- **Pure native macOS (macOS 15+):** Built with Swift, SwiftUI, and Apple frameworks (Vision, PDFKit, ImageIO, AVFoundation, ScreenCaptureKit, Speech, Translation, Quick Look, WebKit, and Foundation Models)—no Electron, no web wrappers, and universal binaries for Apple silicon and Intel.
- **Private and offline by default:** No accounts, no telemetry, and no file uploads. All built-in tools—including **Translate**, **Transcribe**, **Summarize**, **Markdown to PDF**, and **Word / PowerPoint / Excel to PDF**—process files locally on your Mac. OpenToolbox connects to the network only when you explicitly start an online action: downloading on-demand engines, downloading a media URL in **Download Video**, running **Network Speed Test**, checking for or downloading updates, loading a URL in **Web Page to PDF**, showing or searching the map in **Coordinate Picker** (Apple Maps), or clicking **Find Network Scanners** in **Scan Document**. You can also opt in to daily automatic update checks; a second opt-in lets OpenToolbox download an available update's disk image after a daily check without a further click and install it when you restart or quit (both are off by default). For **Translate** and (on macOS 26+) **Transcribe**, macOS may download an on-device language pack the first time you use a language.
- **Originals stay untouched:** Tools that export processed copies write new, collision-safe files into `<output folder>/<yyyy-MM-dd>/<tool>/` rather than overwriting your source files. Actions that modify or remove existing files happen only when you explicitly choose them—such as **Batch Rename**'s **Rename in place** mode (which supports undo), **Find Duplicates** moving selected copies to Trash, and **Quarantine Helper** clearing a file's quarantine flag in place.
- **On-demand external engines:** Built-in tools work out of the box with zero extra downloads. External CLI engines are never bundled; tools requiring them start disabled in the **Tool Catalog** and only download pinned, SHA-256-verified builds on request in the **Engine Manager**, shared across tools and removable in one click.

## Highlights

- **Fast navigation:** Browse tools in the sidebar, jump anywhere with **Quick Open** in the window toolbar (or press `⌘K`), enable or disable tools in the **Tool Catalog**, and manage on-demand engines in the **Engine Manager**.
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
| **Color Picker** | Pick a color anywhere on screen and copy it as hex, RGB, HSL, HSB, SwiftUI, or AppKit code. |
| **Coordinate Picker** | Find a place on a map or enter coordinates, and copy latitude and longitude as decimal, DMS, or GeoJSON. |

### Text & Files

| Tool | Description |
| --- | --- |
| **Word Counter** | Count words, characters, sentences, and lines. |
| **Case Converter** | Convert text between `camelCase`, `snake_case`, Title Case, and more. |
| **QR Code** | Generate and read QR codes. |
| **Batch Rename** | Rename many files with patterns, live previews, and undo. |
| **Find Duplicates** | Find duplicate files by content and safely move selected copies to Trash. |
| **Translate** | Translate text on-device with Apple Translation. |
| **Text to Speech** | Read text aloud with any installed voice, or save it as an audio file. |
| **Transcribe** | Turn speech in audio and video files into text or subtitles (SRT, WebVTT), on-device. |
| **Summarize** | Summarize text and documents on-device with Apple Intelligence (macOS 26+ on Macs with Apple Intelligence). |
| **Zip & Unzip** | Create ZIP, 7z, and TAR archives (with optional password encryption for ZIP/7z) and extract ZIP, 7z, RAR, and TAR archives *(on-demand `7zz`)*. |
| **Convert Documents** | Convert documents between DOCX, RTF, HTML, ODT, TXT, Markdown, and PDF offline. |

### Images & PDF

Powered on-device by Apple's Vision, PDFKit, ImageIO, Image Capture, Quick Look, and WebKit frameworks, plus on-demand Ghostscript for PDF compression:

| Tool | Description |
| --- | --- |
| **Convert Images** | Convert, resize, and rotate images. |
| **Strip EXIF** | Remove location and camera metadata from images. |
| **Remove Background** | Lift subjects from photos on-device. |
| **Blur Faces** | Detect and blur faces on-device. |
| **Extract Text (OCR)** | Recognize text in images and PDFs on-device. |
| **Organize PDFs** | Merge, split, extract, delete, reorder, and rotate PDF pages. |
| **Images ↔ PDF** | Combine images into a PDF or export PDF pages as images. |
| **Watermark** | Add a text or image watermark to images and PDFs (9 positions or tiled, adjustable size, opacity, and diagonal angle). PDF pages stay vector and text stays searchable. |
| **Compress Images** | Make images smaller by lowering quality or size; copies that wouldn't be smaller are not saved. |
| **Crop PDF** | Trim the margins of PDF pages with a live preview. |
| **PDF Password** | Add a password to PDFs (with optional printing, copying, and editing restrictions) or remove one. |
| **Fill & Flatten Forms** | Fill in PDF forms and save a filled or flattened copy. |
| **Scan Document** | Scan pages from a scanner or a nearby iPhone or iPad (Continuity Camera) into a PDF. |
| **Web Page to PDF** | Save a web page as A4 or US Letter pages, or as one long page. |
| **Compress PDF** | Shrink PDF file sizes by downsampling images and optimizing streams; copies that wouldn't be smaller are not saved *(on-demand `ghostscript`)*. |
| **Markdown to PDF** | Convert Markdown files or pasted text (including GitHub-flavored tables and task lists) into formatted PDFs offline. |
| **Word to PDF** | Convert `.docx`, `.doc`, `.odt`, and `.rtf` documents to PDF offline via macOS Quick Look and WebKit. |
| **PowerPoint to PDF** | Convert `.pptx` and `.ppt` presentations to PDF offline via macOS Quick Look and WebKit. |
| **Excel to PDF** | Convert `.xlsx` and `.xls` spreadsheets to PDF offline via macOS Quick Look and WebKit. |

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
| **Wi-Fi Password** | Show a saved Wi-Fi password (after administrator authentication) and share it as a QR code. |
| **Reset Permissions** | Reset the privacy permissions an app has been given or denied so macOS prompts again. |

### Media

| Tool | Description |
| --- | --- |
| **Record Screen** | Record the whole screen, a window, or an app, with optional Mac audio and microphone capture. |
| **Record Audio** | Record sound from the microphone you choose to an AAC audio file. |
| **Trim Audio** | Cut the start and end off an audio file (WAV, AIFF, and CAF keep their format and encoding; other formats save as AAC). |
| **Extract Frames** | Save frames from videos as images: spread evenly, every few seconds, or at set times. |
| **Compress Video** | Shrink video file sizes with H.264 or HEVC and optional max resolution *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Convert Video** | Convert videos between MP4, MOV, MKV, WebM, AVI, and M4V *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Resize Video** | Scale videos to 4K, 1080p, 720p, 480p, 360p, or custom dimensions *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Crop & Rotate Video** | Crop by aspect ratio or custom region, rotate, or flip videos *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Trim Video** | Cut a start and end range from a video using fast stream copy or frame-accurate re-encoding *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Merge Videos** | Join two or more videos in order with stream copy or normalized re-encoding *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Mute Video** | Remove audio tracks from videos without re-encoding *(on-demand `ffmpeg`)*. |
| **Replace Audio** | Swap or add an audio track onto a video, with optional audio looping *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Change Video Speed** | Speed up or slow down video and audio from 0.25× to 4× *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Video to GIF** | Create two-pass palette-optimized animated GIFs with custom frame rate, width, and trim range *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Burn In Subtitles** | Hardcode `.srt`, `.ass`, `.ssa`, or `.vtt` subtitles onto videos *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Media Info** | Inspect container metadata, duration, bitrate, and video/audio/subtitle streams, with copyable JSON *(on-demand `ffprobe`)*. |
| **Convert Audio** | Convert audio files between M4A, MP3, WAV, FLAC, OGG, Opus, and AIFF *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Extract Audio** | Save the audio track from a video as M4A, MP3, WAV, FLAC, OGG, Opus, or AIFF *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Clean Up Audio** | Reduce background noise, remove low rumble, tame harsh highs, and normalize loudness (EBU R128) on audio or video files *(on-demand `ffmpeg`, `ffprobe`)*. |
| **Download Video** | Download video (best, 1080p, 720p) or audio-only (M4A, MP3) with optional English subtitles from supported websites *(on-demand `yt-dlp`, `ffmpeg`)*. |

#### On-Demand Engines

Tools that rely on external CLI programs start disabled in **Tool Catalog** and download nothing automatically. Install or remove pinned, SHA-256-verified builds individually in **Engines**:

- **FFmpeg** 9.1 (GPL-3.0-or-later) and **FFprobe** 9.1 (GPL-3.0-or-later)
- **yt-dlp** 2026.10.26 (Unlicense)
- **7-Zip (`7zz`)** 26.06 (LGPL-2.1-or-later, BSD-3-Clause)
- **Ghostscript** 10.07.1 (AGPL-3.0-or-later)

## Install

Requires **macOS 15 or later** (universal build for Apple silicon and Intel; tested on Apple silicon only).

Some tools have additional system or hardware requirements:

- **Summarize** requires **macOS 26 or later** on a Mac with **Apple Intelligence** enabled.
- **Transcribe** uses Apple's newer on-device speech engine on **macOS 26 or later** and the older on-device speech recognizer on earlier versions; the languages offered depend on the recognizer your macOS version uses.
- **Record Audio** requires a connected microphone; you can pick any connected microphone or use the system default. If your saved microphone isn't connected, it falls back to the system default when macOS has one, or asks you to choose another microphone.
- **Scan Document** requires a scanner supported by macOS Image Capture or a nearby iPhone or iPad (Continuity Camera via **File → Import from iPhone or iPad**).

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
- **Test builds:** Turn on **Include test builds** in **Settings → Updates** to try GitHub pre-releases (such as `0.4.0-beta.1` or `0.3.0-rc.1`) early. It is off by default on full releases, and starts on in a test build until you change it. Test builds may have more bugs, and go through the same SHA-256, bundle-identifier, version, and code-signature checks as full releases. When it is on, each update check (manual **Check for Updates…**, or the daily automatic check if turned on) reads GitHub's list of recent releases and offers the highest newer version, full or test. A full release ranks above test builds of the same version (`0.3.0` over `0.3.0-rc.2`), while a test build for a later version (`0.4.0-beta.1`) ranks above `0.3.0` and is offered instead. Turning it off cancels any in-progress test-build download and discards an uninstalled test build, without returning you to an older full release—you stay on the test build until a newer full release comes out.

## Known Limitations

- **Not notarized / ad-hoc signed:** Releases require **Open Anyway** on first launch (see [Install](#install)). Because the signature is ad-hoc, it proves the app bundle is intact rather than publisher identity; trust in an update rests on the GitHub release. After an update, macOS may also ask again for **Screen Recording**, **Microphone**, **Speech Recognition**, and **Location** permissions.
- **Intel Macs not tested:** The release download includes Intel code, but releases are tested only on Macs with Apple silicon.
- **Unsaved recordings:** If **Record Screen** or **Record Audio** can't save a recording to the output folder, it is kept in **Unsaved Recordings** inside the recorder, where both tools can save or discard it later. If saving to **Unsaved Recordings** also fails, the error shows where the recording is stored; copy it from there before closing the tool.
- **PDF Password restrictions and removal:** Printing, copying, and editing restrictions are enforced only by PDF apps that respect them. Removing a password or restrictions requires the PDF's owner password (or its single password if one was used for both).
- **Summarize and Transcribe system limits:** **Summarize** requires macOS 26 or later on a Mac with Apple Intelligence turned on. **Transcribe** uses Apple's newer speech engine on macOS 26 or later and the older on-device speech recognizer on earlier versions; the languages it offers depend on the recognizer your macOS version uses.
- **Scan Document sources:** Works with scanners macOS supports through Image Capture, and with an iPhone or iPad through **File → Import from iPhone or iPad**.
- **Web Page to PDF rendering:** Pages load without your browser cookies or logins, so pages behind a sign-in save as their sign-in page. Splitting a page into A4 or US Letter pages can cut a line of text across two pages.
- **Office & Markdown to PDF rendering:** **Word to PDF**, **PowerPoint to PDF**, **Excel to PDF**, and PDF exports in **Convert Documents** render files completely offline using macOS Quick Look (with `textutil` fallback for Word/RTF/ODT) and WebKit. Complex Office layouts, fonts, animations, or multi-sheet pagination may differ from Microsoft Office or LibreOffice. Remote images and external resources in Markdown and HTML are blocked during offline rendering.
- **Compress PDF:** Uses Ghostscript (`-dSAFER`) to downsample images and optimize streams; copies that wouldn't be smaller are not saved, and password-protected PDFs must be unlocked first.
- **Zip & Unzip archive safety:** Extracted archives containing symlinks, hardlinks, or special files are refused rather than published.
- **Download Video:** Uses on-demand `yt-dlp` and `ffmpeg` for supported websites; upstream site changes may require a newer `yt-dlp` build.
- **Closing windows during active jobs:** Closing a window stops a Network Speed Test, Disk Speed Test, or duplicate scan running in that window. File batches already under way (such as image conversion or watermarking) finish as long as OpenToolbox remains running; with the menu bar icon off, closing the last window quits the app.
- **Image and Watermark format limits:** Animated GIFs and multipage TIFFs (images with several frames or pages) are refused by Watermark and Compress Images. Watermarked PDFs keep vector graphics and searchable text, but links, form fields, comments, and outlines are not preserved as interactive elements.
- **Updates apply on restart/quit:** While OpenToolbox stays open in the menu bar, a downloaded update waits until you choose **Restart to Update** or quit.
- **Multiple copies from one folder:** Running two copies of OpenToolbox from the same folder at once causes the later instance to remove a staged update prepared by the first; run **Check for Updates…** again to re-download it.
- **Startup bundle swap race:** OpenToolbox records its on-disk app bundle at launch. If something replaces the app on disk at that exact moment, a subsequent update from that session replaces the new copy instead.
- **Unreported DMG mount path:** If macOS reports an update disk image without its file path, OpenToolbox cannot eject it, leaving it mounted (hidden and read-only) until you restart.

## Building from Source

Requires **macOS 15 or later** and **Xcode 26 or later** (Swift 6 toolchain and macOS 26 SDK).

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
- **Outputs:** Tools that export processed files write to `<output folder>/<yyyy-MM-dd>/<tool>/` with collision-safe filenames and never overwrite originals; tools that act directly on existing files when explicitly requested include **Batch Rename** (when **Rename in place** is chosen), **Find Duplicates** (moving selected copies to Trash), and **Quarantine Helper** (clearing the quarantine extended attribute in place).

## Contributing

Issues and pull requests are welcome. Every contribution follows two core rules:

- **Clean room:** Build everything from scratch using public Apple frameworks, standard open-source tools, and original code, UI copy, and assets. Never download, decompile, or copy binaries, source code, icons, or UI text from other utility apps, including the inspiration apps below.
- **Separate free engines:** External CLI engines are downloaded on demand as separate binaries—never bundled—and must be free and open-source (for example, `unar` or `7zz` instead of non-free `unrar`).

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors under their own licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
