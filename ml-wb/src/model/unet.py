"""U-Net with Kelvin FiLM conditioning for white-balance correction.

delta = kelvin_input - kelvin_target, fed through a small MLP to produce
(gamma, beta) that modulate the bottleneck features.
"""
import logging
import torch
import torch.nn as nn

from src.data.augment import DELTA_MIN, DELTA_MAX

log = logging.getLogger(__name__)


class ConvBlock(nn.Module):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(in_ch,  out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.block(x)


class Down(nn.Module):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__()
        self.pool = nn.MaxPool2d(2)
        self.conv = ConvBlock(in_ch, out_ch)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.conv(self.pool(x))


class Up(nn.Module):
    def __init__(self, in_ch: int, skip_ch: int, out_ch: int):
        super().__init__()
        self.up   = nn.Upsample(scale_factor=2, mode="bilinear", align_corners=False)
        self.conv = ConvBlock(in_ch + skip_ch, out_ch)

    def forward(self, x: torch.Tensor, skip: torch.Tensor) -> torch.Tensor:
        return self.conv(torch.cat([self.up(x), skip], dim=1))


class KelvinFiLM(nn.Module):
    def __init__(self, channels: int, delta_min: float, delta_max: float):
        super().__init__()
        self.delta_min = delta_min
        self.delta_max = delta_max
        self.mlp = nn.Sequential(
            nn.Linear(1, 64),
            nn.ReLU(),
            nn.Linear(64, channels * 2),
        )

    def forward(self, features: torch.Tensor, delta: torch.Tensor) -> torch.Tensor:
        k = (delta - self.delta_min) / (self.delta_max - self.delta_min)
        k = (k * 2.0 - 1.0).float().view(-1, 1)
        gamma, beta = self.mlp(k).chunk(2, dim=1)
        gamma = gamma.unsqueeze(2).unsqueeze(3)
        beta  = beta.unsqueeze(2).unsqueeze(3)
        return features * (1.0 + gamma) + beta


class UNet(nn.Module):
    """forward(x, delta): x (B,3,H,W) in [0,1], delta (B,) -> corrected (B,3,H,W)."""
    def __init__(
        self,
        base_channels: int = 16,
        delta_min: float = DELTA_MIN,
        delta_max: float = DELTA_MAX,
    ):
        super().__init__()
        b = base_channels

        self.enc1 = ConvBlock(3,    b)
        self.enc2 = Down(b,         b * 2)
        self.enc3 = Down(b * 2,     b * 4)
        self.enc4 = Down(b * 4,     b * 8)

        self.bottleneck = Down(b * 8,  b * 16)
        self.film       = KelvinFiLM(b * 16, delta_min, delta_max)

        self.dec4 = Up(b * 16, b * 8,  b * 8)
        self.dec3 = Up(b * 8,  b * 4,  b * 4)
        self.dec2 = Up(b * 4,  b * 2,  b * 2)
        self.dec1 = Up(b * 2,  b,      b)

        self.out     = nn.Conv2d(b, 3, 1)
        self.sigmoid = nn.Sigmoid()

    def forward(self, x: torch.Tensor, delta: torch.Tensor) -> torch.Tensor:
        s1 = self.enc1(x)
        s2 = self.enc2(s1)
        s3 = self.enc3(s2)
        s4 = self.enc4(s3)

        x = self.film(self.bottleneck(s4), delta)

        x = self.dec4(x, s4)
        x = self.dec3(x, s3)
        x = self.dec2(x, s2)
        x = self.dec1(x, s1)

        return self.sigmoid(self.out(x))


def build_model(config: dict) -> UNet:
    base_ch = config["model"].get("base_channels", 16)
    model = UNet(base_channels=base_ch)
    log.debug("U-Net+FiLM base_channels=%d params=%d", base_ch,
              sum(p.numel() for p in model.parameters()))
    return model
