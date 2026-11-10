"""Real-ESRGAN(xinntao, BSD-3) 애니 모델 두 개를 도트메이커용 ONNX로 바꾼다.

입력 image [1,3,H,W] (0~1 RGB) → 출력 upscaled [1,3,4H,4W].
필요: torch, onnx  /  사용: python3 scripts/export-esrgan.py vendor/models
"""
import sys
import urllib.request
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F

RELEASES = "https://github.com/xinntao/Real-ESRGAN/releases/download"


class RDB(nn.Module):
    def __init__(self, f=64, g=32):
        super().__init__()
        self.conv1 = nn.Conv2d(f, g, 3, 1, 1)
        self.conv2 = nn.Conv2d(f + g, g, 3, 1, 1)
        self.conv3 = nn.Conv2d(f + 2 * g, g, 3, 1, 1)
        self.conv4 = nn.Conv2d(f + 3 * g, g, 3, 1, 1)
        self.conv5 = nn.Conv2d(f + 4 * g, f, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        return self.conv5(torch.cat((x, x1, x2, x3, x4), 1)) * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, f=64):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = RDB(f), RDB(f), RDB(f)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, blocks=6, f=64):
        super().__init__()
        self.conv_first = nn.Conv2d(3, f, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(f) for _ in range(blocks)])
        self.conv_body = nn.Conv2d(f, f, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(f, f, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(f, f, 3, 1, 1)
        self.conv_hr = nn.Conv2d(f, f, 3, 1, 1)
        self.conv_last = nn.Conv2d(f, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class SRVGGNetCompact(nn.Module):
    def __init__(self, f=64, convs=16, scale=4):
        super().__init__()
        layers = [nn.Conv2d(3, f, 3, 1, 1), nn.PReLU(num_parameters=f)]
        for _ in range(convs):
            layers += [nn.Conv2d(f, f, 3, 1, 1), nn.PReLU(num_parameters=f)]
        layers.append(nn.Conv2d(f, 3 * scale * scale, 3, 1, 1))
        self.body = nn.ModuleList(layers)
        self.up = nn.PixelShuffle(scale)
        self.scale = scale

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return self.up(out) + F.interpolate(x, scale_factor=self.scale, mode="nearest")


MODELS = [
    ("esrgan-anime-6b.onnx", RRDBNet, "v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth"),
    ("esrgan-animevideo-v3.onnx", SRVGGNetCompact, "v0.2.5.0/realesr-animevideov3.pth"),
]

if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "vendor/models")
    out.mkdir(parents=True, exist_ok=True)
    for name, arch, release in MODELS:
        weights = out / Path(release).name
        if not weights.exists():
            urllib.request.urlretrieve(f"{RELEASES}/{release}", weights)
        state = torch.load(weights, map_location="cpu", weights_only=True)
        net = arch()
        net.load_state_dict(state.get("params_ema", state.get("params", state)))
        net.eval()
        torch.onnx.export(net, torch.rand(1, 3, 64, 48), out / name, input_names=["image"], output_names=["upscaled"],
                          opset_version=17, dynamic_axes={"image": {2: "h", 3: "w"}, "upscaled": {2: "h4", 3: "w4"}},
                          dynamo=False)
        weights.unlink()
        print("만듦:", out / name)
