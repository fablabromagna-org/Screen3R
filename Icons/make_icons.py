#!/usr/bin/env python3
"""Draws the two Screen3R app icons (original artwork, GNU GPL v3 or later like the code).

    pip install cairosvg pillow && python3 Icons/make_icons.py

Writes host.svg / viewer.svg and 1024×1024 PNGs next to this script; build.sh turns the
PNGs into .icns files. host.ico (all Windows sizes) is the icon of Screen3R for Windows.
"""
import math, os, cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))

def arrows(cx, cy, r, color, width):
    parts = []
    for k in range(3):
        a0 = -90 + k * 120 + 14          # degrees, clockwise from top
        a1 = a0 + 78
        def pt(a, rr=r):
            t = math.radians(a)
            return cx + rr * math.cos(t), cy + rr * math.sin(t)
        x0, y0 = pt(a0); x1, y1 = pt(a1)
        parts.append(f'<path d="M {x0:.1f} {y0:.1f} A {r} {r} 0 0 1 {x1:.1f} {y1:.1f}" '
                     f'fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round"/>')
        # arrowhead at the end, pointing clockwise (tangent direction)
        tip_a = a1 + 19
        tx, ty = pt(tip_a)
        ox, oy = pt(a1, r + width * 1.15)
        ix, iy = pt(a1, r - width * 1.15)
        parts.append(f'<path d="M {ox:.1f} {oy:.1f} L {tx:.1f} {ty:.1f} L {ix:.1f} {iy:.1f} Z" '
                     f'fill="{color}" stroke="{color}" stroke-width="{width*0.35:.1f}" stroke-linejoin="round"/>')
    return "\n    ".join(parts)

def flow_arrow(direction, color, cy=447):
    """Horizontal arrow crossing a side wall of the monitor.
    'out': leaves through the right wall (sender). 'in': enters through the left wall (receiver)."""
    if direction == "out":
        x0, xb, xt = 712, 842, 912      # shaft start, head base, tip
    else:
        x0, xb, xt = 112, 242, 312
    h, H = 17, 44                        # half shaft height, half head height
    pts = [(x0, cy - h), (xb, cy - h), (xb, cy - H), (xt, cy), (xb, cy + H), (xb, cy + h), (x0, cy + h)]
    d = "M " + " L ".join(f"{x} {y}" for x, y in pts) + " Z"
    return (f'<path d="{d}" fill="{color}" stroke="#0b1424" stroke-width="10" stroke-linejoin="round" '
            f'paint-order="stroke"/>')

def icon(bg1, bg2, scr1, scr2, arrow, glow, direction):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{bg1}"/><stop offset="1" stop-color="{bg2}"/>
    </linearGradient>
    <linearGradient id="scr" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{scr1}"/><stop offset="1" stop-color="{scr2}"/>
    </linearGradient>
    <linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f4f6fa"/><stop offset="1" stop-color="#c9d0db"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.45" r="0.5">
      <stop offset="0" stop-color="{glow}" stop-opacity="0.55"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/>
    </radialGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity="0.35"/>
    </filter>
  </defs>
  <!-- background tile -->
  <rect x="100" y="100" width="824" height="824" rx="184" fill="url(#bg)"/>
  <!-- monitor -->
  <g filter="url(#shadow)">
    <path d="M 452 668 L 572 668 L 596 752 L 428 752 Z" fill="#aeb7c4"/>
    <rect x="378" y="742" width="268" height="34" rx="17" fill="url(#bezel)"/>
    <rect x="196" y="236" width="632" height="452" rx="44" fill="url(#bezel)"/>
    <rect x="226" y="266" width="572" height="362" rx="20" fill="url(#scr)"/>
  </g>
  <ellipse cx="512" cy="447" rx="270" ry="170" fill="url(#glow)"/>
  <!-- three chasing arrows: reduce, reuse, recycle -->
  <g>
    {arrows(512, 447, 112, arrow, 34)}
  </g>
  <!-- data flow: out of the sender, into the receiver -->
  {flow_arrow(direction, arrow)}
</svg>'''

host = icon("#2b3a5c", "#121a2e", "#0b2f3d", "#0f5f6b", "#7df0a8", "#3fe0a0", "out")
viewer = icon("#5a3a1e", "#21140a", "#3a2310", "#6b3f12", "#ffc062", "#ffab3d", "in")
for name, svg in (("host", host), ("viewer", viewer)):
    open(os.path.join(HERE, f"{name}.svg"), "w").write(svg)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(HERE, f"{name}-1024.png"),
                     output_width=1024, output_height=1024)
from PIL import Image   # noqa: E402  (only needed for the Windows icon)
Image.open(os.path.join(HERE, "host-1024.png")).convert("RGBA").save(
    os.path.join(HERE, "host.ico"), sizes=[(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
print("Icons written to", HERE)
