# Escalation: Disk Speed Test drive identity

**Issue:** round 1 should-fix #4 of the v0.2.0 release review. The drive chosen in Disk Speed Test must still be the drive mounted at that path when the test starts.

## Lineage

| Round | Commit reviewed | Result | Remaining case, as the reviewer wrote it |
| --- | --- | --- | --- |
| 1 | `63ec128` | Raised | "The selected drive is identified only by its cached path. Select an external drive, replace it with another volume mounted under the same name, then start the test. The new drive receives the writes." |
| 2 | `401d51d` (attempt 1, `bc2bd71`) | Partial | "A missing UUID disables the identity check. Even with a UUID, a remount between its lookup and `stat(directory.path)` lets the subsequent directory and file checks agree on the replacement drive." |
| 3 | `5ee2c6d` (attempt 2) | Partial | "Apple's HFS implementation constructs that value [`f_fsid`] from the device number and filesystem type. Eject an HFS+ drive, then attach a different HFS+ drive that receives the same device number and mounts under the same name." |
| 4 | `7273e94` (attempt 3) | Partial | "A same-size block clone of an HFS+ drive preserves the volume UUID. If the clone replaces the original at the same mount path and receives the same device number, all three fields can match and the benchmark writes to the clone." |

At `7273e94`, the test opens the folder once. On that descriptor it checks the file system ID, the volume UUID and the volume's size. It then creates the test file relative to the folder with `O_CREAT | O_EXCL | O_NOFOLLOW`, and unlinks it before writing anything.

## Judges

Both judges worked independently and read-only on `4dcbfbb`, which only adds a test assertion to `7273e94`.

**Claude Fable 5.2 (high): not critical. Bar clause: none.**

> "The verdict rests on consequence, not rarity. Assume the swap happens and all three identity fields match. The only effect is a transient, self-removing write into free space on a volume the user had mounted under the name they chose when they pressed Start."
>
> "No existing file on B is opened, truncated, overwritten, renamed or deleted."
>
> **Can it wait past publishing v0.2.0?** "Yes. … bind the selection to a mount instance and drop it on unmount, for example by observing `NSWorkspace.didUnmountNotification` / `didMountNotification` and clearing or refreshing the selection."

**Gemini 4 Carbon (high): not critical. Bar clause: none.**

> "Descriptor-pinned, non-destructive I/O bounds the impact completely. … The test file … is created with `O_CREAT | O_EXCL | O_NOFOLLOW`—so it cannot overwrite, truncate, or follow any existing file or symlink—and `unlinkat` must succeed before the first `pwrite`."
>
> "Standard macOS backup tools … generate a fresh volume UUID on the target volume, which `VolumeIdentity.uuid` already catches. Even on a raw `dd` clone mounted read-write, 100% of backed-up files, directories, symlinks, and attributes remain untouched and usable."
>
> **Can it wait past publishing v0.2.0?** "Yes. It is safe to publish `v0.2.0` with this open … with unmount-notification invalidation left as non-blocking follow-up polish."

Residual risk both judges named:
- up to 4 GiB of the clone's free space is written and then freed;
- previously deleted files on the clone can no longer be recovered;
- the result is reported for the wrong physical drive.

## Decision

The issue is not critical, so it goes to the release reviewer to confirm the deferral. Separately, the volume list now reloads whenever a drive is mounted or ejected, which both judges suggested as the follow-up. The selection is kept only when the reloaded volume has the same identity.

## Confirmation

Pending.
