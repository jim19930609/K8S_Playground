#!/usr/bin/env python3
import argparse
import json
import sys
from io import BytesIO
from pathlib import Path

import torch
from PIL import Image
from transformers import BlipForConditionalGeneration, BlipProcessor


def load_image(path_or_url: str) -> Image.Image:
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        import urllib.request

        with urllib.request.urlopen(path_or_url) as resp:
            data = resp.read()
        return Image.open(BytesIO(data)).convert("RGB")
    return Image.open(path_or_url).convert("RGB")


def main() -> int:
    parser = argparse.ArgumentParser(description="BLIP VLM GPU captioning demo")
    parser.add_argument("--image", required=True, help="Path or URL to an image")
    parser.add_argument(
        "--prompt",
        default="a photo of",
        help="Text prompt to condition the caption",
    )
    parser.add_argument("--max-new-tokens", type=int, default=32)
    parser.add_argument("--out-caption", help="Optional path to write caption")
    args = parser.parse_args()

    if not torch.cuda.is_available():
        print("CUDA is required for this demo. No GPU detected.", file=sys.stderr)
        return 2

    device = torch.device("cuda")
    model_id = "Salesforce/blip-image-captioning-base"

    processor = BlipProcessor.from_pretrained(model_id)
    model = BlipForConditionalGeneration.from_pretrained(
        model_id,
        torch_dtype=torch.float16,
    ).to(device)
    model.eval()

    image = load_image(args.image)
    inputs = processor(images=image, text=args.prompt, return_tensors="pt").to(device)

    with torch.inference_mode():
        output_ids = model.generate(
            **inputs,
            max_new_tokens=args.max_new_tokens,
        )

    caption = processor.decode(output_ids[0], skip_special_tokens=True)
    output = json.dumps({"prompt": args.prompt, "caption": caption}, indent=2)
    print(output)
    if args.out_caption:
        Path(args.out_caption).write_text(caption)
    return 0


if __name__ == "__main__":
    sys.exit(main())
