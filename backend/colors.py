"""Small color helpers shared by the providers (hex / RGB / CIE xy / HSV / kelvin)."""
import colorsys
import math


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) != 6:
        raise ValueError(f"bad color {h!r}, expected #rrggbb")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def rgb_to_hex(r: float, g: float, b: float) -> str:
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(c))) for c in (r, g, b))


def rgb_to_xy(r: int, g: int, b: int) -> tuple[float, float]:
    def lin(c: float) -> float:
        c /= 255
        return ((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92

    r_, g_, b_ = lin(r), lin(g), lin(b)
    x = r_ * 0.4124 + g_ * 0.3576 + b_ * 0.1805
    y = r_ * 0.2126 + g_ * 0.7152 + b_ * 0.0722
    z = r_ * 0.0193 + g_ * 0.1192 + b_ * 0.9505
    s = x + y + z
    if s == 0:
        return (0.3227, 0.3290)
    return (round(x / s, 4), round(y / s, 4))


def xy_to_hex(x: float, y: float) -> str:
    """Full-brightness sRGB color for a CIE xy point (used only for UI tinting)."""
    if y <= 0:
        return "#ffffff"
    Y = 1.0
    X = (Y / y) * x
    Z = (Y / y) * (1 - x - y)
    rgb = [
        X * 3.2406 - Y * 1.5372 - Z * 0.4986,
        -X * 0.9689 + Y * 1.8758 + Z * 0.0415,
        X * 0.0557 - Y * 0.2040 + Z * 1.0570,
    ]
    rgb = [max(0.0, c) for c in rgb]
    m = max(rgb) or 1.0
    rgb = [c / m for c in rgb]
    rgb = [1.055 * c ** (1 / 2.4) - 0.055 if c > 0.0031308 else 12.92 * c for c in rgb]
    return rgb_to_hex(*(c * 255 for c in rgb))


def hex_to_hsv(h: str) -> tuple[int, int, int]:
    """Returns (hue 0-360, sat 0-100, value 0-100)."""
    r, g, b = hex_to_rgb(h)
    hh, ss, vv = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    return round(hh * 360) % 360, round(ss * 100), round(vv * 100)


def hsv_to_hex(h: float, s: float, v: float = 100) -> str:
    r, g, b = colorsys.hsv_to_rgb((h % 360) / 360, s / 100, v / 100)
    return rgb_to_hex(r * 255, g * 255, b * 255)


def kelvin_to_hex(k: float) -> str:
    """Approximate color of a black body at k kelvin (Tanner Helland)."""
    t = max(1000, min(40000, k)) / 100
    r = 255 if t <= 66 else 329.698727446 * ((t - 60) ** -0.1332047592)
    g = 99.4708025861 * math.log(t) - 161.1195681661 if t <= 66 else 288.1221695283 * ((t - 60) ** -0.0755148492)
    b = 255 if t >= 66 else (0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307)
    return rgb_to_hex(r, g, b)
