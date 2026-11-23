# Resolver record: updater disk image inventory

**Outcome:** deferred past v0.1.2. Both judges said the issue is not critical, and the reviewer (GPT-6.2 Astra, high effort) confirmed that and allowed it to stay open past the v0.1.2 release.

## Lineage

| Round | Commit reviewed | What the reviewer said | Result |
| --- | --- | --- | --- |
| Raised: first re-check | `c87a792` | Should-fix: "Track image ownership through detach and retry. … Carry the expected image path through detach, re-query before retrying by device, and use a per-work-directory lease so another updater skips live work. Return the detach result." | Open |
| Attempt 1 | `654f480` (work folder lease, device looked up again before each detach, detach result, work kept on failure) | "A matching image with a missing device entry returns `true` immediately. A plist dictionary missing `images` is also interpreted as an empty list." | Partial |
| Attempt 2 | `6200973` (missing device or image list counts as attached; lease taken before the folder is published) | "One case remains: an image row with a mount point inside the work folder but no `image-path` is silently dropped by `compactMap`. `detach` can then report success without issuing a detach, and stale cleanup can attempt to remove a folder that still contains a mount." | Partial, so escalated |

Only the remaining case from the second attempt's re-check was escalated.

## Judges

Both judges worked separately from the same brief, read-only, at `026130b`.

**Claude Fable 5.2 (high effort):** not critical; no bar clause applies.

> The outcome is bounded by the attach flags, not by the inventory. Whether or not `removeItem` descends into the volume, a read-only mount refuses both the unlinks and the removal of its mount point. … what is lost is its contents (a re-downloadable cache file) and an explicit record. … The staged app sits next to the installed app, not in the work folder … A retry uses a fresh UUID folder, so the leftover does not block later updates. … Publishing v0.1.2 with this open risks at worst a hidden read-only mount and a stale cache folder that clear on restart.

**Gemini 4 Carbon (high thought level):** not critical; no bar clause applies.

> Emitting a live `mount-point` under `<work>/mount` with no `image-path` is not normal `hdiutil` behavior and requires a malformed/degraded `hdiutil info -plist` payload. … Nothing inside `<work>/mount/<Volume>` can be removed or modified … `rmdir` on the active mount point fails … with `EBUSY` … Only sibling regular files directly in `<work>/` — namely `<work>/.lease` and the [downloaded disk image] directory entry — are unlinked. … No user files, installed app bundles, or `/Applications` targets are touched, and no unverified code can be staged or installed. … It can wait past publishing `v0.1.2`.

## Reviewer confirmation (at `6d52efb`)

> Should-fix 3 may be deferred. A missing `image-path` drops the row before its mount points are examined, so `detach` can report success while the image remains mounted. For an updater-created mount, the image is attached read-only under the UUID work folder. Cleanup can unlink the cached download and lease and leave the mount behind. The installed app and staged copy are outside that folder, and a retry gets a fresh folder. I found no realistic critical outcome under the stated release bar.

## Follow-up

Keep inventory rows that have a mount point but no `image-path`, treat them as not detached for the work folder that holds the mount, and add a fixture for that row. Listed in the README's known limitations until then.

**Status:** done in v0.4.1. Inventory rows with a mount point but no `image-path` are kept. A row mounted inside a work folder counts as attached for that folder, is detached by device when it has one, and keeps the folder when it can't be detached. `imagesListedWithoutAPathKeepTheirWorkFolder` covers rows with and without a device.
