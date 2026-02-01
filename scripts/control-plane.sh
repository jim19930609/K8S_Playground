#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CALICO_MANIFEST_URL="${CALICO_MANIFEST_URL:-https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml}"
DEVICE_PLUGIN_URL="${DEVICE_PLUGIN_URL:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml}"
METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"

if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  echo "Set CONTROL_PLANE_IP to the control-plane node IP (prefer Tailscale IP if used)." >&2
  exit 1
fi

disable_swap
configure_sysctl
install_containerd
install_k8s_packages

if [[ "${INSTALL_TAILSCALE:-true}" == "true" ]]; then
  install_tailscale
  tailscale_up
fi

log "Initializing Kubernetes control-plane"
kubeadm_args=(
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --apiserver-advertise-address="${CONTROL_PLANE_IP}"
)
if [[ -n "${KUBEADM_K8S_VERSION:-}" ]]; then
  kubeadm_args+=(--kubernetes-version="${KUBEADM_K8S_VERSION}")
fi
kubeadm init "${kubeadm_args[@]}"

log "Configuring kubeconfig for root"
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

if [[ -n "${K8S_ADMIN_USER:-}" && -d "/home/${K8S_ADMIN_USER}" ]]; then
  log "Copying kubeconfig to ${K8S_ADMIN_USER}"
  mkdir -p "/home/${K8S_ADMIN_USER}/.kube"
  cp -i /etc/kubernetes/admin.conf "/home/${K8S_ADMIN_USER}/.kube/config"
  chown -R "${K8S_ADMIN_USER}:${K8S_ADMIN_USER}" "/home/${K8S_ADMIN_USER}/.kube"
fi

log "Installing Calico CNI"
kubectl apply -f "${CALICO_MANIFEST_URL}"

log "Installing NVIDIA device plugin"
kubectl apply -f "${DEVICE_PLUGIN_URL}"

install_metrics_server

log "Creating join command"
kubeadm token create --print-join-command >/root/kubeadm-join.sh
chmod +x /root/kubeadm-join.sh
log "Join command saved to /root/kubeadm-join.sh"
