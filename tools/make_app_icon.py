"""Render the app icon (1024x1024 PNGs) into the AppIcon asset catalog.

Motif: an electric car (side view) with a lightning bolt on the door and radio waves above the roof -
"talking to an EV". Pure standard library: shapes are signed distance fields, anti-aliased per pixel and
written with zlib. Run from the repository root:  python tools/make_app_icon.py [default|dark|tinted ...]
Outputs the default, dark and tinted variants referenced by AppIcon.appiconset/Contents.json.
"""

import math
import struct
import sys
import zlib
from pathlib import Path

SIZE = 1024
OUT_DIR = Path(__file__).resolve().parent.parent / "OBDDisplay" / "Assets.xcassets" / "AppIcon.appiconset"
PIXEL = 2.0 / SIZE

# Normalized coordinates: [-1, 1], y pointing down.
CAR_Y = 0.20                         # vertical shift of the whole car
BODY_CENTER, BODY_HALF, BODY_RADIUS = (0.0, 0.14 + CAR_Y), (0.66, 0.13), 0.11
CABIN = [(-0.44, 0.04 + CAR_Y), (-0.22, -0.20 + CAR_Y), (0.20, -0.20 + CAR_Y), (0.46, 0.04 + CAR_Y)]
CABIN_ROUND = 0.05
WINDOW = [(-0.33, 0.00 + CAR_Y), (-0.18, -0.14 + CAR_Y), (0.16, -0.14 + CAR_Y), (0.34, 0.00 + CAR_Y)]
WINDOW_SPLIT_X, WINDOW_SPLIT_HALF = -0.01, 0.022
WHEELS = [(-0.38, 0.30 + CAR_Y), (0.38, 0.30 + CAR_Y)]
WHEEL_R, RIM_R, HUB_R = 0.135, 0.085, 0.030
WHEEL_GAP = 0.03                     # dark ring around the wheels, cut out of the body

# Lightning bolt on the door (polygon, clockwise).
BOLT = [(0.035, 0.035), (-0.075, 0.175), (-0.005, 0.175), (-0.040, 0.300),
        (0.075, 0.150), (0.005, 0.150), (0.035, 0.035)]
BOLT = [(0.02 + x * 0.9, CAR_Y + 0.135 + (y - 0.1675) * 0.85) for x, y in BOLT]   # mittig auf der Tür

# Radio waves above the roof, opening upwards: (radius, alpha).
WAVE_CENTER = (0.0, -0.22 + CAR_Y)
WAVES = [(0.17, 1.0), (0.29, 0.75), (0.41, 0.5)]
WAVE_HALF_WIDTH = 0.026
WAVE_APERTURE = math.radians(38)     # half opening angle around "up"

CYAN = (0.20, 0.90, 1.00)
GREEN = (0.35, 1.00, 0.55)
WHITE = (1.00, 1.00, 1.00)
GLASS = (0.05, 0.16, 0.30)
TIRE = (0.04, 0.05, 0.08)
RIM = (0.70, 0.80, 0.88)
BG_STOPS = [(0.0, (0.01, 0.05, 0.10)), (0.55, (0.02, 0.22, 0.32)), (1.0, (0.04, 0.42, 0.40))]


def seg_dist(px, py, ax, ay, bx, by):
    pax, pay, bax, bay = px - ax, py - ay, bx - ax, by - ay
    h = max(0.0, min(1.0, (pax * bax + pay * bay) / (bax * bax + bay * bay)))
    dx, dy = pax - bax * h, pay - bay * h
    return math.sqrt(dx * dx + dy * dy)


def poly_dist(px, py, pts):
    """Signed distance to a closed polygon (negative inside)."""
    d = min(seg_dist(px, py, *a, *b) for a, b in zip(pts, pts[1:] + pts[:1]))
    inside = False
    for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
        if (ay > py) != (by > py) and px < (bx - ax) * (py - ay) / (by - ay) + ax:
            inside = not inside
    return -d if inside else d


def box_dist(px, py, center, half, radius):
    qx = abs(px - center[0]) - half[0] + radius
    qy = abs(py - center[1]) - half[1] + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def circle_dist(px, py, center, radius):
    return math.hypot(px - center[0], py - center[1]) - radius


def wave_dist(px, py, radius):
    x, y = px - WAVE_CENTER[0], WAVE_CENTER[1] - py      # y up
    if y <= 0:
        return 9.0
    angle = math.atan2(abs(x), y)                         # 0 = straight up
    if angle < WAVE_APERTURE:
        d = abs(math.hypot(x, y) - radius)
    else:
        d = math.hypot(abs(x) - radius * math.sin(WAVE_APERTURE), y - radius * math.cos(WAVE_APERTURE))
    return d - WAVE_HALF_WIDTH


def coverage(d):
    return max(0.0, min(1.0, 0.5 - d / PIXEL))


