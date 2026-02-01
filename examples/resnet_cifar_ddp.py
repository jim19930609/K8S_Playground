import argparse
import os
import time
import urllib.request
from datetime import timedelta

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader
from torch.utils.data.distributed import DistributedSampler
from torchvision import datasets, transforms, models


def setup_distributed():
    dist.init_process_group(backend="nccl", timeout=timedelta(minutes=30))
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    return local_rank


def main():
    parser = argparse.ArgumentParser(description="ResNet18 CIFAR10 DDP")
    parser.add_argument("--data-dir", default="/data", type=str)
    parser.add_argument("--epochs", default=1, type=int)
    parser.add_argument("--batch-size", default=128, type=int)
    parser.add_argument("--num-workers", default=2, type=int)
    parser.add_argument("--log-interval", default=10, type=int)
    parser.add_argument("--max-steps", default=50, type=int)
    args = parser.parse_args()

    local_rank = setup_distributed()
    rank = dist.get_rank()
    world_size = dist.get_world_size()

    torch.backends.cudnn.benchmark = True

    transform = transforms.Compose(
        [
            transforms.RandomCrop(32, padding=4),
            transforms.RandomHorizontalFlip(),
            transforms.ToTensor(),
            transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2023, 0.1994, 0.2010)),
        ]
    )
    use_fake = os.environ.get("USE_FAKE_DATA") == "1"
    if not use_fake:
        try:
            with urllib.request.urlopen(
                "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz", timeout=5
            ):
                pass
        except Exception:
            use_fake = True

    if use_fake:
        if rank == 0:
            print("Using FakeData for validation")
        train_set = datasets.FakeData(
            size=2048,
            image_size=(3, 32, 32),
            num_classes=10,
            transform=transform,
        )
    else:
        train_set = datasets.CIFAR10(root=args.data_dir, train=True, download=True, transform=transform)
    sampler = DistributedSampler(train_set, num_replicas=world_size, rank=rank, shuffle=True)
    loader = DataLoader(
        train_set,
        batch_size=args.batch_size,
        sampler=sampler,
        num_workers=args.num_workers,
        pin_memory=True,
    )
    dist.barrier()

    model = models.resnet18(num_classes=10).cuda(local_rank)
    model = DDP(model, device_ids=[local_rank])
    criterion = torch.nn.CrossEntropyLoss().cuda(local_rank)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)

    for epoch in range(args.epochs):
        sampler.set_epoch(epoch)
        model.train()
        start = time.time()
        for step, (images, targets) in enumerate(loader, 1):
            images = images.cuda(local_rank, non_blocking=True)
            targets = targets.cuda(local_rank, non_blocking=True)
            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, targets)
            loss.backward()
            optimizer.step()

            if step % args.log_interval == 0 and rank == 0:
                elapsed = time.time() - start
                print(
                    f"epoch={epoch} step={step} loss={loss.item():.4f} "
                    f"imgs_per_sec={args.batch_size * step / max(elapsed, 1e-6):.1f}"
                )
            if step >= args.max_steps:
                break

    if rank == 0:
        print("training completed")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
