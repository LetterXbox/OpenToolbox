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

## 2. Review gate

Run the release review (GPT-6.2 Astra, high effort) on the release commit and resolve or explicitly defer every finding. Record deferrals in `docs/reviews/` and in the README's known-limitations list.

## 3. Package

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

## 4. Publish

Create a GitHub release tagged `v<version>` on the release commit. Attach only the disk image.

The in-app updater depends on these exact conventions:
- The tag is `v<version>`, where `<version>` is dotted numbers only (for example `v0.2.0`). It must equal the app's `CFBundleShortVersionString`.
- The asset is named `OpenToolbox-<version>-macOS-universal.dmg`, and `OpenToolbox.app` sits at the top level of the disk image.
- Only the latest full release is offered. Drafts and pre-releases are never offered.
- The updater checks the asset's SHA-256 digest from the GitHub API, so the uploaded file must be the exact disk image from step 3.

Release notes have two sections only, **New features** and **Bug fixes**, written for people using the app. Install steps and known limitations live in the README. What was and wasn't tested, and on which platform, goes in the release pull request.
