FROM pytorch/pytorch:2.2.2-cuda11.8-cudnn8-runtime

WORKDIR /app

# Install runtime deps
RUN pip install --no-cache-dir \
    torchvision \
    pillow \
    transformers

# Copy demo scripts and datasets
COPY examples/offline_infer_demo /app/examples/offline_infer_demo
COPY datasets/offline_infer_demo /app/datasets/offline_infer_demo

ENV PYTHONUNBUFFERED=1
