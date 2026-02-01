#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root

NODE_NAME="${NODE_NAME:-}"
if [[ -n "${NODE_NAME}" ]]; then
  hostnamectl set-hostname "${NODE_NAME}"
  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${NODE_NAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${NODE_NAME}" >>/etc/hosts
  fi
fi

KUBE_JOIN_COMMAND="${KUBE_JOIN_COMMAND:-}"
if [[ -z "${KUBE_JOIN_COMMAND}" ]]; then
  echo "Set KUBE_JOIN_COMMAND to the output of kubeadm token create --print-join-command." >&2
  exit 1
fi
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
install_nvidia_container_toolkit

log "Joining Kubernetes cluster"
if [[ "${KUBE_JOIN_COMMAND}" != *"--cri-socket"* ]]; then
  KUBE_JOIN_COMMAND="${KUBE_JOIN_COMMAND} --cri-socket unix:///run/containerd/containerd.sock"
fi
eval "${KUBE_JOIN_COMMAND}"
