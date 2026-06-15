#!/usr/bin/env python3
"""Generate Mac Connect app icon.

Design: two triangles whose TIPS are joined by a semicircular arc, with three
concentric broadcast (signal) arcs ABOVE it. Black rounded-square bg, white glyph.

Outputs:
 - Android legacy mipmaps (ic_launcher / ic_launcher_round)
 - Android ADAPTIVE foreground (ic_launcher_foreground) for a clean look on 8.0+
 - macOS AppIcon set
"""

from PIL import Image, ImageDraw
import math, os

BG = (17, 17, 17)

def _draw_glyph(d, size):
    """Draw the white glyph (triangles + arc + signal) onto draw context d."""
    s = size / 1024.0
    cx = size / 2

    tri_half = int(108 * s)
    tri_h = int(tri_half * math.sqrt(3))
    left_cx = int(320 * s)
    right_cx = int(704 * s)
    tri_base_y = int(726 * s)
    lw = max(int(24 * s), 2)

    def triangle(tcx, base_y, half_w, height, width):
        top = (tcx, base_y - height)
        bl = (tcx - half_w, base_y)
        br = (tcx + half_w, base_y)
        d.line([bl, top, br, bl], fill="white", width=width, joint="curve")
        return top

    left_tip = triangle(left_cx, tri_base_y, tri_half, tri_h, lw)
    right_tip = triangle(right_cx, tri_base_y, tri_half, tri_h, lw)
    tip_y = tri_base_y - tri_h

    bulge = int(215 * s)
    arc_lw = max(int(22 * s), 2)
    d.arc([left_cx, tip_y - bulge, right_cx, tip_y + bulge], start=180, end=360,
          fill="white", width=arc_lw)

    dot_r = max(int(12 * s), 2)
    for (tx, ty) in (left_tip, right_tip):
        d.ellipse([tx - dot_r, ty - dot_r, tx + dot_r, ty + dot_r], fill="white")

    apex_y = tip_y - bulge
    sig_center = (cx, apex_y - int(8 * s))
    sig_lw = max(int(18 * s), 2)
    for rad in (50, 92, 134):
        rr = rad * s
        d.arc([sig_center[0] - rr, sig_center[1] - rr, sig_center[0] + rr, sig_center[1] + rr],
              start=212, end=328, fill="white", width=sig_lw)
    od = max(int(13 * s), 2)
    d.ellipse([sig_center[0] - od, sig_center[1] - od, sig_center[0] + od, sig_center[1] + od], fill="white")

def _render_glyph_centered(size, fill_ratio):
    """Render the glyph, crop to content, scale so its largest side = size*fill_ratio,
    and center it on a transparent canvas (gives even padding on all sides)."""
    big = 1024
    glyph = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    _draw_glyph(ImageDraw.Draw(glyph), big)
    cropped = glyph.crop(glyph.getbbox())
    target = int(size * fill_ratio)
    w, h = cropped.size
    scale = target / max(w, h)
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    cropped = cropped.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(cropped, ((size - nw) // 2, (size - nh) // 2), cropped)
    return canvas

def draw_icon(size=1024):
    # Legacy / macOS icon: glyph at ~60% with comfortable padding, on the bg.
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.18), fill=BG)
    glyph = _render_glyph_centered(size, fill_ratio=0.54)
    img.alpha_composite(glyph)
    return img

def draw_foreground(size, fill_ratio=0.42):
    # Adaptive foreground: smaller still, so launcher masking never crops it.
    return _render_glyph_centered(size, fill_ratio)

def make_round(img):
    size = img.size[0]
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out

def save_png(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG")
    print(f"  {os.path.relpath(path, base)} ({img.size[0]}x{img.size[1]})")

# Project root = parent of the scripts/ directory this file lives in.
base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
android_res = f"{base}/AndroidApp/app/src/main/res"
mac_iconset = f"{base}/MacApp/AndroidBridge/Assets.xcassets/AppIcon.appiconset"

icon = draw_icon(1024)
save_png(icon, f"{base}/icon_1024.png")

print("Android legacy + adaptive:")
densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
fg_densities = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
for density, sz in densities.items():
    resized = icon.resize((sz, sz), Image.LANCZOS)
    save_png(resized, f"{android_res}/mipmap-{density}/ic_launcher.png")
    save_png(make_round(resized), f"{android_res}/mipmap-{density}/ic_launcher_round.png")
for density, sz in fg_densities.items():
    save_png(draw_foreground(sz), f"{android_res}/mipmap-{density}/ic_launcher_foreground.png")

print("macOS:")
mac_icons = {
    "icon_16x16@1x.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32@1x.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128@1x.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256@1x.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512@1x.png": 512, "icon_512x512@2x.png": 1024,
}
for fn, sz in mac_icons.items():
    save_png(icon.resize((sz, sz), Image.LANCZOS), f"{mac_iconset}/{fn}")

print("\nDone!")
