#!/usr/bin/env python3
"""Export the (untouched) ml-wb U-Net+FiLM checkpoint to CoreML.

Writes ios/Runner/Models/MLWhiteBalance.mlpackage for on-device inference.
ml-wb/ is imported read-only via sys.path.

Usage:
    tool/.venv-mlwb/bin/python tool/export_ml_wb_coreml.py
"""
from __future__ import annotations

import sys
from pathlib import Path

_TOOL = Path(__file__).resolve().parent
_FLUTTER = _TOOL.parent
_REPO = _FLUTTER.parent
_ML_WB = _REPO / "ml-wb"
_OUT = _FLUTTER / "ios" / "Runner" / "Models" / "MLWhiteBalance.mlpackage"

if str(_ML_WB) not in sys.path:
    sys.path.insert(0, str(_ML_WB))


def main() -> int:
    import coremltools as ct
    import numpy as np
    import torch
    import torch.nn as nn

    from src.infer import load_model

    model, _device, image_size = load_model()
    model = model.cpu().eval()

    # CoreML prefers a single forward(image, delta) with fixed shapes.
    class ExportWrapper(nn.Module):
        def __init__(self, net: nn.Module):
            super().__init__()
            self.net = net

        def forward(self, image: torch.Tensor, delta: torch.Tensor) -> torch.Tensor:
            # image: (1,3,H,W) float32 [0,1]; delta: (1,) float32
            return self.net(image, delta)

    wrapped = ExportWrapper(model)
    example_image = torch.zeros(1, 3, image_size, image_size, dtype=torch.float32)
    example_delta = torch.zeros(1, dtype=torch.float32)

    traced = torch.jit.trace(wrapped, (example_image, example_delta))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image", shape=example_image.shape, dtype=np.float32),
            ct.TensorType(name="delta", shape=example_delta.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="corrected", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
    )
    mlmodel.author = "flutter_face_scan"
    mlmodel.short_description = (
        "ml-wb Kelvin-conditioned U-Net white-balance (256px). "
        "Apply gain ratio to full-res image on device."
    )
    mlmodel.user_defined_metadata["image_size"] = str(image_size)
    mlmodel.user_defined_metadata["default_kelvin"] = "5600"
    mlmodel.user_defined_metadata["delta_min"] = "-5800"
    mlmodel.user_defined_metadata["delta_max"] = "5800"

    _OUT.parent.mkdir(parents=True, exist_ok=True)
    if _OUT.exists():
        import shutil
        shutil.rmtree(_OUT)
    mlmodel.save(str(_OUT))
    print(f"Wrote {_OUT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
