<img src="Design/AppIcon/AppIcon-1024.png" width="128" alt="OpenToolbox app icon">

# OpenToolbox

**Everyday developer, text, image, PDF, and Mac utilities in one native macOS app.**

OpenToolbox brings common small utilities together in a single Swift and SwiftUI app for macOS 15+. Everything built in runs locally on your Mac using Apple frameworks, and file tools always write to a dedicated output folder so your originals stay untouched.

## Why OpenToolbox

- **Native macOS (macOS 15+):** Written in Swift and SwiftUI using Apple frameworks (such as Vision, PDFKit, and ImageIO)—no Electron, no web wrappers, and universal builds for Apple silicon and Intel.
- **Private and offline by default:** No accounts, no telemetry, and no file uploads. Files are processed locally on your Mac. OpenToolbox only accesses the network for actions you explicitly start (downloading on-demand engines, running Network Speed Test, or checking for updates), plus a once-a-day update check if you turn it on.
- **Originals untouched:** File-processing tools write new, collision-safe files into a dedicated output folder (`<output folder>/<yyyy-MM-dd>/<tool>/`) instead of overwriting your source files.
- **On-demand engines:** Built-in Swift and Apple-framework tools work out of the box with zero extra downloads. External CLI engines are never bundled into the app; when available, they are downloaded only when you choose to install them, verified by SHA-256, shared across tools that need them, and removable with one click.

## What It Does

Navigate tools from the sidebar, jump anywhere with **Quick Open (`⌘K`)**, and use the **Engine Manager** to enable or disable tools and manage on-demand engines.

- **Tools keep their state.** Switching to another tool leaves the one you left as it was, and its work keeps running. A tool that is working shows a spinner in the sidebar. When it finishes out of sight, a dot marks it and macOS shows a notification.
- **Each window is separate.** Every OpenToolbox window has its own tools, selection and Quick Open.
- **Menu bar, hotkey and login.** **Settings → General** can show an OpenToolbox menu in the menu bar, open Quick Open from any app with `⌃⌥K`, and open OpenToolbox when you log in. All three are off by default. While the menu bar icon is shown, closing the last window keeps OpenToolbox running there.

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
| **Batch Rename** | Rename many files with patterns and previews. |
| **Find Duplicates** | Find duplicate files by content. |

### Images & PDF

Powered by Apple frameworks (Vision, PDFKit, ImageIO):

| Tool | Description |
| --- | --- |
| **Convert Images** | Convert, resize, and rotate images. |
| **Strip EXIF** | Remove location and camera metadata from images. |
| **Remove Background** | Lift subjects from photos on-device. |
| **Blur Faces** | Detect and blur faces on-device. |
| **Extract Text (OCR)** | Recognize text in images and PDFs on-device. |
| **Organize PDFs** | Merge, split, extract, reorder, and rotate PDF pages. |
| **Images ↔ PDF** | Combine images into a PDF or export pages as images. |
| **Watermark** | Add a text or image watermark to images and PDFs: position, size, opacity, diagonal or tiled. PDF pages stay vector and the text stays searchable. |

### Mac Utilities

| Tool | Description |
| --- | --- |
| **Keep Awake** | Prevent your Mac from sleeping for a while. |
| **Battery Health** | Show battery cycle count, capacity, and condition. |
| **Network Speed Test** | Measure network quality with Apple's `networkQuality`. |
| **Disk Speed Test** | Measure a drive's sequential write and read speed with an uncached test file that is removed when the test ends. |
| **Eject All Disks** | Eject every external and disk-image volume. |
| **Quarantine Helper** | Inspect and clear the quarantine flag on downloaded files. |
| **Hidden Settings** | Toggle documented hidden macOS preferences. |

### Media

- **Convert Video & Audio** (`ffmpeg`) and **Download Video** (`yt-dlp`) are listed in the app as **"Coming soon"** until verified engine builds are pinned.

## Install

Requires **macOS 15 or later** (universal build for Apple silicon and Intel).

