"""OpenTTD DOS palette helpers shared by the sprite tools.

The palette itself comes from the installed `nml` package, so the 8bpp sprites we
write are guaranteed to match what nmlc expects.
"""
from __future__ import annotations

import numpy as np
from nml import palette as _nml_palette

# 256 x 3 uint8, DOS ("DEFAULT") palette.
DOS: np.ndarray = np.frombuffer(bytes(_nml_palette.palette_data[0]), dtype=np.uint8).reshape(256, 3).copy()
DOS_FLAT: list[int] = DOS.flatten().tolist()  # for PIL.Image.putpalette

TRANSPARENT = 0
CC1 = list(range(0xC6, 0xCE))  # first company colour, 8 shades dark -> light
CC2 = list(range(0x50, 0x58))  # second company colour, 8 shades dark -> light
CC1_MASK_INDEX = 0xCA          # mid shade used in 32bpp masks; brightness comes from the RGB pixel
CC2_MASK_INDEX = 0x54

# Indices that ordinary (non-recoloured) pixels must never use: transparent, company
# colours, and the animated / special range at the top of the palette.
_RESERVED = set([TRANSPARENT]) | set(CC1) | set(CC2) | set(range(0xE3, 0x100))
ALLOWED: np.ndarray = np.array([i for i in range(256) if i not in _RESERVED], dtype=np.int32)
_ALLOWED_RGB = DOS[ALLOWED].astype(np.int32)


def nearest_allowed(rgb: np.ndarray) -> np.ndarray:
    """Map an (N, 3) uint8 array to the nearest allowed palette index (N,)."""
    px = rgb.astype(np.int32)
    # Squared euclidean distance in RGB; N x M is small for sprite sheets.
    d = ((px[:, None, :] - _ALLOWED_RGB[None, :, :]) ** 2).sum(axis=2)
    return ALLOWED[d.argmin(axis=1)]


def cc_shade_index(brightness: np.ndarray, base: list[int], lo: int = 64, hi: int = 224) -> np.ndarray:
    """Pick a company-colour shade (8 steps) from a 0..255 brightness array."""
    t = np.clip((brightness.astype(np.float32) - lo) / float(hi - lo), 0.0, 1.0)
    idx = np.rint(t * (len(base) - 1)).astype(np.int32)
    return np.array(base, dtype=np.int32)[idx]


def quantize_8bpp(rgba: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Convert a 32bpp RGBA image (H, W, 4) plus a mask (H, W: 0 / CC1_MASK_INDEX / CC2_MASK_INDEX)
    into an 8bpp DOS-palette index image (H, W).
    """
    h, w, _ = rgba.shape
    out = np.zeros((h, w), dtype=np.uint8)
    alpha = rgba[..., 3]
    opaque = alpha >= 128
    brightness = rgba[..., :3].max(axis=2)

    cc1 = opaque & (mask == CC1_MASK_INDEX)
    cc2 = opaque & (mask == CC2_MASK_INDEX)
    plain = opaque & ~cc1 & ~cc2

    if cc1.any():
        out[cc1] = cc_shade_index(brightness[cc1], CC1)
    if cc2.any():
        out[cc2] = cc_shade_index(brightness[cc2], CC2)
    if plain.any():
        out[plain] = nearest_allowed(rgba[..., :3][plain])
    return out
