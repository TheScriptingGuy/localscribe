"""Draws the LocalScribe launcher icons (ci/res, copied into android/ by CI)
and the store icon (fastlane). Sound bars turning into lines of text.
Run from the repo root: python tool/make_icons.py (needs Pillow)."""
import os
from PIL import Image, ImageDraw

S = 4  # supersampling
GROUND = (17, 17, 17, 255)
INK = (255, 255, 255, 255)


def glyph(d, size, scale, cx, cy):
    u = size * scale / 100.0
    cx -= 3.6 * u  # optical centre of the bars + lines
    w = 5.5 * u
    for x, h in [(-30, 10), (-21, 22), (-12, 32), (-3, 18)]:
        x0 = cx + x * u
        d.rounded_rectangle([x0 - w / 2, cy - h * u, x0 + w / 2, cy + h * u], radius=w / 2, fill=INK)
    for y, length in [(-14, 26), (-2, 34), (10, 22)]:
        x0 = cx + 6 * u
        d.rounded_rectangle([x0, cy + y * u - w / 2, x0 + length * u, cy + y * u + w / 2], radius=w / 2, fill=INK)


def render(px, scale, ground):
    n = px * S
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if ground == 'circle':
        d.ellipse([n * 0.04, n * 0.04, n * 0.96, n * 0.96], fill=GROUND)
    elif ground == 'square':
        d.rectangle([0, 0, n, n], fill=GROUND)
    glyph(d, n, scale, n / 2, n / 2)
    return im.resize((px, px), Image.LANCZOS)


for name, f in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
    out = f'ci/res/mipmap-{name}'
    os.makedirs(out, exist_ok=True)
    render(int(48 * f), 0.82, 'circle').save(f'{out}/ic_launcher.png')
    # Adaptive foreground: 108 dp canvas, glyph inside the 66 dp safe zone.
    render(int(108 * f), 0.55, None).save(f'{out}/ic_launcher_foreground.png')

store = 'fastlane/metadata/android/en-US/images'
os.makedirs(store, exist_ok=True)
render(512, 0.82, 'square').save(f'{store}/icon.png')
print('icons written')