1. Download the latest `OpenToolbox-<version>-macOS-universal.dmg` from [Releases](https://github.com/LetterXbox/OpenToolbox/releases) and open it.
2. Drag **OpenToolbox** into the **Applications** folder.
3. Open **OpenToolbox** from Applications. Because releases are not signed with an Apple Developer ID or notarized, macOS blocks the first launch: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once per version.

Each release lists the disk image's SHA-256 checksum so you can verify your download:

```sh
shasum -a 256 OpenToolbox-<version>-macOS-universal.dmg
```

## Updates

Choose **OpenToolbox → Check for Updates…** to look for a newer release on GitHub. In **Settings → Updates** you can turn on a daily automatic check and, optionally, automatic download and install. Both are off by default.

An update is installed only after the disk image matches the SHA-256 checksum GitHub publishes for it, and the app inside has the OpenToolbox bundle identifier, the release's version number, and a valid code signature. It replaces the app when you restart or quit. Before downloading and again just before replacing the app, OpenToolbox checks that the app on disk is still the copy that was opened, and that the downloaded copy is still the one it verified, down to every architecture in its executable. If OpenToolbox can't write to its own folder, or macOS is running it from a temporary location, the update window links to the release page instead.

If installing an update fails when you quit, OpenToolbox tells you why the next time you open it. While OpenToolbox runs in the menu bar, a downloaded update also appears in its menu as **Restart to Update**. Turning on the automatic check checks right away. Turning off automatic download and install stops an automatic download that is under way and discards an automatically downloaded update that hasn't been installed yet.

## Known Limitations

- Releases are not notarized (see [Install](#install)).
- Closing a window stops the work running in its tools, such as a speed test or a duplicate scan.
- Watermarked PDFs keep each page's text and vector graphics, but links, form fields, comments and the outline are not kept as interactive items.
- An update installs only when you restart or quit OpenToolbox, so while it stays open in the menu bar a downloaded update waits until you choose **Restart to Update** or quit.
- Releases are ad-hoc signed, so an update's code signature proves the app is intact but not who built it. Trust in an update rests on the GitHub release it comes from.
- If you run two copies of OpenToolbox from the same folder at once, the one you open later removes an update the other has downloaded and is waiting to install. Choose **Check for Updates…** in the first copy to download it again.
- When OpenToolbox opens, it records the app on disk that an update may later replace. If something replaces the app on disk at that exact moment, an update installed from that session replaces the new copy instead.
- If macOS reports an update's disk image without its file path, OpenToolbox can't eject it, and the image stays mounted (hidden and read-only) until you restart.

## Building from Source

Requires **macOS 15 or later** and **Xcode 16 or later** (Swift 6 toolchain).

```sh
swift build                 # build the core library and the app
swift test                  # run OpenToolboxCore unit tests (Swift Testing)
swift run OpenToolbox       # launch the app from the command line
```

You can also open `Package.swift` in Xcode and run the `OpenToolbox` scheme.

To package a universal, ad-hoc signed `OpenToolbox.app` and its release disk image (`.dmg` and `.sha256`), run on a Mac:

```sh
scripts/package-app.sh <version>
```

Output is written to `.build/release-app/dist/`.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/OpenToolboxCore` | UI-free logic: tool catalog, engine manager (`EngineStore`), output-folder helper, and tool implementations. Fully unit-tested. |
| `Sources/OpenToolboxApp` | SwiftUI shell: sidebar, `⌘K` command palette, tool catalog, Engine Manager, and tool views. |
| `Tests/OpenToolboxCoreTests` | Unit tests. They never use the network or the real Application Support folder. |

### Conventions

- **Strings:** Every user-facing literal goes through `L("…")` (app) or `coreLocalized("…")` (core) so it lands in the `Localizable.xcstrings` catalogs. English is the source language.
- **Engines:** Manifests ship with the app (`EngineCatalog`). Each artifact is pinned per CPU architecture with an HTTPS URL, byte size, and SHA-256 checksum. Installs download to a staging folder, verify size and checksum, then move into `~/Library/Application Support/OpenToolbox/engines/<id>/` in one rename. Engines without a verified pinned build yet are listed as "Coming soon" and cannot be installed.
- **Outputs:** File tools write to `<output folder>/<yyyy-MM-dd>/<tool>/` with collision-safe names and never overwrite the source file.

## Contributing

Issues and pull requests are welcome. Two rules apply to every contribution:

- **Clean room:** Write everything from scratch using public Apple frameworks, standard open-source tools, and original code, UI text, and assets. Never download, decompile, or copy binaries, source code, icons, or UI text from other utility apps, including the ones named below.
- **Engines stay separate:** External CLI engines are downloaded on demand as separate binaries, never bundled. Only free and open-source engines are used (for example, `unar` or `7zz` instead of the non-free `unrar`).

## Inspiration & Credits

Inspired by all-in-one native macOS utility suites such as [Toolbox for Mac](https://mactoolbox.app/) and [DevToys](https://devtoys.app/). OpenToolbox is built independently from scratch as a free, open-source, modular alternative.

External open-source engines downloaded on demand remain the work of their respective authors and retain their own open-source licenses.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
