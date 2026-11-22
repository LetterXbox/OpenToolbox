# Escalation: recording recovery and microphone start (v0.3.0)

Two findings from the v0.3.0 release review failed two reviewed fix attempts. Each was judged independently by Claude Fable 5.2 and Gemini 4 Carbon against the project's bar for "critical", and Astra then confirmed the result.

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
