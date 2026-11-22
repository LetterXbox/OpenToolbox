# App icon

`AppIcon-1024.png` is the master artwork. `AppIcon.iconset/` holds the sizes made from it, and `scripts/package-app.sh` turns those into `AppIcon.icns` with `iconutil`.

## Design

An open white toolbox holding an amber wrench and a coral screwdriver, on a teal-to-blue rounded square. It is drawn with soft depth in the style of current macOS app icons, and the square leaves the standard transparent margin of about 100 px on each side.

## Provenance

- **Brief:** an original design brief, written under the project's clean-room rule. It forbade referencing or imitating any existing app's icon.
- **Concepts:** AI image generators produced eight concepts from that brief (Gemini 4 Neon and GPT-6.2 Sol).
- **Choice:** the owner chose Gemini 4 Neon's "open toolbox" concept.
- **This file:** that generated image, with its white background removed so the margin is transparent, and no other edits.

## Updating the icon

1. Replace `AppIcon-1024.png` with a 1024 × 1024 RGBA PNG.
2. Rebuild the iconset, which needs `pip install Pillow`:

   ```sh
   python Design/AppIcon/render_iconset.py
   ```
3. Commit the master and the iconset together.

Check the 16 px and 32 px files after any change.
