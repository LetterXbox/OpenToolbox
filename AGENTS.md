# OpenToolbox workspace

Open-source, pure native macOS (Swift / SwiftUI, macOS 15+) utility suite with modular on-demand downloads for external engines and models.

## Host baseline & policies

- Follow `/home/debian/.local/share/agent-skills/workspace-policies/common.md`.
- Reply and write all repo docs, comments, commit messages, and default UI strings in **English** (keep UI strings ready for `Localizable.xcstrings` localization).
- License: **GPL-3.0** (`LICENSE`). Keep external GPL/LGPL/permissive CLI engines (`ffmpeg`, `yt-dlp`, `7zz`, `whisper.cpp`, etc.) as separate on-demand subprocess binaries rather than bundling non-free binaries (avoid non-free `unrar`; use `unar`/`7zz`).

## Clean-room rule

- Build everything cleanly from scratch using public Apple frameworks, standard open-source tools, and original UI/code/assets.
- Never download, inspect, decompile, or copy binaries, source code, icons, or UI copy from commercial reference apps.

## Architecture rules

- **Pure native Swift / SwiftUI** targeting macOS 15+ (Swift Package Manager + Xcode app target).
- **On-demand downloads only:** Pure-Swift and Apple-framework tools add 0 MB external weight. Heavy engines/models live in `~/Library/Application Support/OpenToolbox/engines/`, downloaded only when the user enables/downloads a tool requiring them, verified by SHA-256, deduplicated across tools, and individually removable.
- **Originals untouched:** File tools must write new files to an output directory without silently overwriting originals.
- **Privacy first:** Offline by default; network access occurs only for explicit user-triggered actions (engine downloads, video URL downloads, network speed tests, map lookups).

## Dual-environment build & test workflow

- **Coding & orchestration (`.49` Linux server):** `/home/debian/Workspaces/OpenToolbox`
- **Native macOS build & test (`mac-mini` linked environment):** `/Users/pliu-bot/OpenToolbox`
  - `environmentId`: `5dd812dc-fcc5-481d-aaa6-180df7038894`
  - `projectId`: `mcp:599cc2a8-ce62-4c99-9558-0d2fb21c7ab6`
  - Authenticated with a **read-only** repo-scoped GitHub deploy key (`core.sshCommand` configured repo-locally for `/Users/pliu-bot/.ssh/id_ed25519_opentoolbox`). Do not attempt to push from `mac-mini`.
- Both checkouts share `origin` (`git@github.com:LetterXbox/OpenToolbox.git`, private GitHub repo until release).
- Do not attempt to compile SwiftUI/macOS targets on `.49`. Commit and push branches to `origin`, then delegate `git fetch` + `swift build` / `swift test` / `xcodebuild` to `mac-mini`'s `OpenToolbox` project (which runs Codex/Pi; use Codex `gpt-6.2-sol` Low for routine build/test runs).
