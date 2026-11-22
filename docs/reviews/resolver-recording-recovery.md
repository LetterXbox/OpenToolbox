# Escalations: recording recovery, microphone start and kept-file replacement (v0.3.0)

Three findings from the v0.3.0 release review failed two reviewed fix attempts. Each was judged independently by Claude Fable 5.2 and Gemini 4 Carbon against the project's bar for "critical", and Astra then confirmed the result.

## A. Recording recovery (round-1 #1, blocker)

| Round | Commit reviewed | Result |
| --- | --- | --- |
| 1 | `bfbec20` | Raised: a failed save deleted the only copy of a recording. |
| 2 | `452201c` (attempt 1, `0506802`) | Partial: starting another recording discarded the kept copy, and recovery wasn't reachable after the view closed. |
| 3 | `55230dd` (attempt 2) | Partial: "If a recorder closes and both the output write and the move into Application Support fail, the only copy stays in a temporary directory. Its path exists only in the closed recorder's error message." |

**Fable: not critical.** "It needs two faults at once, and I found no single realistic cause for both in a standard layout. ... Nothing in the app deletes the file on this path ... With the view open, the stop is visible and names the path in selectable text." Residual risk: a home folder on a separate, full or detached volume; macOS may eventually purge the temporary file. It can wait past the v0.3.0 gate if recorded here and in the README.

**Carbon: not critical.** "In every realistic save failure (unplugged/full external output drive, denied `~/Downloads` TCC permission, read-only or symlink-blocked output directory), `RecordingStore.keep` is an atomic same-volume `rename(2)` needing zero data blocks ... no failure path deletes an unsaved recording." It can wait past v0.3.0.

**Astra (round 4): confirmed not critical, and it may stay open past the v0.3.0 gate.** The README's known limitations must tell users to copy the recording from the displayed path before closing the view.

**Decision: deferred.** The later fix is to record straight into a durable recovery location so that no rescue move is needed.

## B. Microphone start after close (round-1 #6)

| Round | Commit reviewed | Result |
| --- | --- | --- |
| 1 | `bfbec20` | Raised: a permission prompt could outlive the view and start an orphan recording. |
| 2 | `452201c` (attempt 1, `0506802`) | Partial: the task could enter `start()` after `close()`. |
| 3 | `55230dd` (attempt 2) | Partial: reopening the same view during the prompt cleared the close flag. |

**Fable and Carbon: not critical.** The user pressed Record and allowed the microphone. The recording is visible, indicated by macOS and stoppable, and there's no network use or data loss.

**Decision: fixed** in `0078095` with a per-start generation token, which is captured when Record is pressed and invalidated on close. **Astra (round 4): resolved.**

## C. A kept recording replaced by another file (round-3 finding, continued in rounds 4 and 5)

| Round | Commit reviewed | Result |
| --- | --- | --- |
| 3 | `55230dd` | Raised: Unsaved Recordings listed any entry, so Discard could delete a folder a user put there. |
| 4 | `0078095` (attempt 1, `807f001`) | Partial: a linked tool folder, or a listed entry later replaced by a folder, could still be deleted. |
| 5 | `2939e27` (attempt 2) | Linked folder resolved. Partial: a different regular file swapped in between the identity check and the open or unlink could be copied or removed. |

**Fable: not critical.** "The app cannot race itself. Every caller ... runs on the main actor ... The race gives an attacker nothing new. The app is not sandboxed, so any process able to make the swap can already delete or replace those files ... The blast radius is bounded: one regular file, inside OpenToolbox's own recovery folder, under a name OpenToolbox generated." It recommended checking the opened descriptor before copying.

**Carbon: not critical.** "No realistic concurrent writer exists for that path ... any process able to race inside it already runs as the same user with direct write/unlink access there." Residual risk: the microsecond gap between `fstatat` and `unlinkat`.

**Astra (round 6): confirmed not critical, and the unlink gap may stay open past the v0.3.0 gate.** The read gap is closed by `e5c4c5d`, which checks the opened descriptor's type, device and inode before copying.

**Decision:** the read gap is fixed. Deferred: move the entry into private same-volume staging, verify it there, and only then unlink it, for both Discard and cleanup after Save.
