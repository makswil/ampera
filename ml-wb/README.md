# ml-wb

White-balance color normalization. Run an input image through this model for
color balancing before feeding it into the main pipeline.

## Install

```bash
pip install -r ml-wb/requirements.txt \
  --index-url https://download.pytorch.org/whl/cpu   # CPU-only torch
```

## Use (direct function call)

```python
from ml_wb.src.infer import load_model, correct_array
import numpy as np
from PIL import Image

model, device, image_size = load_model()   # uses checkpoints/model.pt + configs/config.yaml

img = np.asarray(Image.open("photo.jpg").convert("RGB"), dtype=np.float32) / 255.0
corrected = correct_array(img, model, device, image_size)   # float32 [0,1] HWC RGB
# optional: correct toward a specific target, e.g. correct_array(img, ..., target_kelvin=5600)
```

`load_model()` once, then call `correct_array` per image. Default target is
5600 K (neutral daylight). `correct_file(path, model, device, image_size, reference_path=...)`
loads from disk and can match a reference image's white balance.

## CLI (optional)

```bash
python -m src.infer --input photo.jpg --out-dir output/
```

## Layout

```
ml-wb/
├── README.md
├── requirements.txt
├── configs/config.yaml
├── checkpoints/model.pt
└── src/
    ├── infer.py          # load_model, correct_array, correct_file
    ├── utils.py
    ├── model/unet.py
    └── data/augment.py
```
