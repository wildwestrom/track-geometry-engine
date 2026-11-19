#!/usr/bin/env python3
"""Draw the thumbnail from the Lean geometry: shapes only, no text.

    lake env lean --run mod/thumbnail/Thumbnail.lean | python3 mod/thumbnail/thumbnail.py > mod/thumbnail/thumbnail.svg
"""
import json
import sys

BG = "#142129"
SPIRAL, ARC = "#e66fc8", "#52b8ea"
# the game's own colours (COLORS in tg_gui.script.tl), as 0-255 with the alpha apart
SLEEPER, RAIL = "#a2a9ac", "#a2a9ac"
PI, BRACKET, OSCULATING, INK = "#f2a900", "#4dff66", "#52b8ea", "#1c2733"

d = json.load(sys.stdin)
w, h = d["size"]
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
       f'<rect width="{w}" height="{h}" fill="{BG}"/>']


def xy(p):
    return f"{p[0]:g},{p[1]:g}"


def bezier(cubics):
    """One path: the cubics are consecutive, so each continues from the last one's end."""
    return f"M{xy(cubics[0][0])} " + " ".join(f"C{xy(c[1])} {xy(c[2])} {xy(c[3])}" for c in cubics)


def group(attrs, body):
    out.append(f"<g {attrs}>")
    out.extend(body)
    out.append("</g>")


arcs = [s for s in d["segments"] if s["kind"] == "arc"]

# each arc's osculating circle (a solid ring, as in the game), with its centre and radius
for s in arcs:
    c = s["circle"]
    out.append(f'<circle cx="{c["center"][0]:g}" cy="{c["center"][1]:g}" r="{c["r"]:g}" fill="none" '
               f'stroke="{OSCULATING}" stroke-width="13"/>')
    out.append(f'<path d="M{xy(c["center"])} L{xy(c["mid"])}" stroke="{OSCULATING}" stroke-width="8"/>')
    out.append(f'<circle cx="{c["center"][0]:g}" cy="{c["center"][1]:g}" r="14" fill="{OSCULATING}"/>')

# # the track: sleepers, then a rail either side of the path
# group(f'stroke="{SLEEPER}" stroke-width="20" stroke-linecap="butt"',
#       [f'<path d="M{xy(a)} L{xy(b)}"/>' for s in d["segments"] for a, b in s["sleepers"]])
# group(f'fill="none" stroke="{RAIL}" stroke-width="13" stroke-linejoin="round"',
#       [f'<path d="{bezier(r)}"/>' for s in d["segments"] for r in s["rails"]])

# # the path itself is the track's centre line, one colour per kind of segment
# (straights are left out: the tangent line already marks them)
colour = {"spiral": SPIRAL, "arc": ARC}


def centre_line(kind):
    group('fill="none" stroke-width="12" stroke-linejoin="round"',
          [f'<path d="{bezier(s["cubics"])}" stroke="{colour[kind]}"/>' for s in d["segments"] if s["kind"] == kind])


centre_line("arc")

# tangent lines through the PIs, over the centre line so it doesn't draw across them
group(f'fill="none" stroke="{PI}" stroke-width="14" stroke-linecap="round"',
      [f'<path d="M{xy(a)} L{xy(b)}"/>' for a, b in zip(d["pis"], d["pis"][1:])])

# the transitions go over the tangent lines
centre_line("spiral")

# the handles that adjust a curve: a bracket where each curve starts and ends
group(f'fill="none" stroke="{BRACKET}" stroke-width="18" stroke-linejoin="round" stroke-linecap="round"',
      [f'<path d="M{" L".join(xy(p) for p in s["bracket"])}"/>' for s in d["segments"] if "bracket" in s])

# PIs are rings; the two ends are dots
for p in d["pis"][1:-1]:
    out.append(f'<circle cx="{p[0]:g}" cy="{p[1]:g}" r="{d["grab"]:g}" fill="{BG}" stroke="{PI}" stroke-width="17"/>')
for p in (d["pis"][0], d["pis"][-1]):
    out.append(f'<circle cx="{p[0]:g}" cy="{p[1]:g}" r="28" fill="#ffffff"/>')

out.append("</svg>")
print("\n".join(out))
