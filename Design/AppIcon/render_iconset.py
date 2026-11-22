"""Builds the macOS iconset from AppIcon-1024.png; scripts/package-app.sh turns the iconset into AppIcon.icns.

Each size is a high-quality (Lanczos) downscale of the 1024 px master.
Requires Pillow (pip install Pillow). Run from anywhere:

    python Design/AppIcon/render_iconset.py
"""

from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
MASTER = HERE / "AppIcon-1024.png"
ICONSET = HERE / "AppIcon.iconset"

# (file name, pixel size) as iconutil expects them.
SIZES = [
    (f"icon_{points}x{points}{suffix}.png", points * scale)
    for points in (16, 32, 128, 256, 512)
    for scale, suffix in ((1, ""), (2, "@2x"))
]


def main() -> None:
    master = Image.open(MASTER).convert("RGBA")
    if master.size != (1024, 1024):
        raise SystemExit(f"{MASTER.name} must be 1024 x 1024, not {master.size}")
    ICONSET.mkdir(exist_ok=True)
    for name, pixels in SIZES:
        image = master if pixels == 1024 else master.resize((pixels, pixels), Image.LANCZOS)
        image.save(ICONSET / name, optimize=True)
        print(f"{name}: {pixels} px")


if __name__ == "__main__":
    main()
