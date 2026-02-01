import argparse
import base64
import io
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
from torchvision import models, transforms

CIFAR10_CLASSES = [
    "airplane",
    "automobile",
    "bird",
    "cat",
    "deer",
    "dog",
    "frog",
    "horse",
    "ship",
    "truck",
]


def _maybe_load_image(b64_str):
    try:
        from PIL import Image
    except Exception:
        return None, "PIL not available; send 'tensor' instead of 'image_b64'."

    try:
        raw = base64.b64decode(b64_str)
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        return img, None
    except Exception as exc:
        return None, f"Failed to decode image_b64: {exc}"


def _tensor_from_list(data):
    tensor = torch.tensor(data)
    if tensor.ndim == 3:
        tensor = tensor.unsqueeze(0)
    return tensor


def _normalize_tensor(tensor):
    if tensor.dtype != torch.float32:
        tensor = tensor.float()
    max_val = float(tensor.max().item()) if tensor.numel() else 1.0
    if max_val > 1.5:
        tensor = tensor / 255.0
    mean = torch.tensor([0.4914, 0.4822, 0.4465], device=tensor.device).view(1, 3, 1, 1)
    std = torch.tensor([0.2023, 0.1994, 0.2010], device=tensor.device).view(1, 3, 1, 1)
    return (tensor - mean) / std


def _burn_cpu(ms):
    if ms <= 0:
        return
    end = time.perf_counter() + (ms / 1000.0)
    x = 0.0
    while time.perf_counter() < end:
        x = (x + 1.618) % 3.14159
    return x


def load_model(args, device):
    if args.torchscript:
        model = torch.jit.load(args.model_path, map_location=device)
        model.eval()
        return model

    model = models.resnet18(num_classes=args.num_classes)
    if args.model_path:
        checkpoint = torch.load(args.model_path, map_location="cpu")
        if isinstance(checkpoint, dict):
            if "state_dict" in checkpoint:
                checkpoint = checkpoint["state_dict"]
            elif "model" in checkpoint:
                checkpoint = checkpoint["model"]
        model.load_state_dict(checkpoint)
    model.eval()
    model.to(device)
    return model


def build_transform(input_size):
    return transforms.Compose(
        [
            transforms.Resize((input_size, input_size)),
            transforms.ToTensor(),
        ]
    )


class InferenceHandler(BaseHTTPRequestHandler):
    server_version = "resnet-cifar-infer/1.0"

    def _send_json(self, payload, status=200):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(
                {
                    "status": "ok",
                    "device": str(self.server.device),
                    "model_path": self.server.model_path or "",
                    "torchscript": self.server.torchscript,
                }
            )
            return
        self._send_json({"error": "not found"}, status=404)

    def do_POST(self):
        if self.path != "/infer":
            self._send_json({"error": "not found"}, status=404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            payload = json.loads(body.decode("utf-8"))
        except Exception as exc:
            self._send_json({"error": f"invalid json: {exc}"}, status=400)
            return

        if "tensor" in payload:
            try:
                tensor = _tensor_from_list(payload["tensor"])
            except Exception as exc:
                self._send_json({"error": f"invalid tensor: {exc}"}, status=400)
                return
        elif "inputs" in payload:
            try:
                tensor = torch.stack([_tensor_from_list(x).squeeze(0) for x in payload["inputs"]], dim=0)
            except Exception as exc:
                self._send_json({"error": f"invalid inputs: {exc}"}, status=400)
                return
        elif "image_b64" in payload:
            img, err = _maybe_load_image(payload["image_b64"])
            if err:
                self._send_json({"error": err}, status=400)
                return
            tensor = self.server.transform(img).unsqueeze(0)
        else:
            self._send_json({"error": "provide 'tensor', 'inputs', or 'image_b64'."}, status=400)
            return

        if tensor.ndim != 4 or tensor.shape[1] != 3:
            self._send_json({"error": f"expected NCHW with 3 channels, got {list(tensor.shape)}"}, status=400)
            return

        tensor = tensor.to(self.server.device, non_blocking=True)
        tensor = _normalize_tensor(tensor)
        _burn_cpu(self.server.cpu_burn_ms)
        with torch.no_grad():
            logits = self.server.model(tensor)
            probs = torch.softmax(logits, dim=-1)
            top_prob, top_idx = torch.max(probs, dim=-1)

        top_idx = top_idx.cpu().tolist()
        top_prob = top_prob.cpu().tolist()
        if self.server.class_names:
            top_label = [self.server.class_names[i] if i < len(self.server.class_names) else str(i) for i in top_idx]
        else:
            top_label = [str(i) for i in top_idx]

        response = {
            "batch": tensor.shape[0],
            "top1_index": top_idx,
            "top1_label": top_label,
            "top1_prob": top_prob,
        }
        self._send_json(response, status=200)


def main():
    parser = argparse.ArgumentParser(description="ResNet CIFAR10 Inference HTTP server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", default=8080, type=int)
    parser.add_argument("--model-path", default=os.environ.get("MODEL_PATH", ""))
    parser.add_argument("--torchscript", action="store_true")
    parser.add_argument("--num-classes", default=10, type=int)
    parser.add_argument("--input-size", default=32, type=int)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--no-class-names", action="store_true")
    parser.add_argument("--cpu-burn-ms", default=int(os.environ.get("CPU_BURN_MS", "0")), type=int)
    args = parser.parse_args()

    torch.backends.cudnn.benchmark = True
    device = torch.device(args.device)
    model = load_model(args, device)
    transform = build_transform(args.input_size)

    server = ThreadingHTTPServer((args.host, args.port), InferenceHandler)
    server.model = model
    server.device = device
    server.transform = transform
    server.model_path = args.model_path
    server.torchscript = bool(args.torchscript)
    server.class_names = [] if args.no_class_names else CIFAR10_CLASSES
    server.cpu_burn_ms = max(args.cpu_burn_ms, 0)

    print(f"serving on http://{args.host}:{args.port} device={device}")
    server.serve_forever()


if __name__ == "__main__":
    main()
