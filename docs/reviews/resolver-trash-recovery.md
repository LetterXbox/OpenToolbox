# Resolver record: Find Duplicates Trash recovery

**Outcome:** deferred to v0.1.1. Both judges said the issue is not critical, and the reviewer (GPT-6.2 Astra, high effort) confirmed that and allowed it to stay open past the v0.1 release.

## Lineage

| Round | Commit reviewed | What the reviewer said | Result |
| --- | --- | --- | --- |
| Raised: first review | `f34715e` | High: "Trash eligibility expires before Finder acts … Finder can then recycle a replacement or the last remaining copy." | Open |
| Attempt 1 | `6102430` (per-file staging, identity checks) | Medium: "Trash recovery and reporting can disagree with disk state … Even an ordinary successful move removes the recovery directory Finder may use as the Put Back destination." | Partial |
| Attempt 2 | `cc07a7a`, merged in `bd9a199` (Trash the original path; verified / restored / uncertain / skipped outcomes) | High: "Trash recovery can move an unrelated item into the source folder … If the receipt path was reused before the first `entry` lookup, the code records the unrelated occupant's identity and passes that identity to `restore`." (`DuplicateTrash.swift`, receipt lookup and recovery) | Partial, so escalated |

The issue failed two fix attempts, so it was escalated instead of getting a third ordinary fix round. Only the remaining path from the second re-check was escalated.

## Judges

Both judges worked separately from the same brief, read-only, at `bd9a199`.

**Claude Fable 5.2 (high effort):** not critical; no bar clause applies.

> The claimed path is real … but it needs two independent races to land inside one synchronous call. … Nothing is deleted or overwritten, because every move is `RENAME_EXCL`. … The false success is partial and self-flagging. The message wrongly says the file was restored, but it also says the file changed and tells the user to scan again. … It can ship in v0.1 as a documented known limitation.

**Gemini 4 Carbon (high thought level):** not critical; no bar clause applies.

> Ordinary races do not reach the bug [in-place edits keep the identity; atomic saves leave no single link, so the result is `.uncertain`; an original moved to Trash fails the parent check]. … Three ordered mutations across two directories must hit two consecutive millisecond-scale windows in a single `trash` call … the likelihood is effectively zero. … Residual: the displaced replacement stays in Trash, and a later manual Empty Trash could delete it if the user did not check Trash. … Safe to defer past the v0.1 release gate.

## Reviewer confirmation (round 3, at `4e0877c`)

> **Q1 — Yes, I confirm #1 is not critical under the stated bar.** The identity gap is real. … I found no realistic ordinary file operation that produces that combined sequence. If it does occur, the exclusive rename preserves existing destination entries, but the UI can identify the wrong item as restored while directing the user to rescan.
>
> **Q2 — Yes, #1 may stay open past v0.1.** For v0.1.1, return `.uncertain` on receipt identity mismatch and cover the combined parked-original and reused-receipt case with a test that verifies the unrelated occupant stays in place.

Release verdict for `4e0877c`: ship, with this item and the mid-export time-zone edge accepted as known v0.1 limitations.

## Follow-up for v0.1.1

- In `DuplicateTrash`, return `.uncertain` whenever the trashed item's identity does not match the reviewed file. Drop automatic recovery of a replacement that can't be shown to belong to this operation.
- Add a test that combines a parked original with an unrelated item at the receipt path, and assert that both Trash entries stay where they are.
