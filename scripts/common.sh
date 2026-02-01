#!/usr/bin/env bash
set -euo pipefail

log() {
  printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

disable_swap() {
  log "Disabling swap"
  swapoff -a || true
  if [[ -f /etc/fstab ]]; then
    sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
  fi
}

configure_sysctl() {
  log "Configuring kernel settings for Kubernetes"
  modprobe br_netfilter
  cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
  sysctl --system
}

install_containerd() {
  log "Installing containerd"
  apt-get update
  if apt-cache show containerd.io >/dev/null 2>&1; then
    apt-get install -y containerd.io
  else
    apt-get install -y containerd
  fi
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  if ! ctr plugins ls 2>/dev/null | awk '{print $2}' | grep -qx 'cri'; then
    log "containerd CRI plugin missing; trying containerd.io"
    apt-get install -y containerd.io
    containerd config default >/etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
  fi
}

install_k8s_packages() {
  local k8s_minor="${K8S_MINOR:-1.29}"
  log "Installing Kubernetes packages (v${k8s_minor})"
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gpg
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb/Release.key" \
    | gpg --dearmor --yes --batch -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb/ /
EOF
  apt-get update
  if [[ -n "${K8S_VERSION:-}" ]]; then
    apt-get install -y kubelet="${K8S_VERSION}" kubeadm="${K8S_VERSION}" kubectl="${K8S_VERSION}"
  else
    apt-get install -y kubelet kubeadm kubectl
  fi
  apt-mark hold kubelet kubeadm kubectl
}

install_tailscale() {
  log "Installing Tailscale"
  apt-get update
  apt-get install -y curl gpg
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt-get update
  apt-get install -y tailscale
}

tailscale_up() {
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    log "TS_AUTHKEY not set; skipping tailscale up"
    return
  fi
  local hostname="${TS_HOSTNAME:-$(hostname -s)}"
  local extra_args="${TS_EXTRA_ARGS:-}"
  log "Bringing up Tailscale (${hostname})"
  tailscale up --authkey "${TS_AUTHKEY}" --hostname "${hostname}" ${extra_args}
}

install_nvidia_driver() {
  local driver_version="${NVIDIA_DRIVER_VERSION:-535}"
  log "Installing NVIDIA driver ${driver_version}"
  apt-get update
  apt-get install -y "nvidia-driver-${driver_version}"
}

install_nvidia_container_toolkit() {
  log "Installing NVIDIA Container Toolkit"
  apt-get update
  apt-get install -y curl gpg
  mkdir -p /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes --batch -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=containerd --set-as-default
  systemctl restart containerd
}

install_metrics_server() {
  local manifest_url="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
  local metrics_node_selector="${METRICS_SERVER_NODE_SELECTOR:-kubernetes.io/hostname=ubuntu}"
  log "Installing metrics-server"
  kubectl apply -f "${manifest_url}"

  # Add common flags for clusters without valid kubelet TLS or with mixed node addressing.
  local args
  args="$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)"
  if [[ -z "${args}" ]]; then
    return
  fi
  if ! grep -q -- '--kubelet-insecure-tls' <<<"${args}"; then
    kubectl -n kube-system patch deployment metrics-server \
      --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
  fi
  if ! grep -q -- '--kubelet-preferred-address-types' <<<"${args}"; then
    kubectl -n kube-system patch deployment metrics-server \
      --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalIP,ExternalDNS"}]' >/dev/null
  fi

  if [[ -n "${metrics_node_selector}" ]]; then
    local selector_key="${metrics_node_selector%%=*}"
    local selector_value="${metrics_node_selector#*=}"
    kubectl -n kube-system patch deployment metrics-server \
      --type='merge' \
      -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${selector_key}\":\"${selector_value}\"}}}}}" >/dev/null
  fi
}
