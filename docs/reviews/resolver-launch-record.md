# Resolver record: updater launch record

**Outcome:** deferred past v0.1.2. Both judges said the issue is not critical, and the reviewer (GPT-6.2 Astra, high effort) confirmed that and allowed it to stay open past the v0.1.2 release.

## Lineage

| Round | Commit reviewed | What the reviewer said | Result |
| --- | --- | --- | --- |
| Raised: first review | `e0399ff` | Blocker: "Quit can delete an unrelated item at the original app path. `install` never checks what currently occupies `installedApp` … A manual upgrade during the same interval can also be silently rolled back." | Open |
| Attempt 1 | `c87a792` (device and inode recorded at prepare time, checked before and after the swap) | "The baseline itself comes from `lstat` on whatever directory occupies `installedApp` when `prepare` begins … An in-place upgrade that retains the top-level directory also passes both identity checks." | Partial |
| Attempt 2 | `654f480` (identity and whole-executable and `Info.plist` digests recorded at launch, checked before download, before the swap and on the displaced bundle) | "`UpdateCenter` reads the running version, synchronously removes leftovers, then schedules a detached task to read the app **by path**. If a manual upgrade lands before that task reads the path, the older process can record the newer installation and later overwrite it." | Partial, so escalated |

Only the remaining path from the second re-check was escalated.

## Judges

Both judges worked separately from the same brief, read-only, at `654f480`.

**Claude Fable 5.2 (high effort):** not critical; no bar clause applies.

> Harm needs three things together. A complete replacement of the app lands inside the launch interval … What lands is newer than the latest full release, or is not OpenToolbox at all. The manual upgrade you describe normally installs L or older, which gives the two harmless rows. The user then authorises installing L at that path. … What is lost in the worst row: a re-downloadable or rebuildable app bundle. User data lives outside the bundle. … It can ship in v0.1.2 as a recorded deferral.

**Gemini 4 Carbon (high thought level):** not critical; no bar clause applies.

> Even measured conservatively from `execve`, the window is tens of milliseconds; measured from `Bundle.main` `Info.plist` read to `lstat(appURL)`, it is typically 1–10 ms. … If OpenToolbox is already running when a manual upgrade begins, `launchRecord` finished at launch and `isUnchanged` refuses cleanly … An actual downgrade or unintended deletion requires both hitting the … race via a concurrent script and placing a build newer than `releases/latest` … or a non-OpenToolbox `.app` at `/Applications/OpenToolbox.app`. … Safe to defer past publishing `v0.1.2`.

## Reviewer confirmation (at `6200973`)

> (1) Yes, I confirm the non-critical assessment. (2) Yes, C1 may stay open past v0.1.2 as a documented deferral. … a consequential replacement must land in that specific interval, survive the subsequent identity and content checks, and later be displaced by an authorized update. I found no realistic critical scenario under the supplied bar. Track binding the record to the running executable as the follow-up.

## Follow-up

Bind the launch record to the running process: capture the bundle's identity synchronously at startup and check that the executable on disk is the one running (for example by the running image's `LC_UUID` or code directory hash), with a test that delays the read and replaces the destination. Listed in the README's known limitations until then.

**Status:** done in v0.4.1. The launch record takes the bundle's identity and `Info.plist` digest synchronously at startup, and the background read refuses the bundle unless its executable contains the running build's `LC_UUID`, read from the same open file that is hashed. `aLaunchRecordRefusesAnAppReplacedBeforeItsExecutableIsRead` replaces the executable, then the whole bundle, after the record is taken and checks that both are refused.
