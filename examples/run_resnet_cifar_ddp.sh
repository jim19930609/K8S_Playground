#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"
MASTER_PORT="${MASTER_PORT:-29500}"
NNODES="${NNODES:-1}"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
NODE_RANK="${NODE_RANK:-}"
POD_IP="${POD_IP:-}"
POD_NAME="${POD_NAME:-}"
DATA_DIR="${DATA_DIR:-/tmp/cifar-data}"
EPOCHS="${EPOCHS:-1}"
MAX_STEPS="${MAX_STEPS:-50}"
BATCH_SIZE="${BATCH_SIZE:-128}"
NUM_WORKERS="${NUM_WORKERS:-2}"
LOG_INTERVAL="${LOG_INTERVAL:-10}"

if [[ -z "${NODE_RANK}" ]]; then
  if [[ -n "${POD_NAME}" && "${POD_NAME}" =~ -([0-9]+)$ ]]; then
    NODE_RANK="${BASH_REMATCH[1]}"
  elif [[ "${HOSTNAME}" =~ -([0-9]+)$ ]]; then
    NODE_RANK="${BASH_REMATCH[1]}"
  else
    NODE_RANK="0"
  fi
fi

if [[ "${NODE_RANK}" == "0" && -n "${POD_IP}" ]]; then
  MASTER_ADDR="${POD_IP}"
fi

if [[ "${MASTER_ADDR}" =~ [A-Za-z] ]]; then
  for _ in $(seq 1 30); do
    if command -v getent >/dev/null 2>&1; then
      RESOLVED_ADDR="$(getent ahostsv4 "${MASTER_ADDR}" | awk '{print $1}' | head -n1 || true)"
    else
      RESOLVED_ADDR="$(python - <<'PY' 2>/dev/null || true
import os
import socket
try:
    print(socket.gethostbyname(os.environ.get("MASTER_ADDR", "")))
except Exception:
    pass
PY
)"
    fi
    if [[ -n "${RESOLVED_ADDR}" ]]; then
      MASTER_ADDR="${RESOLVED_ADDR}"
      break
    fi
    sleep 1
  done
fi

echo "MASTER_ADDR=${MASTER_ADDR} NODE_RANK=${NODE_RANK} NNODES=${NNODES} GPUS_PER_NODE=${GPUS_PER_NODE}"

python - <<'PY' || pip install --no-cache-dir torchvision
import importlib.util
if importlib.util.find_spec("torchvision") is None:
    raise SystemExit(1)
PY

if [[ "${NNODES}" == "1" ]]; then
  torchrun \
    --standalone \
    --nproc_per_node="${GPUS_PER_NODE}" \
    "${SCRIPT_DIR}/resnet_cifar_ddp.py" \
    --data-dir "${DATA_DIR}" \
    --epochs "${EPOCHS}" \
    --max-steps "${MAX_STEPS}" \
    --batch-size "${BATCH_SIZE}" \
    --num-workers "${NUM_WORKERS}" \
    --log-interval "${LOG_INTERVAL}"
else
  torchrun \
    --nnodes="${NNODES}" \
    --nproc_per_node="${GPUS_PER_NODE}" \
    --node_rank="${NODE_RANK}" \
    --master_addr="${MASTER_ADDR}" \
    --master_port="${MASTER_PORT}" \
    "${SCRIPT_DIR}/resnet_cifar_ddp.py" \
    --data-dir "${DATA_DIR}" \
    --epochs "${EPOCHS}" \
    --max-steps "${MAX_STEPS}" \
    --batch-size "${BATCH_SIZE}" \
    --num-workers "${NUM_WORKERS}" \
    --log-interval "${LOG_INTERVAL}"
fi
