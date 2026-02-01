import argparse
import json
import random
import urllib.request


def build_random_tensor(batch, channels, height, width):
    data = []
    for _ in range(batch):
        img = []
        for _ in range(channels):
            channel = [
                [random.randint(0, 255) for _ in range(width)] for _ in range(height)
            ]
            img.append(channel)
        data.append(img)
    return data


def post_json(url, payload, timeout):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description="ResNet CIFAR10 inference client")
    parser.add_argument("--url", default="http://127.0.0.1:8080/infer")
    parser.add_argument("--batch", default=1, type=int)
    parser.add_argument("--timeout", default=10, type=int)
    args = parser.parse_args()

    payload = {"tensor": build_random_tensor(args.batch, 3, 32, 32)}
    response = post_json(args.url, payload, args.timeout)
    print(response)


if __name__ == "__main__":
    main()
