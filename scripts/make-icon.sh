#!/usr/bin/env bash
# Regenerate the MultiverseWP app icon set deterministically.
#
# Concept: teal-green rounded square (#075E54) with a white infinity / multiverse
# glyph centred. Reproducible from this script — no binary artwork is checked in
# that cannot be regenerated here.
#
# Tools required: python3 (with Pillow), sips, iconutil. All pre-installed on
# the developer's macOS environment.
#
# Output:
#   Resources/Assets.xcassets/AppIcon.appiconset/icon_<size>(@2x).png
#   Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
#   build/AppIcon.icns (optional, for distribution / Sparkle)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$REPO_ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
BUILD_DIR="$REPO_ROOT/build"
BASE_PNG="$BUILD_DIR/icon-1024-base.png"

mkdir -p "$ASSET_DIR" "$BUILD_DIR"

echo "==> Rendering 1024x1024 base via Pillow"
python3 - "$BASE_PNG" <<'PY'
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
SIZE = 1024
BG = (7, 94, 84, 255)          # #075E54 teal-green
BG_DARK = (4, 64, 57, 255)     # subtle gradient bottom
FG = (255, 255, 255, 255)

# Base canvas (transparent) — macOS asset catalog handles the rounded mask but
# we draw our own rounded square so the .icns also looks polished standalone.
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Rounded-square background with a vertical gradient (top-light → bottom-dark).
RADIUS = int(SIZE * 0.225)  # macOS Big Sur-ish "squircle-ish" radius

# Vertical gradient layer.
gradient = Image.new("RGBA", (SIZE, SIZE), BG)
gd = ImageDraw.Draw(gradient)
for y in range(SIZE):
    t = y / (SIZE - 1)
    r = int(BG[0] * (1 - t) + BG_DARK[0] * t)
    g = int(BG[1] * (1 - t) + BG_DARK[1] * t)
    b = int(BG[2] * (1 - t) + BG_DARK[2] * t)
    gd.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

# Rounded mask.
mask = Image.new("L", (SIZE, SIZE), 0)
mdraw = ImageDraw.Draw(mask)
mdraw.rounded_rectangle([(0, 0), (SIZE, SIZE)], radius=RADIUS, fill=255)

img.paste(gradient, (0, 0), mask)

# Inner soft highlight at the top — gives a subtle "glass" feel without
# overdoing skeuomorphism.
hl = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
hd.ellipse(
    [(-int(SIZE * 0.2), -int(SIZE * 0.55)),
     (int(SIZE * 1.2), int(SIZE * 0.45))],
    fill=(255, 255, 255, 38),
)
hl = hl.filter(ImageFilter.GaussianBlur(radius=18))
hl_masked = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hl_masked.paste(hl, (0, 0), mask)
img = Image.alpha_composite(img, hl_masked)

# Infinity / multiverse glyph — two overlapping circles forming a lemniscate.
# Stroke-only, generous padding from the rounded square.
glyph = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd2 = ImageDraw.Draw(glyph)

cx, cy = SIZE / 2, SIZE / 2
# Lobe geometry.
lobe_radius = SIZE * 0.18
lobe_dx = SIZE * 0.18
stroke = int(SIZE * 0.07)

left_box = (
    cx - lobe_dx - lobe_radius, cy - lobe_radius,
    cx - lobe_dx + lobe_radius, cy + lobe_radius,
)
right_box = (
    cx + lobe_dx - lobe_radius, cy - lobe_radius,
    cx + lobe_dx + lobe_radius, cy + lobe_radius,
)
gd2.ellipse(left_box,  outline=FG, width=stroke)
gd2.ellipse(right_box, outline=FG, width=stroke)

# A faint inner dot in each lobe — the "two worlds" cue.
dot_r = SIZE * 0.022
gd2.ellipse(
    (cx - lobe_dx - dot_r, cy - dot_r,
     cx - lobe_dx + dot_r, cy + dot_r),
    fill=(255, 255, 255, 200),
)
gd2.ellipse(
    (cx + lobe_dx - dot_r, cy - dot_r,
     cx + lobe_dx + dot_r, cy + dot_r),
    fill=(255, 255, 255, 200),
)

img = Image.alpha_composite(img, glyph)
img.save(OUT, "PNG", optimize=True)
print(f"   wrote {OUT}")
PY

echo "==> Resizing into AppIcon.appiconset"
# Sizes Apple expects for a macOS app icon set.
declare -a TARGETS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

# Wipe stale PNGs (keep Contents.json — we will rewrite it).
find "$ASSET_DIR" -maxdepth 1 -type f -name '*.png' -delete

for entry in "${TARGETS[@]}"; do
  PX="${entry%%:*}"
  NAME="${entry##*:}"
  /usr/bin/sips -s format png -z "$PX" "$PX" "$BASE_PNG" \
    --out "$ASSET_DIR/$NAME" >/dev/null
done

echo "==> Writing Contents.json"
cat > "$ASSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "==> Building AppIcon.icns (optional, for DMG / Sparkle)"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# iconutil expects specific filenames.
for entry in "${TARGETS[@]}"; do
  PX="${entry%%:*}"
  NAME="${entry##*:}"
  cp "$ASSET_DIR/$NAME" "$ICONSET/${NAME//icon_/icon_}"
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> Done."
ls -la "$ASSET_DIR"
