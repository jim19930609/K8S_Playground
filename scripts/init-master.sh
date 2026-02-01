#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root

POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CALICO_MANIFEST_URL="${CALICO_MANIFEST_URL:-https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml}"
DEVICE_PLUGIN_URL="${DEVICE_PLUGIN_URL:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml}"
METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
ALLOW_SCHEDULING_ON_CONTROL_PLANE="${ALLOW_SCHEDULING_ON_CONTROL_PLANE:-true}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

if [[ -z "${TS_AUTHKEY}" ]]; then
  echo "Set TS_AUTHKEY for Tailscale." >&2
  exit 1
fi

disable_swap
configure_sysctl
install_containerd
install_k8s_packages
install_tailscale
tailscale_up

CONTROL_PLANE_IP="$(tailscale ip -4 | head -n1)"
if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  echo "Failed to detect Tailscale IP." >&2
  exit 1
fi

log "Initializing Kubernetes control-plane"
kubeadm_args=(
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --apiserver-advertise-address="${CONTROL_PLANE_IP}"
  --cri-socket "unix:///run/containerd/containerd.sock"
)
if [[ -n "${KUBEADM_K8S_VERSION:-}" ]]; then
  kubeadm_args+=(--kubernetes-version="${KUBEADM_K8S_VERSION}")
fi
kubeadm init "${kubeadm_args[@]}"

log "Configuring kubeconfig for root"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

if [[ -n "${K8S_ADMIN_USER:-}" && -d "/home/${K8S_ADMIN_USER}" ]]; then
  log "Copying kubeconfig to ${K8S_ADMIN_USER}"
  mkdir -p "/home/${K8S_ADMIN_USER}/.kube"
  cp -f /etc/kubernetes/admin.conf "/home/${K8S_ADMIN_USER}/.kube/config"
  chown -R "${K8S_ADMIN_USER}:${K8S_ADMIN_USER}" "/home/${K8S_ADMIN_USER}/.kube"
fi

log "Installing Calico CNI"
kubectl apply -f "${CALICO_MANIFEST_URL}"

log "Installing NVIDIA device plugin"
kubectl apply -f "${DEVICE_PLUGIN_URL}"

install_metrics_server

if [[ "${ALLOW_SCHEDULING_ON_CONTROL_PLANE}" == "true" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
fi

log "Creating join command"
kubeadm token create --print-join-command >/root/kubeadm-join.sh
chmod +x /root/kubeadm-join.sh
log "Join command saved to /root/kubeadm-join.sh"
