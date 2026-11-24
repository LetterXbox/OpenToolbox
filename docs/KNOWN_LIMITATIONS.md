# Known limitations

## Signing, platforms, and updates

- **Ad-hoc signing.** Releases are not notarized with an Apple Developer ID, so first launch requires **Open Anyway** in **System Settings → Privacy & Security**. Because the signature is ad-hoc, it proves the app bundle is intact rather than publisher identity, and trust in an update rests on the GitHub release. After an update, macOS may prompt again for **Screen Recording**, **Microphone**, **Speech Recognition**, and **Location** permissions.
- **Intel Macs untested.** The universal disk image includes Intel code, but releases are tested only on Apple silicon.
- **Read-only or translocated app locations.** If OpenToolbox cannot write to its own folder or runs from a temporary location, the update window links to GitHub Releases instead of self-updating.
- **Updates apply on restart or quit.** While OpenToolbox stays running in the menu bar, a ready update waits until you choose **Restart to Update** or quit.

## System and hardware requirements

- **Summarize.** Requires macOS 26 or later on a Mac with Apple Intelligence enabled.
- **Transcribe.** Uses Apple's newer on-device speech engine on macOS 26+ and the older on-device speech recognizer on earlier versions, which determines the languages offered.
- **Record Audio.** Requires a connected microphone. If a previously chosen microphone is disconnected, it falls back to the system default when macOS has one, or asks you to choose another microphone.
- **Scan Document.** Works with scanners supported by macOS Image Capture and with a nearby iPhone or iPad through Continuity Camera (**File → Import from iPhone or iPad**).

## Recording and background jobs

- **Unsaved recordings.** Record Screen and Record Audio capture into a hidden folder inside OpenToolbox's **Unsaved Recordings** store in Application Support. If the output folder refuses a finished recording, OpenToolbox keeps it in **Unsaved Recordings** (shown in both recorders) so you can save or discard it later. If a crash or forced quit interrupts a recording in that store, the part already written appears as "Interrupted Recording" the next time the list is shown; empty interrupted recordings are removed. OpenToolbox falls back to a temporary folder only if the **Unsaved Recordings** folder cannot be used, and does not recover temporary-folder recordings after a crash or forced quit. If saving a finished temporary-folder recording fails, copy the file from the path shown in the recorder error (or in a macOS notification if the recorder was already closed and notifications are allowed for OpenToolbox).
- **Closing windows during active jobs.** Closing a window stops a Network Speed Test, Disk Speed Test, or duplicate scan running in that window. File batches already running finish while OpenToolbox stays open; with the menu bar icon off, closing the last window quits the app.

## PDF, Office, and image tools

- **Office and Markdown to PDF.** Word to PDF, PowerPoint to PDF, Excel to PDF, and PDF exports in Convert Documents render offline through macOS Quick Look (with `textutil` fallback for Word, RTF, and ODT) and WebKit. Complex layouts, fonts, animations, or multi-sheet pagination may differ from Microsoft Office or LibreOffice. Remote images and external resources in Markdown and HTML are blocked during offline rendering.
- **Web Page to PDF.** Pages load without browser cookies or logins, so pages behind a sign-in save as their sign-in page. Splitting a page into A4 or US Letter pages can cut across a line of text.
- **PDF Password.** Printing, copying, and editing restrictions depend on PDF viewers respecting them. Removing a password or restrictions requires the owner password (or the single password if one was used for both).
- **Compress PDF.** Uses Ghostscript (`-dSAFER`); password-protected PDFs must be unlocked first, and copies that are not smaller are not saved.
- **Watermark and Compress Images.** Animated GIFs and multipage TIFFs are refused, and Compress Images does not save copies that are not smaller. Watermarked PDFs keep vector graphics and searchable text, but do not preserve interactive links, form fields, comments, or outlines.

## Archives, media, and disk tools

- **Zip & Unzip.** Refuses archives containing symlinks, hardlinks, or special files rather than publishing them.
- **Download Video.** Uses on-demand `yt-dlp` and `ffmpeg`; upstream site changes may require a newer `yt-dlp` build.
- **Disk Speed Test.** Creates and removes an uncached test file from the target folder before writing test data so it does not stay behind once the test starts. If removing that file fails, the test stops before writing and shows its path so you can delete it.
