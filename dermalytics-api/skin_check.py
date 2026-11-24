"""
SKIN CHECK: is this photo of skin at all?

The Dermalytics model was trained only on skin photos, so it always answers with one of
its 11 skin conditions, even for a menu or a screenshot. This check runs BEFORE the model:
it measures how much of the photo has a skin colour and refuses photos with too little.

How a pixel is judged "skin coloured" (a standard rule from image processing):
  the photo is converted to YCbCr (brightness Y + two colour channels Cb, Cr);
  human skin of every tone falls in a narrow colour band: Cr 133-180 and Cb 77-127,
  whatever its brightness (180 instead of the usual 173 so red, inflamed skin still counts);
  skin is also clearly redder than it is blue (Cr - Cb >= 22), which separates it from
  cream paper, menus and beige walls (tested: skin photos >= 23, photographed documents <= 19).
  Very dark or very bright pixels (shadows, glare, white paper) are ignored.
"""

import numpy as np
from PIL import Image

MIN_SKIN_SHARE = 0.30   # at least 30 % of the photo must look like skin


def skin_share(photo: Image.Image) -> float:
    """Share of the photo's pixels (0-1) that have a skin colour."""
    small = photo.convert("RGB").resize((160, 160))
    y, cb, cr = [np.asarray(c, dtype=np.int16) for c in small.convert("YCbCr").split()]
    skin = ((cr >= 133) & (cr <= 180) & (cb >= 77) & (cb <= 127) & (y >= 40) & (y <= 245)
            & (cr - cb >= 22))
    return float(skin.mean())


def looks_like_skin(photo: Image.Image) -> bool:
    return skin_share(photo) >= MIN_SKIN_SHARE
