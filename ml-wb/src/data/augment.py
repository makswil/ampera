"""Colour-temperature utilities for white-balance inference.

delta = kelvin_input - kelvin_target. Corrections are relative gain ratios
between two white points, so no absolute white point is assumed.
"""
import logging
from pathlib import Path

import numpy as np
import colour

log = logging.getLogger(__name__)

DEFAULT_INFERENCE_KELVIN: float = 5600.0

KELVIN_MIN: float = 2700.0
KELVIN_MAX: float = 8500.0
DELTA_MIN: float = KELVIN_MIN - KELVIN_MAX
DELTA_MAX: float = KELVIN_MAX - KELVIN_MIN

_LUT_SIZE: int = 1200
_LUT_K: np.ndarray | None = None
_LUT_G: np.ndarray | None = None


def _kelvin_to_rgb_gain_exact(kelvin: float) -> np.ndarray:
    def cct_to_xyz(k):
        return colour.xy_to_XYZ(colour.temperature.CCT_to_xy_Kang2002(k))

    src_rgb = colour.XYZ_to_RGB(cct_to_xyz(kelvin), "sRGB", apply_cctf_encoding=False)
    ref_rgb = colour.XYZ_to_RGB(cct_to_xyz(6504.0), "sRGB", apply_cctf_encoding=False)
    gain = ref_rgb / (src_rgb + 1e-8)
    return gain / gain[1]


def _build_lut() -> None:
    global _LUT_K, _LUT_G
    _LUT_K = np.linspace(KELVIN_MIN, KELVIN_MAX, _LUT_SIZE)
    _LUT_G = np.array([_kelvin_to_rgb_gain_exact(k) for k in _LUT_K])


def _kelvin_to_rgb_gain(kelvin: float) -> np.ndarray:
    if _LUT_K is None:
        _build_lut()
    return np.array([np.interp(kelvin, _LUT_K, _LUT_G[:, ch]) for ch in range(3)])


def load_augmentation_config(config_path: str | Path | None = None) -> dict:
    """Sync KELVIN_MIN/MAX with config.yaml so inference matches training range."""
    import yaml
    global KELVIN_MIN, KELVIN_MAX, DELTA_MIN, DELTA_MAX

    if config_path is None:
        config_path = Path(__file__).parents[2] / "configs" / "config.yaml"
    if not Path(config_path).exists():
        return {}

    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    aug = cfg.get("augmentation", {})
    KELVIN_MIN = float(aug.get("kelvin_min", KELVIN_MIN))
    KELVIN_MAX = float(aug.get("kelvin_max", KELVIN_MAX))
    DELTA_MIN = KELVIN_MIN - KELVIN_MAX
    DELTA_MAX = KELVIN_MAX - KELVIN_MIN
    _build_lut()
    return aug


def estimate_kelvin(image: np.ndarray) -> float:
    """Estimate colour temperature (K) from the brightest ~5% of pixels.

    image: float32 [0,1] HWC RGB. Falls back to DEFAULT_INFERENCE_KELVIN on failure.
    """
    brightness = image.mean(axis=2)
    mask = brightness >= np.percentile(brightness, 95)
    if mask.sum() < 10:
        log.warning("Too few bright pixels — falling back to %.0f K.", DEFAULT_INFERENCE_KELVIN)
        return DEFAULT_INFERENCE_KELVIN

    illuminant_rgb = np.clip(image[mask].mean(axis=0).astype(np.float64), 1e-6, None)
    linear_rgb = illuminant_rgb ** 2.2

    cs = colour.RGB_COLOURSPACES["sRGB"]
    xyz = np.clip(cs.matrix_RGB_to_XYZ @ linear_rgb, 1e-8, None)
    xy = colour.XYZ_to_xy(xyz)

    try:
        cct = float(colour.temperature.xy_to_CCT_Kang2002(xy))
        return float(np.clip(cct, KELVIN_MIN, KELVIN_MAX))
    except Exception as exc:
        log.warning("CCT estimation failed (%s) — falling back to %.0f K.",
                    exc, DEFAULT_INFERENCE_KELVIN)
        return DEFAULT_INFERENCE_KELVIN
