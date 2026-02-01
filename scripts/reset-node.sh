#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root

log "Resetting kubeadm state"
kubeadm reset -f
rm -rf /etc/cni/net.d /var/lib/cni /var/lib/etcd /var/lib/kubelet/pki
systemctl restart containerd || true
