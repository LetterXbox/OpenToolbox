# Releasing OpenToolbox

Run these steps for every release.

## 1. Planning: check what the inspiration apps shipped

At the start of work on each new release, look at the latest releases of both apps named in the README's "Inspiration & Credits":

- Toolbox for Mac (<https://mactoolbox.app/>), using its public changelog or release notes
- DevToys (<https://devtoys.app/>), using its public release notes

For each one, note the version and date of its latest release and list the features it added since our last check. Then decide what, if anything, joins our roadmap. Record the result in the release PR description, for example: "Checked Toolbox for Mac 3.4 (2026-11-01) and DevToys 2.1 (2026-10-15); added X to Phase 2."

Clean-room boundary (see `AGENTS.md`):
- **Allowed:** reading public release notes, changelogs and feature lists to learn which features exist.
- **Not allowed:**
  - downloading, installing or decompiling the apps;
  - reading their source code, including open-source repositories;
  - copying their icons, screenshots, UI text or feature descriptions.
- Design and word our own versions of any feature from scratch.

## 2. Review gate

Run the release review (GPT-6.2 Astra, high effort) on the release commit and resolve or explicitly defer every finding. Record deferrals in `docs/reviews/` and in the README's known-limitations list.

## 3. Package

On a Mac with Xcode 16 or later, from a clean checkout of the release commit:

```sh
swift test
scripts/package-app.sh <version> <build-number>
```

The script builds a universal, ad-hoc signed `OpenToolbox.app`. Its output is in `.build/release-app/dist/`:
- `OpenToolbox-<version>-macOS-universal.zip`;
- `OpenToolbox-<version>-macOS-universal.dmg`, a drag-to-Applications disk image made by `scripts/make-dmg.sh` from the same app;
- a matching `.sha256` file for each.

Before publishing, unzip that exact zip into a fresh folder, launch the app, and confirm it opens with no crash. `make-dmg.sh` checks that the app inside the disk image is identical and validly signed.

## 4. Publish

Create a GitHub release tagged `v<version>` on the release commit. Attach the disk image, the zip and their `.sha256` files. The notes must include:
- the "Open Anyway" install steps (releases are not notarized);
- what was and wasn't tested;
- the known limitations.
