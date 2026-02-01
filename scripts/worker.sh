#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root

KUBE_JOIN_COMMAND="${KUBE_JOIN_COMMAND:-}"
if [[ -z "${KUBE_JOIN_COMMAND}" ]]; then
  echo "Set KUBE_JOIN_COMMAND to the output of kubeadm token create --print-join-command." >&2
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

install_nvidia_driver
install_nvidia_container_toolkit

log "Joining Kubernetes cluster"
${KUBE_JOIN_COMMAND}
