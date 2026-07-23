#!/usr/bin/env python3
"""Batch white-balance correction bridge for the Dart bake tool.

Wraps the (untouched) `ml-wb` PyTorch model: loads it ONCE, corrects a list of
input images toward a common target white point, and writes the results as PNG.
Prints a JSON `{input_path: output_path}` map to stdout so the caller can pick up
the corrected files. All diagnostics go to stderr.

This lives in `flutter_face_scan/tool/` and imports `ml-wb` via `sys.path` only —
the `ml-wb/` folder itself is never modified.

Usage (see `tool/bake_texture.dart --ml-wb`):
    python ml_wb_correct.py --out-dir <dir> [--ml-wb-root <path>] \
        [--target-kelvin 5600 | --reference <img>] img1 img2 ...

Target modes (all poses are normalised to the SAME white point → consistent
colour across poses, which is the point of running it before baking):
  * default            → neutral daylight (ml-wb's DEFAULT_INFERENCE_KELVIN, 5600 K).
  * --target-kelvin K  → correct every image toward K.
  * --reference <img>  → correct every image toward the reference image's
                          estimated colour temperature (e.g. the frontal still).
"""
import argparse
import json
import sys
from pathlib import Path


def _resolve_ml_wb_root(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).expanduser().resolve()
    else:
        # tool/ -> flutter_face_scan/ -> <repo>/ , sibling `ml-wb`.
        root = Path(__file__).resolve().parents[2] / "ml-wb"
    if not (root / "src" / "infer.py").exists():
        raise SystemExit(
            f"[ml_wb_correct] ml-wb not found at '{root}'. Pass --ml-wb-root."
        )
    return root


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Batch ml-wb white-balance correction")
    parser.add_argument("inputs", nargs="+", help="Input image paths")
    parser.add_argument("--out-dir", required=True, help="Directory for corrected PNGs")
    parser.add_argument("--ml-wb-root", default=None, help="Path to the ml-wb folder")
    parser.add_argument("--target-kelvin", type=float, default=None,
                        help="Correct all images toward this Kelvin (default: ml-wb neutral)")
    parser.add_argument("--reference", default=None,
                        help="Correct all images toward this reference image's white balance")
    args = parser.parse_args(argv)

    ml_wb_root = _resolve_ml_wb_root(args.ml_wb_root)
    if str(ml_wb_root) not in sys.path:
        sys.path.insert(0, str(ml_wb_root))

    # Imported here (after sys.path is set) so a missing ml-wb gives a clean error.
    import numpy as np  # noqa: E402
    from PIL import Image  # noqa: E402
    from src.infer import load_model, correct_array, load_image  # noqa: E402
    from src.data.augment import estimate_kelvin  # noqa: E402

    model, device, image_size = load_model()

    # A single shared target for every pose → uniform white balance across them.
    target_kelvin = args.target_kelvin
    if args.reference:
        target_kelvin = float(estimate_kelvin(load_image(Path(args.reference))))
        print(f"[ml_wb_correct] reference white balance ~= {target_kelvin:.0f} K",
              file=sys.stderr)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    mapping: dict[str, str] = {}
    for raw in args.inputs:
        in_path = Path(raw)
        image = np.asarray(Image.open(in_path).convert("RGB"), dtype=np.float32) / 255.0
        corrected = correct_array(image, model, device, image_size, target_kelvin)
        out_path = out_dir / f"{in_path.stem}_wb.png"
        Image.fromarray((np.clip(corrected, 0, 1) * 255).astype(np.uint8)).save(out_path)
        mapping[str(in_path)] = str(out_path)
        print(f"[ml_wb_correct] {in_path.name} -> {out_path.name}", file=sys.stderr)

    # Machine-readable result for the Dart caller (stdout only).
    print(json.dumps(mapping))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
