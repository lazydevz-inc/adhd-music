"""Builds the menu bar headset as filled SVG shapes (no strokes), same geometry as AppShell.MenuBarIcon.
Grid: 24 units, stroke 2. Output: band.svg (head band + ear cups) and wave.svg, 1024 canvas.

The headset-and-wave design these shapes draw is not under the MIT License: copyright lazydevz Inc.,
all rights reserved. See ASSETS.md. The files it writes carry the same notice."""
import math, sys, os
out = sys.argv[1]
S = float(sys.argv[2]) if len(sys.argv) > 2 else 26.0   # px per unit (glyph 19 units wide)
W = 1024
cx_u, cy_u = 12.0, 12.5        # glyph centre in units
ox, oy = W/2 - cx_u*S, W/2 - cy_u*S
def P(x, y): return (ox + x*S, oy + y*S)
def f(v): return f"{v:.2f}"
hw = 1.0  # half stroke

def arc_band(cx, cy, r, a0, a1, sweep_up=True):
    # annular sector from angle a0 to a1 (deg, SVG coords y down), round caps
    ro, ri = r + hw, r - hw
    def pt(rad, a): 
        x, y = P(cx + rad*math.cos(math.radians(a)), cy + rad*math.sin(math.radians(a)))
        return f(x), f(y)
    x0o, y0o = pt(ro, a0); x1o, y1o = pt(ro, a1); x1i, y1i = pt(ri, a1); x0i, y0i = pt(ri, a0)
    large = 1 if abs(a1 - a0) > 180 else 0
    capr = f(hw*S)
    return (f"M{x0o} {y0o} A{f(ro*S)} {f(ro*S)} 0 {large} 1 {x1o} {y1o} "
            f"A{capr} {capr} 0 0 1 {x1i} {y1i} "
            f"A{f(ri*S)} {f(ri*S)} 0 {large} 0 {x0i} {y0i} "
            f"A{capr} {capr} 0 0 1 {x0o} {y0o} Z")

def rrect(x, y, w, h, r):
    X, Y = P(x, y); return f'<rect x="{f(X)}" y="{f(Y)}" width="{f(w*S)}" height="{f(h*S)}" rx="{f(r*S)}"/>'
def circle(x, y, r):
    X, Y = P(x, y); return f'<circle cx="{f(X)}" cy="{f(Y)}" r="{f(r*S)}"/>'

# band: centre (12,13.5) r 8.5 from 180° to 360° (upper half in y-down coords)
band = arc_band(12, 13.5, 8.5, 180, 360)
cups = rrect(2.5, 13, 4, 7, 2) + rrect(17.5, 13, 4, 7, 2)
# wave: verticals x=8.25 (16.5→14.5), x=10.75 (14.5→18.5), x=13.25 (18.5→14.5), x=15.75 (14.5→16.5)
# arcs: top arcs centre (9.5,14.5) and (14.5,14.5) r1.25 (upper), bottom arc centre (12,18.5) r1.25 (lower)
wave_parts = []
for (x, y0, y1) in [(8.25, 14.5, 16.5), (10.75, 14.5, 18.5), (13.25, 14.5, 18.5), (15.75, 14.5, 16.5)]:
    wave_parts.append(rrect(x - hw, y0, 2*hw, y1 - y0, 0))
wave_parts.append(f'<path d="{arc_band(9.5, 14.5, 1.25, 180, 360)}"/>')
wave_parts.append(f'<path d="{arc_band(14.5, 14.5, 1.25, 180, 360)}"/>')
wave_parts.append(f'<path d="{arc_band(12, 18.5, 1.25, 0, 180)}"/>')
wave_parts.append(circle(8.25, 16.5, hw)); wave_parts.append(circle(15.75, 16.5, hw))
notice = ('<!-- The headset-and-wave design in this file is not under the MIT License: '
          'copyright lazydevz Inc., all rights reserved. See ASSETS.md. -->')
head = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">' + notice + '<g fill="#000000">'
open(os.path.join(out, "band.svg"), "w").write(head + f'<path d="{band}"/>' + cups + "</g></svg>")
open(os.path.join(out, "wave.svg"), "w").write(head + "".join(wave_parts) + "</g></svg>")
open(os.path.join(out, "glyph.svg"), "w").write(head + f'<path d="{band}"/>' + cups + "".join(wave_parts) + "</g></svg>")
print("ok", S)
