"""White-balance correction inference.

Direct use:
    from src.infer import load_model, correct_array
    model, device, image_size = load_model()
    corrected = correct_array(rgb_float01, model, device, image_size)

Pipeline:
    1. Estimate colour temperature of input (and reference, else 5600 K).
    2. delta = k_input - k_target.
    3. model(input@256px, delta) -> correction.
    4. Upsample per-pixel gain ratio to original resolution and apply.
"""
import argparse
import logging
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import yaml
import numpy as np
import torch
from PIL import Image, UnidentifiedImageError

import src.data.augment as augment
from src.data.augment import estimate_kelvin
from src.model.unet import build_model
from src.utils import WBError, get_device, setup_logging

log = logging.getLogger(__name__)

_DEFAULT_CHECKPOINT = _ROOT / "checkpoints" / "model.pt"
_DEFAULT_CONFIG = _ROOT / "configs" / "config.yaml"


def load_image(path: Path) -> np.ndarray:
    """Load an image file as float32 [0,1] HWC RGB."""
    try:
        img = Image.open(path).convert("RGB")
        return np.array(img, dtype=np.float32) / 255.0
    except FileNotFoundError:
        raise WBError(f"Image file not found: {path}")
    except UnidentifiedImageError:
        raise WBError(f"Cannot read image: {path}. Expected JPEG, PNG, TIFF, or WebP.")
    except Exception as exc:
        raise WBError(f"Failed to load image '{path}': {exc}") from exc


def save_image(array: np.ndarray, path: Path) -> None:
    """Save a float32 [0,1] array as PNG."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray((np.clip(array, 0, 1) * 255).astype(np.uint8)).save(path)
    except OSError as exc:
        raise WBError(f"Could not write output image '{path}': {exc}") from exc


def load_model(
    checkpoint: str | Path = _DEFAULT_CHECKPOINT,
    config: str | Path = _DEFAULT_CONFIG,
) -> tuple[torch.nn.Module, torch.device, int]:
    """Build the model, load weights, sync the Kelvin range. Returns (model, device, image_size)."""
    checkpoint, config = Path(checkpoint), Path(config)
    if not checkpoint.exists():
        raise WBError(f"Checkpoint not found: {checkpoint}")
    if not config.exists():
        raise WBError(f"Config file not found: {config}")

    with open(config) as f:
        cfg = yaml.safe_load(f)

    augment.load_augmentation_config(config)
    device = get_device(cfg.get("device", "auto"))
    image_size = cfg["data"]["image_size"]

    model = build_model(cfg).to(device)
    try:
        ckpt = torch.load(checkpoint, map_location=device, weights_only=True)
        model.load_state_dict(ckpt["model"])
    except Exception as exc:
        raise WBError(f"Could not load checkpoint '{checkpoint}': {exc}. "
                      "Check that base_channels in config.yaml matches the checkpoint.") from exc
    model.eval()
    return model, device, image_size


def correct_array(
    image: np.ndarray,
    model: torch.nn.Module,
    device: torch.device,
    image_size: int = 256,
    target_kelvin: float | None = None,
) -> np.ndarray:
    """Correct a float32 [0,1] HWC RGB image. target_kelvin defaults to 5600 K."""
    k_input = estimate_kelvin(image)
    k_ref = augment.DEFAULT_INFERENCE_KELVIN if target_kelvin is None else float(target_kelvin)
    delta = float(np.clip(k_input - k_ref, augment.DELTA_MIN, augment.DELTA_MAX))

    orig_t = torch.from_numpy(image.transpose(2, 0, 1)).unsqueeze(0)
    input_resized = torch.nn.functional.interpolate(
        orig_t, size=(image_size, image_size), mode="bilinear", align_corners=False,
    ).squeeze(0).numpy().transpose(1, 2, 0)

    delta_tensor = torch.tensor([delta], dtype=torch.float32).to(device)
    inp_tensor = torch.from_numpy(input_resized.transpose(2, 0, 1)).float().unsqueeze(0).to(device)
    try:
        with torch.no_grad():
            out_tensor = model(inp_tensor, delta_tensor)
    except RuntimeError as exc:
        raise WBError(f"Model inference failed: {exc}") from exc
    out_resized = out_tensor.squeeze(0).cpu().numpy().transpose(1, 2, 0)

    h, w = image.shape[:2]
    ratio = np.clip(out_resized / (input_resized + 1e-6), 0.1, 4.0)
    ratio_t = torch.from_numpy(ratio.transpose(2, 0, 1)).unsqueeze(0)
    ratio_full = torch.nn.functional.interpolate(
        ratio_t, size=(h, w), mode="bilinear", align_corners=False,
    ).squeeze(0).numpy().transpose(1, 2, 0)

    return np.clip(image * ratio_full, 0, 1).astype(np.float32)


def correct_file(
    input_path: str | Path,
    model: torch.nn.Module,
    device: torch.device,
    image_size: int = 256,
    reference_path: str | Path | None = None,
) -> np.ndarray:
    """Load an image file, correct it, and return the result array."""
    image = load_image(Path(input_path))
    target = estimate_kelvin(load_image(Path(reference_path))) if reference_path else None
    return correct_array(image, model, device, image_size, target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="White-balance correction (Kelvin-conditioned U-Net)")
    parser.add_argument("--input", required=True, help="Input image path")
    parser.add_argument("--reference", default=None, help="Reference image (target white balance)")
    parser.add_argument("--checkpoint", default=str(_DEFAULT_CHECKPOINT), help="Model checkpoint (.pt)")
    parser.add_argument("--config", default=str(_DEFAULT_CONFIG), help="Config file")
    parser.add_argument("--out-dir", default="output", help="Output directory")
    parser.add_argument("--verbose", action="store_true", help="Verbose logging")
    args = parser.parse_args()

    setup_logging(verbose=args.verbose)
    try:
        model, device, image_size = load_model(args.checkpoint, args.config)
        output = correct_file(args.input, model, device, image_size, args.reference)
        out_path = Path(args.out_dir) / f"{Path(args.input).stem}_corrected.png"
        save_image(output, out_path)
        print(out_path)
    except WBError as exc:
        print(exc, file=sys.stderr)
        sys.exit(exc.exit_code)
    except KeyboardInterrupt:
        sys.exit(130)
