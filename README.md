# Milestone 1 - K8s + GPU Bootstrap (VastAI)

This repository provides scripts to bring up a 1x control-plane + 2x GPU node
Kubernetes cluster on VastAI, with Tailscale for node VPN, Calico for pod
networking, and NVIDIA GPU support.

## Prerequisites
- Ubuntu 22.04 (recommended)
- Root access on all nodes
- Tailscale auth key (if using Tailscale)

## Environment Variables
Common:
- `K8S_MINOR` (default `1.29`)
- `K8S_VERSION` (optional pin, e.g. `1.29.3-1.1`)
- `INSTALL_TAILSCALE` (`true`/`false`, default `true`)
- `TS_AUTHKEY` (required if `INSTALL_TAILSCALE=true`)
- `TS_HOSTNAME` (optional)
- `TS_EXTRA_ARGS` (optional, e.g. `--ssh --accept-dns=false`)

Control-plane:
- `CONTROL_PLANE_IP` (required, prefer the Tailscale IP if used)
- `POD_CIDR` (default `192.168.0.0/16`)
- `SERVICE_CIDR` (default `10.96.0.0/12`)
- `CALICO_MANIFEST_URL` (optional)
- `DEVICE_PLUGIN_URL` (optional)
- `KUBEADM_K8S_VERSION` (optional, e.g. `v1.29.3`)
- `K8S_ADMIN_USER` (optional, copy kubeconfig to this user)

GPU nodes:
- `KUBE_JOIN_COMMAND` (required)
- `NVIDIA_DRIVER_VERSION` (default `535`)

## One-Click Flow

### 1) Initialize control-plane
Required input:
- `TS_AUTHKEY`

```bash
sudo TS_AUTHKEY=tskey-xxxxx ./scripts/init-master.sh
```

### 2) Join GPU worker nodes
Required inputs:
- `TS_AUTHKEY`
- `KUBE_JOIN_COMMAND` (from `/root/kubeadm-join.sh` on the master)

```bash
sudo TS_AUTHKEY=tskey-xxxxx \
  KUBE_JOIN_COMMAND="$(ssh root@control-plane 'cat /root/kubeadm-join.sh')" \
  ./scripts/join-worker.sh
```

### 3) Reset a node (cleanup)
```bash
sudo ./scripts/reset-node.sh
```

## Metrics Server (required for HPA)
Metrics Server is installed automatically by `init-master.sh` and `control-plane.sh`.
To verify:

```bash
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
kubectl get apiservices | grep metrics
kubectl top nodes
```

If you need to reinstall manually:

```bash
METRICS_SERVER_MANIFEST_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" \
  sudo bash -lc 'source scripts/common.sh; install_metrics_server'
```

## HPA (CPU)
Example HPA manifest for inference service:

```bash
kubectl apply -f manifests/resnet-cifar-infer-hpa.yaml
kubectl get hpa
kubectl describe hpa resnet-cifar-infer
```

### HPA quick validation (CPU)
The inference service is GPU-heavy, so CPU usage is usually low. For quick HPA validation,
you can enable a small CPU burn per request and lower CPU requests to make scaling visible.

1) Enable CPU burn and lower requests:
```bash
kubectl apply -f manifests/resnet-cifar-infer-deploy.yaml
```

2) Start load inside the cluster:
```bash
kubectl run hpa-load --restart=Never --image=python:3.10-slim -- /bin/bash -lc 'cat > /tmp/load.py <<'"'"'PY'"'"'
import json, random, time, urllib.request
url = "http://resnet-cifar-infer/infer"
def make_tensor(batch, c=3, h=32, w=32):
    return [[[[random.randint(0,255) for _ in range(w)] for _ in range(h)] for _ in range(c)] for _ in range(batch)]
while True:
    payload = json.dumps({"inputs": make_tensor(64)}).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers={"Content-Type":"application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass
PY
python /tmp/load.py'
```

3) Watch scaling:
```bash
kubectl get hpa resnet-cifar-infer -w
kubectl top pods -n default
```

4) Stop load:
```bash
kubectl delete pod hpa-load --ignore-not-found
```

To disable CPU burn, set `CPU_BURN_MS=0` or remove the env var from the deployment manifest.