def lerp(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def over(dst, src, alpha):
    return tuple(d + (s - d) * alpha for d, s in zip(dst, src))


def background(u, v):
    t = max(0.0, min(1.0, (u + v) / 4 + 0.5))
    for (t0, c0), (t1, c1) in zip(BG_STOPS, BG_STOPS[1:]):
        if t <= t1:
            color = lerp(c0, c1, (t - t0) / (t1 - t0))
            break
    glow = 0.30 * math.exp(-(u * u + (v - CAR_Y) ** 2) / 0.35)
    return tuple(min(1.0, c + k * glow) for c, k in zip(color, CYAN))


def layers(u, v):
    """Coverage of every shape at (u, v)."""
    body = min(box_dist(u, v, BODY_CENTER, BODY_HALF, BODY_RADIUS), poly_dist(u, v, CABIN) - CABIN_ROUND)
    wheel_hole = min(circle_dist(u, v, w, WHEEL_R + WHEEL_GAP) for w in WHEELS)
    body = max(body, -wheel_hole)                         # wheel arches cut out of the body
    window = max(poly_dist(u, v, WINDOW), -(abs(u - WINDOW_SPLIT_X) - WINDOW_SPLIT_HALF))
    tire = min(circle_dist(u, v, w, WHEEL_R) for w in WHEELS)
    rim = min(abs(circle_dist(u, v, w, RIM_R)) - 0.018 for w in WHEELS)
    hub = min(circle_dist(u, v, w, HUB_R) for w in WHEELS)
    bolt = poly_dist(u, v, BOLT[:-1])
    waves = [(coverage(wave_dist(u, v, r)) * a, wave_dist(u, v, r)) for r, a in WAVES]
    return body, window, tire, min(rim, hub), bolt, waves


def render(variant):
    rows = []
    for j in range(SIZE):
        v = (j + 0.5) / SIZE * 2 - 1
        row = bytearray([0])  # PNG filter type: none
        for i in range(SIZE):
            u = (i + 0.5) / SIZE * 2 - 1
            body, window, tire, rim, bolt, waves = layers(u, v)
            a_body, a_window, a_tire, a_rim, a_bolt = (coverage(d) for d in (body, window, tire, rim, bolt))
            a_wave = max(a for a, _ in waves)
            d_wave = min(d for _, d in waves)

            if variant == "default":
                color = background(u, v)
                glow = 0.45 * math.exp(-max(d_wave, 0.0) / 0.05) + 0.35 * math.exp(-max(body, 0.0) / 0.06)
                color = tuple(min(1.0, c + k * glow) for c, k in zip(color, CYAN))
                color = over(color, CYAN, a_wave)
                body_color = lerp(WHITE, (0.78, 0.93, 1.0), max(0.0, min(1.0, (v - CAR_Y + 0.2) / 0.5)))
                color = over(color, body_color, a_body)
                color = over(color, GLASS, a_window * a_body)
                color = over(color, TIRE, a_tire)
                color = over(color, RIM, a_rim)
                bolt_glow = 0.6 * math.exp(-max(bolt, 0.0) / 0.03) * a_body
                color = tuple(min(1.0, c + k * bolt_glow * 0.4) for c, k in zip(color, GREEN))
                color = over(color, GREEN, a_bolt)
                a = 1.0
            elif variant == "dark":
                # Transparent background; iOS supplies the dark backdrop. Car as outline-free silhouette.
                a = max(a_wave, a_body, a_tire)
                color = CYAN
                color = over(color, WHITE, a_body / a if a else 0.0)
                color = over(color, GLASS, a_window * a_body)
                color = over(color, (0.12, 0.14, 0.18), a_tire)
                color = over(color, RIM, a_rim)
                color = over(color, GREEN, a_bolt)
            else:  # tinted: opaque grayscale, iOS applies the user's tint.
                gray = (0.0,)
                gray = over(gray, (0.70,), a_wave)
                gray = over(gray, (1.0,), a_body)
                gray = over(gray, (0.25,), a_window * a_body)
                gray = over(gray, (0.10,), a_tire)
                gray = over(gray, (0.80,), a_rim)
                gray = over(gray, (0.0,), a_bolt)
                color, a = (gray[0],) * 3, 1.0

            row += bytes(round(max(0.0, min(1.0, c)) * 255) for c in color)
            if variant == "dark":
                row.append(round(a * 255))
        rows.append(bytes(row))
        if j % 128 == 0:
            print(f"  {variant}: row {j}/{SIZE}", file=sys.stderr)
    return b"".join(rows)


def write_png(path, raw, alpha):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    # 8-bit RGBA for the transparent dark variant, RGB otherwise (App Store rejects alpha in opaque icons).
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6 if alpha else 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    variants = sys.argv[1:] or ["default", "dark", "tinted"]
    for name in variants:
        out = OUT_DIR / f"AppIcon-{name}.png"
        write_png(out, render(name), alpha=name == "dark")
        print(f"wrote {out}")
