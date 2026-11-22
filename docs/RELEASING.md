# Releasing OpenToolbox

Run these steps for every release.

## 1. Planning: check what the inspiration apps shipped

At the start of work on each new release, look at the latest releases of both apps named in the README's "Inspiration & Credits":

- Toolbox for Mac (<https://mactoolbox.app/>), using its public changelog or release notes
- DevToys (<https://devtoys.app/>), using its public release notes

For each one, note the version and date of its latest release and list the features it added since our last check. Then decide what, if anything, to plan for. The roadmap is kept privately by the maintainers, so record the decisions there. The release PR description only names what was checked, for example: "Checked Toolbox for Mac 3.4 (2026-11-01) and DevToys 2.1 (2026-10-15)."

Clean-room boundary (see "Contributing" in the README):
- **Allowed:** reading public release notes, changelogs and feature lists to learn which features exist.
- **Not allowed:**
  - downloading, installing or decompiling the apps;
  - reading their source code, including open-source repositories;
  - copying their icons, screenshots, UI text or feature descriptions.
- Design and word our own versions of any feature from scratch.

## 2. Update the main README

Update `README.md` for every release because it holds the user-facing feature list, install instructions, and known limitations.

- Have **Gemini 4 Neon** write or update `README.md` so the tool list, highlights, privacy/network uses, build requirements, and known limitations accurately match the release.
- Keep existing project links (such as support/donation links, license, and credits) intact.

## 3. Review gate

Run the release review (GPT-6.2 Astra, high effort) on the release commit and resolve or explicitly defer every finding. Record deferrals in `docs/reviews/` and update the README's known-limitations list (via Gemini 4 Neon if the README changes).

## 4. Package

On a Mac with Xcode 26 or later, from a clean checkout of the release commit:

```sh
swift test
scripts/package-app.sh <version> <build-number>
```

The script builds a universal, ad-hoc signed `OpenToolbox.app`. Its output is in `.build/release-app/dist/`:
- `OpenToolbox.app`;
- `OpenToolbox-<version>-macOS-universal.dmg`, a drag-to-Applications disk image made by `scripts/make-dmg.sh` from that app;
- the disk image's `.sha256` file.

`make-dmg.sh` checks that the app inside the disk image is identical to the built app and validly signed. Before publishing, mount that exact disk image, copy the app to a fresh folder, launch it, and confirm it opens with no crash.

## 5. Publish

Create a GitHub release tagged `v<version>` on the release commit. Attach only the disk image.

The in-app updater depends on these exact conventions:
- The tag is `v<version>`, where `<version>` is three dotted numbers (for example `v0.2.0`). It must equal the app's `CFBundleShortVersionString`.
- The asset is named `OpenToolbox-<version>-macOS-universal.dmg`, and `OpenToolbox.app` sits at the top level of the disk image.
- By default, only the latest full release is offered. Drafts are never offered.
- The updater checks the asset's SHA-256 digest from the GitHub API, so the uploaded file must be the exact disk image from step 4.

### Test builds

A test build lets people try a release before it ships, through **Settings → Updates → Include test builds**. Apps with that option off never see test builds.

- Version it `<next version>-<stage>.<n>`, where the stage is `alpha`, `beta` or `rc`, for example `0.4.0-beta.1`. `scripts/package-app.sh` refuses any other form. Numbers count up within a stage, and `0.4.0-rc.1` comes after every `0.4.0-beta.<n>` and before `0.4.0`.
- Package it with that version, so the tag, the app's version and the asset name all carry the suffix: tag `v0.4.0-beta.1`, asset `OpenToolbox-0.4.0-beta.1-macOS-universal.dmg`.
- Publish it with `gh release create <tag> --prerelease --latest=false` on a commit of the release branch. Mark a release as a pre-release exactly when its tag has a suffix; the updater skips any release where the two disagree.
- Don't merge a test build into `main`. Afterwards, check that `https://api.github.com/repos/LetterXbox/OpenToolbox/releases/latest` still names the last full release.
- The full release is packaged separately with the plain version, because the version inside the app must match the tag exactly.
- Test builds get release notes in the same format as full releases.

### Release notes

- Have **Gemini 4 Neon** write every GitHub release note.
- Include **two sections only**: **New features** and **Bug fixes**, written plainly for people using the app.
- Leave out install steps, checksums, testing status, known limitations, and internal/review details. Install steps and known limitations live in `README.md`; what was and wasn't tested, and on which platform, goes in the release pull request.
