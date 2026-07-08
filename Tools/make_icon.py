#!/usr/bin/env python3
"""NOOP app icon — Titanium & Gold v3.1 "gold on navy".

A deep-navy tile + a THICK open gold recovery ring (round-capped, gold gradient
along the sweep) + a solid gold core dot. Matches the in-app BrandMark geometry
(open ~80% arc from 12 o'clock, clockwise) but on navy with a heavier stroke.

Usage: make_icon.py            -> writes noop_icon_1024.png + noop_icon_432.png
Distribute with distribute_icons.sh.
"""
import os, math, sys
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))

def hx(h):
    h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

NAVY_TOP = hx('#0A1322')   # navy canvas, slightly lifted at top
NAVY_BOT = hx('#05080F')   # deeper navy at the bottom
GLOW     = hx('#17263E')   # subtle cool glow
GOLD_LIGHT = hx('#FCEBA8') # pale cream-gold (StrandPalette.goldLight)
GOLD       = hx('#E8B84B') # brand gold (StrandPalette.gold)
GOLD_DEEP  = hx('#C8902F') # deep antique gold (StrandPalette.goldDeep)

def lerp(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
def grade(t):
    """Gold ramp along the ring: pale -> brand -> deep."""
    return lerp(GOLD_LIGHT, GOLD, t / 0.5) if t < 0.5 else lerp(GOLD, GOLD_DEEP, (t - 0.5) / 0.5)

def render(S, ring_scale=1.0):
    SS = 4                      # supersample for clean anti-aliasing
    W = S * SS

    # --- navy background: vertical gradient + soft upper radial glow ---
    grad = np.empty((W, W, 3), float)
    ys = np.linspace(0, 1, W)[:, None]
    for c in range(3):
        grad[:, :, c] = NAVY_TOP[c] + (NAVY_BOT[c] - NAVY_TOP[c]) * ys
    yy, xx = np.mgrid[0:W, 0:W]
    d = np.sqrt((xx - W * 0.5) ** 2 + (yy - W * 0.40) ** 2)
    glow = np.clip(1 - d / (W * 0.72), 0, 1) ** 2.0
    for c in range(3):
        grad[:, :, c] = np.clip(grad[:, :, c] + glow * GLOW[c] * 0.6, 0, 255)
    img = Image.fromarray(grad.astype(np.uint8), 'RGB').convert('RGBA')

    # --- gold mark layer ---
    mark = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    md = ImageDraw.Draw(mark)
    cx = cy = W / 2.0
    outer_r = 0.39 * W * ring_scale
    ring_w  = 0.135 * W * ring_scale
    center_r = outer_r - ring_w / 2.0
    core_r   = 0.090 * W * ring_scale
    seg_r    = ring_w / 2.0

    # Open ~84% ring with the gap centred at the TOP: pale cap at the upper-left
    # (~11 o'clock), sweeping the long way (down the left, round the bottom, up the
    # right) to the deep cap at the upper-right (~1 o'clock). Drawn as round dabs
    # colour-graded pale -> deep along the sweep (round caps for free).
    start_deg, span = 241.0, -302.0     # PIL angles (0=E, +CW); see note above
    n = 1700
    for i in range(n + 1):
        t = i / n
        a = math.radians(start_deg + span * t)
        x, y = cx + center_r * math.cos(a), cy + center_r * math.sin(a)
        col = tuple(int(v) for v in grade(t)) + (255,)
        md.ellipse([x - seg_r, y - seg_r, x + seg_r, y + seg_r], fill=col)

    # Core dot: SOLID gold disc (opaque). PIL's ImageDraw REPLACES pixels rather
    # than blending, so a semi-transparent sheen drawn here would punch the navy
    # through — instead the sheen rides on its own layer, alpha_composited below.
    md.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=GOLD + (255,))

    img = Image.alpha_composite(img, mark)

    # Subtle lighter top-sheen on the core (own layer, properly blended).
    sheen = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    sr = core_r * 0.92
    ImageDraw.Draw(sheen).ellipse(
        [cx - sr, cy - sr * 1.05, cx + sr, cy + sr * 0.35], fill=GOLD_LIGHT + (90,))
    coremask = Image.new('L', (W, W), 0)
    ImageDraw.Draw(coremask).ellipse(
        [cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=255)
    img.paste(Image.alpha_composite(img, sheen), (0, 0), coremask)
    return img.resize((S, S), Image.LANCZOS)

if __name__ == '__main__':
    # Flatten to RGB (no alpha) for the iOS/macOS app icon. iOS app icons MUST be fully opaque, an
    # RGBA icon renders glitched when applied as an alternate icon (#708). The art already fills the
    # whole opaque navy tile, so dropping the all-255 alpha channel changes nothing visible.
    render(1024, ring_scale=1.00).convert('RGB').save(os.path.join(OUT, 'noop_icon_1024.png'))   # iOS/macOS (squircle shows full art)
    render(432,  ring_scale=0.80).save(os.path.join(OUT, 'noop_icon_432.png'))     # Android adaptive bg (ring inside safe-zone)
    print('wrote noop_icon_1024.png, noop_icon_432.png, noop_icon_preview.png')
