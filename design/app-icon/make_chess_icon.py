"""KaChat Chess app icon: a game controller in KaChat teal with the backward K (the Kaspa mark)
cut into its middle, a D-pad on the left and four buttons on the right.
`python3 make_chess_icon.py light|dark|tinted` writes kachat-chess-<variant>.svg (all three with
no argument)."""
import sys

PALETTES = {
    #          background  body top / bottom      K and controls  shadow
    "light":  ("#FFFFFF", ("#8AD6C9", "#5BBDAC"), "#FFFFFF", 0.18),
    "dark":   ("#1B2029", ("#8AD6C9", "#5BBDAC"), "#1B2029", 0.45),
    "tinted": ("#000000", ("#EDEDED", "#C4C4C4"), "#000000", 0.5),
}


def k_mark(cx, cy, height, color):
    # the backward K, traced from the KaChat app's icon (KaChat-iPhone AppIcon, where it is 434
    # tall): a chevron stroke and a bar whose edges both bend out at the middle. Centred on
    # (cx, cy), `height` tall.
    s = height / 434
    return (f'<g transform="translate({cx} {cy}) scale({s:.4f})">'
            f'<polyline points="-127,-147 64,0 -127,147" fill="none" stroke="{color}" stroke-width="78" stroke-miterlimit="4"/>'
            f'<polygon points="45,-206 123,-217 153,0 123,217 45,206 75,0" fill="{color}"/></g>')


def d_pad(cx, cy, color):
    # a plus with rounded ends, 132 across, arms 44 wide
    arm, half = 44, 66
    return (f'<rect x="{cx - half}" y="{cy - arm / 2}" width="{2 * half}" height="{arm}" rx="12" fill="{color}"/>'
            f'<rect x="{cx - arm / 2}" y="{cy - half}" width="{arm}" height="{2 * half}" rx="12" fill="{color}"/>')


def buttons(cx, cy, color):
    # four face buttons in a diamond
    gap, r = 48, 23
    return "".join(f'<circle cx="{cx + dx}" cy="{cy + dy}" r="{r}" fill="{color}"/>'
                   for dx, dy in ((0, -gap), (gap, 0), (0, gap), (-gap, 0)))


# The controller, one closed outline: the top edge, the right grip, the bottom between the grips,
# the left grip. Drawn a little low, then lifted 54 so it sits in the middle of the icon.
CONTROLLER = (
    "M330 300 L694 300 "
    "C800 300 858 336 880 412 "              # top right shoulder
    "C910 512 932 640 924 728 "              # right side
    "C916 806 836 832 786 784 "              # right grip, rounded bottom
    "C748 748 722 696 682 672 "              # right grip, inner edge
    "C604 652 420 652 342 672 "              # bottom between the grips
    "C302 696 276 748 238 784 "              # left grip, inner edge
    "C188 832 108 806 100 728 "              # left grip, rounded bottom
    "C92 640 114 512 144 412 "               # left side
    "C166 336 224 300 330 300 Z"             # top left shoulder
)


def svg(variant):
    bg, (top, bottom), k, shadow = PALETTES[variant]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity="{shadow}"/></filter>
  </defs>
  <rect width="1024" height="1024" fill="{bg}"/>
  <g transform="translate(0 -54)">
  <g filter="url(#soft)"><path d="{CONTROLLER}" fill="url(#body)"/></g>
  {d_pad(262, 470, k)}
  {buttons(762, 470, k)}
  {k_mark(512, 470, 200, k)}
  </g>
</svg>'''


def round_plus(cx, cy, arm, half, r):
    # d_pad as one outline: for each arm (up, right, down, left) out along its near side, around
    # its two rounded corners, back along its far side
    d = ""
    for ux, uy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
        vx, vy = -uy, ux  # across the arm, clockwise
        h = r * 0.55  # a curve's handle, for a quarter circle
        inner = (cx + ux * arm - vx * arm, cy + uy * arm - vy * arm)  # where it meets the last arm
        a = (cx + ux * (half - r) - vx * arm, cy + uy * (half - r) - vy * arm)
        b = (cx + ux * half - vx * (arm - r), cy + uy * half - vy * (arm - r))
        e = (cx + ux * half + vx * (arm - r), cy + uy * half + vy * (arm - r))
        f = (cx + ux * (half - r) + vx * arm, cy + uy * (half - r) + vy * arm)
        d += ("L" if d else "M") + f"{inner[0]:g} {inner[1]:g} L{a[0]:g} {a[1]:g} "
        d += f"C{a[0] + ux * h:g} {a[1] + uy * h:g} {b[0] - vx * h:g} {b[1] - vy * h:g} {b[0]:g} {b[1]:g} "
        d += f"L{e[0]:g} {e[1]:g} "
        d += f"C{e[0] + vx * h:g} {e[1] + vy * h:g} {f[0] + ux * h:g} {f[1] + uy * h:g} {f[0]:g} {f[1]:g} "
    return d + "Z "


def circle(cx, cy, r):
    h = r * 0.5523
    return (f"M{cx} {cy - r} "
            f"C{cx + h:g} {cy - r} {cx + r} {cy - h:g} {cx + r} {cy} "
            f"C{cx + r} {cy + h:g} {cx + h:g} {cy + r} {cx} {cy + r} "
            f"C{cx - h:g} {cy + r} {cx - r} {cy + h:g} {cx - r} {cy} "
            f"C{cx - r} {cy - h:g} {cx - h:g} {cy - r} {cx} {cy - r} Z ")


def k_outline(cx, cy, height):
    # k_mark's chevron and bar as one outline, where the chevron's arms meet the bar
    s = height / 434
    points = ((45, -206), (123, -217), (153, 0), (123, 217), (45, 206), (68.3, 45.9),
              (-103.2, 177.9), (-150.8, 116.1), (0, 0), (-150.8, -116.1), (-103.2, -177.9), (68.3, -45.9))
    return "M" + " L".join(f"{cx + x * s:.1f} {cy + y * s:.1f}" for x, y in points) + " Z "


def tab_icon():
    # The dock's Play icon: the controller with the same D-pad, buttons and K as holes through one
    # path, for the tab bar to tint. Tab bars don't scale images, so width and height are its size
    # in the dock.
    gap, r = 48, 23
    holes = round_plus(262, 470, 22, 66, 12) + k_outline(512, 470, 200) + "".join(
        circle(762 + dx, 470 + dy, r) for dx, dy in ((0, -gap), (gap, 0), (0, gap), (-gap, 0)))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="32" height="20" viewBox="96 293 832 520">
  <path fill-rule="evenodd" fill="#000000" d="{CONTROLLER} {holes.strip()}"/>
</svg>'''


if __name__ == "__main__":
    for variant in (sys.argv[1:] or [*PALETTES, "tab"]):
        open(f"kachat-chess-{variant}.svg", "w").write(tab_icon() if variant == "tab" else svg(variant))
