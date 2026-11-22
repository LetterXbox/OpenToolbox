# OpenToolbox

Open-source, pure native macOS (Swift / SwiftUI, macOS 15+) utility suite with on-demand downloads for external engines. These rules apply to every contributor, including coding agents.

## Language and license

- Write all repo docs, comments, commit messages and default UI strings in **English**. Keep UI strings ready for `Localizable.xcstrings` localization (`L("…")` in the app, `coreLocalized("…")` in the core).
- License: **GPL-3.0** (`LICENSE`). Keep external GPL/LGPL/AGPL/permissive CLI engines (for example `ffmpeg`, `yt-dlp`, `7zz`, and `ghostscript`) as separate on-demand subprocess binaries rather than bundling them. Use only open-source engines (avoid non-free `unrar`; use `7zz`/`unar`).

## Clean-room rule

- Build everything cleanly from scratch using public Apple frameworks, standard open-source tools, and original UI/code/assets.
- Never download, inspect, decompile, or copy binaries, source code, icons, or UI copy from commercial reference apps.

## Architecture rules

- **Pure native Swift / SwiftUI** targeting macOS 15+ (Swift Package Manager).
- **On-demand downloads only:** Pure-Swift and Apple-framework tools add 0 MB external weight. External engines live in `~/Library/Application Support/OpenToolbox/engines/`, downloaded only when the user enables/downloads a tool requiring them, verified by SHA-256, deduplicated across tools, and individually removable.
- **Originals untouched:** File tools must write new files to an output directory without silently overwriting originals.
- **Privacy first:** Offline by default; network access occurs only for explicit user-triggered actions (engine downloads, video URL downloads, network speed tests, update checks, Web Page to PDF, the Coordinate Picker map, Scan Document's Find Network Scanners, and the language downloads macOS makes for Translate and Transcribe) and the opt-in daily update check (off by default).

## Building and testing

- The app builds only on macOS with Xcode 26 or later (Swift 6, macOS 26 SDK). APIs newer than macOS 15 stay behind `#available`, and frameworks newer than macOS 15 are weakly linked (`scripts/package-app.sh` checks this). Use `swift build` and `swift test`; package releases with `scripts/package-app.sh` and follow `docs/RELEASING.md`.
- Unit tests never use the network or the real Application Support folder.

## Public repository

- The repository is public. Plans and roadmap are kept outside the repository.
- Before every release, follow `docs/RELEASING.md`: have **Gemini 4 Neon** update `README.md` (feature list, install steps, and known limitations) and write the GitHub release notes (**New features** and **Bug fixes** only). Record what was tested, and on which platform, in the release PR body.
- Keep machine-specific paths, hostnames, IP addresses and local tool configuration out of tracked files, PR bodies and release notes.
