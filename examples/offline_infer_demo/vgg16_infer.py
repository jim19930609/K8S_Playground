#!/usr/bin/env python3
import argparse
import json
import sys
from io import BytesIO
from pathlib import Path

import torch
from PIL import Image
from torchvision import models


def load_image(path_or_url: str) -> Image.Image:
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        import urllib.request

        with urllib.request.urlopen(path_or_url) as resp:
            data = resp.read()
        return Image.open(BytesIO(data)).convert("RGB")
    return Image.open(path_or_url).convert("RGB")


def main() -> int:
    parser = argparse.ArgumentParser(description="VGG-16 GPU image classification demo")
    parser.add_argument("--image", required=True, help="Path or URL to an image")
    parser.add_argument("--topk", type=int, default=5, help="Top-K predictions")
    parser.add_argument("--out-json", help="Optional path to write JSON output")
    parser.add_argument("--out-top1", help="Optional path to write top1 label")
    args = parser.parse_args()

    if not torch.cuda.is_available():
        print("CUDA is required for this demo. No GPU detected.", file=sys.stderr)
        return 2

    device = torch.device("cuda")
    weights = models.VGG16_Weights.IMAGENET1K_V1
    model = models.vgg16(weights=weights).to(device)
    model.eval()

    preprocess = weights.transforms()

    image = load_image(args.image)
    input_tensor = preprocess(image).unsqueeze(0).to(device)

    with torch.inference_mode():
        logits = model(input_tensor)
        probs = torch.softmax(logits, dim=1)
        topk = min(args.topk, probs.shape[1])
        values, indices = torch.topk(probs, k=topk, dim=1)

    labels = weights.meta["categories"]
    results = []
    for score, idx in zip(values[0].tolist(), indices[0].tolist()):
        results.append({"label": labels[idx], "score": float(score)})

    output = json.dumps({"topk": results}, indent=2)
    print(output)
    if args.out_json:
        Path(args.out_json).write_text(output)
    if args.out_top1:
        Path(args.out_top1).write_text(results[0]["label"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
