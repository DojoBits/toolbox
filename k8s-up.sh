#!/usr/bin/env bash

#===============================================================================
#  Automated Docker‑containerd + Kubernetes + Cilium installation
#  Tested on Ubuntu 24.04 LTS (apt‑based)
#===============================================================================

set -euo pipefail
IFS=$'\n\t'


# ---------------------------------------------------------------------------
#  Configuration (change only the variables below)
# ---------------------------------------------------------------------------

K8S_MAJOR="1"
K8S_MINOR="34"
K8S_PATCH="1"

CRI_VER="v1.34.0"
CIL_VER="1.18.1"

K8S_VER="v${K8S_MAJOR}.${K8S_MINOR}"
K8S_FULL="${K8S_VER}.${K8S_PATCH}"
PKG_VER="${K8S_MAJOR}.${K8S_MINOR}.${K8S_PATCH}-1.1"


# ---- Helper functions -------------------------------------------------------
log()   { echo -e "\033[1;34m[INFO]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---- Ensure we run as root --------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or via sudo)."
fi

# ---- Detect CPU architecture -------------------------------------------------

case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|armv8*) ARCH="arm64" ;;
    *) error "Unsupported architecture: $(uname -m)" ;;
esac

# ---- Detect Ubuntu/Debian ---------------------------------------------------
if ! command -v lsb_release >/dev/null 2>&1; then
    error "lsb_release not found – this script only supports Ubuntu/Debian."
fi

UBUNTU_CODENAME=$(lsb_release -cs)

# ---- Disable swap (idempotent) ---------------------------------------------
if swapon --show | grep -q .; then
    log "Disabling swap..."
    swapoff -a
    sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab
else
    log "Swap already disabled."
fi

# ---- Load required kernel modules -------------------------------------------
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter


# ---- Sysctl customization ---------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/kubernetes.conf"
if [[ ! -f "$SYSCTL_FILE" ]]; then
    log "Writing sysctl config..."
    cat >"$SYSCTL_FILE" <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system
else
    log "Sysctl configuration already present."
fi

# ---- Install prerequisite packages -------------------------------------------
log "Updating apt cache..."
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https


# ---- Add Docker GPG key and verify fingerprint -------------------------------
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_KEY_TEMP="/tmp/docker.gpg"

if [[ ! -f "$DOCKER_KEYRING" ]]; then
    log "Adding Docker APT repository key..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEY_TEMP"
    if [[ ! -s "$DOCKER_KEY_TEMP" ]]; then
        error "Failed to download Docker GPG key from Docker servers."
    fi
    # Check ASCII fingerprint before dearmoring key
    ACTUAL_FP=$(gpg --show-keys --with-fingerprint "$DOCKER_KEY_TEMP" 2>/dev/null \
                     | awk '/^ / {gsub(" ", ""); print; exit}')
    if [[ -z "$ACTUAL_FP" ]]; then
        error "Failed to extract fingerprint from Docker GPG key, aborting."
    fi
    if [[ "$ACTUAL_FP" != "$DOCKER_FINGERPRINT" ]]; then
        error "Docker GPG key fingerprint mismatch – aborting."
    fi
    gpg --dearmor -o "$DOCKER_KEYRING" "$DOCKER_KEY_TEMP"
    rm -f "$DOCKER_KEY_TEMP"
else
    log "Docker GPG key already installed."
fi

# ---- Add Docker APT repo -----------------------------------------------------
DOCKER_REPO="/etc/apt/sources.list.d/docker.list"
if [[ ! -f "$DOCKER_REPO" ]]; then
    log "Adding Docker APT repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_KEYRING] \
https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
        >"$DOCKER_REPO"
else
    log "Docker repository already configured."
fi

# ---- Install containerd (Docker upstream version) ---------------------------
log "Installing containerd..."
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io


# ---- Enable Systemd cgroup driver -------------------------------------------
CONFIG_TOML="/etc/containerd/config.toml"
if ! grep -q "SystemdCgroup = true" "$CONFIG_TOML"; then
    log "Enabling SystemdCgroup in containerd config..."
    containerd config default >"$CONFIG_TOML"
    sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONFIG_TOML"
    systemctl restart containerd
else
    log "SystemdCgroup already set."
fi
systemctl enable --now containerd


# ---- Add Kubernetes APT repo ------------ ----------------------------------
K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_FINGERPRINT="DE15B14486CD377B9E876E1A234654DA9A296436"
K8S_KEY_TEMP="/tmp/k8s.key"

if [[ ! -f "$K8S_KEYRING" ]]; then
    log "Adding Kubernetes APT repository key..."
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/Release.key" -o "$K8S_KEY_TEMP"
    ACTUAL_FP=$(gpg --show-keys --with-fingerprint "$K8S_KEY_TEMP" 2>/dev/null \
      | awk '/^ / {gsub(" ", ""); print; exit}')
    if [[ -z "$ACTUAL_FP" ]]; then
        error "Failed to extract fingerprint from Kubernetes GPG key, aborting."
    fi
    if [[ "$ACTUAL_FP" != "$K8S_FINGERPRINT" ]]; then
        error "Kubernetes GPG key fingerprint mismatch."
    fi
    gpg --dearmor -o "$K8S_KEYRING" /tmp/k8s.key
    rm /tmp/k8s.key
else
    log "Kubernetes GPG key already present."
fi

K8S_REPO="/etc/apt/sources.list.d/kubernetes.list"
if [[ ! -f "$K8S_REPO" ]]; then
    log "Adding Kubernetes APT repository..."
    echo "deb [signed-by=$K8S_KEYRING] https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/ /" \
        >"$K8S_REPO"
fi

log "Updating apt cache for Kubernetes packages..."
apt-get update


# ---- Install kubeadm, kubelet, kubectl -----------------------------------
log "Installing kubelet/kubeadm/kubectl (${PKG_VER})..."
apt-get install -y \
    kubelet="${PKG_VER}" \
    kubeadm="${PKG_VER}" \
    kubectl="${PKG_VER}"

apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# ---- Initialise the control‑plane ---------- -----------------------------
if [[ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    log "Running kubeadm init (Kubernetes $K8S_FULL)..."
    kubeadm init \
        --cri-socket=unix:///var/run/containerd/containerd.sock \
        --kubernetes-version="${K8S_FULL}"
else
    log "kubeadm init already performed."
fi


# ---- Configure kubectl for the admin user ------------------------------
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
    KUBE_CONF_DIR="${USER_HOME}/.kube"
    log "Setting up kubectl config for the $SUDO_USER user..."
    mkdir -p "${KUBE_CONF_DIR}"
    if [[ ! -f "${KUBE_CONF_DIR}/config" ]]; then
        cp /etc/kubernetes/admin.conf "${KUBE_CONF_DIR}/config"
        chown "$SUDO_USER:$SUDO_USER" "${KUBE_CONF_DIR}/config"
        chmod 600 "${KUBE_CONF_DIR}/config"
        log "kubectl config created for $SUDO_USER user."
    else
        log "kubectl config already present for $SUDO_USER user, skipping copy."
    fi
else
    KUBE_CONF_DIR="${HOME}/.kube"
    log "Setting up kubectl config for the $(whoami) user..."
    mkdir -p "${KUBE_CONF_DIR}"
    if [[ ! -f "${KUBE_CONF_DIR}/config" ]]; then
        cp /etc/kubernetes/admin.conf "${KUBE_CONF_DIR}/config"
        chown "$(id -u):$(id -g)" "${KUBE_CONF_DIR}/config"
        chmod 600 "${KUBE_CONF_DIR}/config"
        log "kubectl config created for $(id -u) user."
    else
        log "kubectl config already present for $(id -u) user, skipping copy."
    fi
fi


# ---- Install crictl -----------------------------------------------------
CRICTL_BIN="/usr/local/bin/crictl"
if [[ ! -x "$CRICTL_BIN" ]]; then
    log "Downloading crictl $CRI_VER..."
    curl -fsSL -O "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRI_VER}/crictl-${CRI_VER}-linux-${ARCH}.tar.gz"
    tar -C /usr/local/bin -xzf "crictl-${CRI_VER}-linux-${ARCH}.tar.gz"
    rm "crictl-${CRI_VER}-linux-${ARCH}.tar.gz"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint:    unix:///run/containerd/containerd.sock
EOF
    chmod 600 /etc/crictl.yaml
else
    log "crictl already installed."
fi


# ---- Install Helm -------------------------------------------------------
HELM_KEYRING="/usr/share/keyrings/helm.gpg"
if [[ ! -f "$HELM_KEYRING" ]]; then
    log "Adding Helm repository key..."
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor -o "$HELM_KEYRING"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$HELM_KEYRING] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
        >/etc/apt/sources.list.d/helm-stable-debian.list
    apt-get update
fi
apt-get install -y helm


# ---- Deploy Cilium -----------------------------------------------------
CILIUM_NS="kube-system"
if ! helm status cilium -n "$CILIUM_NS" >/dev/null 2>&1; then
    log "Installing Cilium $CIL_VER via Helm..."
    helm repo add cilium https://helm.cilium.io/ --force-update
    helm upgrade --install cilium cilium/cilium \
        --version "$CIL_VER" \
        --namespace "$CILIUM_NS" \
        --set operator.replicas=1 \
        --create-namespace
else
    log "Cilium Helm release already exists."
fi

# ---- Install Cilium‑CLI ------------------------------------------------------
CIL_CLI_VER=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CIL_CLI_TAR="cilium-linux-${ARCH}.tar.gz"
if [[ ! -x "/usr/local/bin/cilium" ]]; then
    log "Downloading Cilium CLI $CIL_CLI_VER..."
    curl -fsSL -O "https://github.com/cilium/cilium-cli/releases/download/${CIL_CLI_VER}/${CIL_CLI_TAR}"
    curl -fsSL -O "https://github.com/cilium/cilium-cli/releases/download/${CIL_CLI_VER}/${CIL_CLI_TAR}.sha256sum"
    sha256sum --check "${CIL_CLI_TAR}.sha256sum"
    tar -C /usr/local/bin -xzf "${CIL_CLI_TAR}"
    rm "${CIL_CLI_TAR}" "${CIL_CLI_TAR}.sha256sum"
else
    log "Cilium CLI already installed."
fi

# ---- Remove the default control‑plane taint -------------------------------
if kubectl get nodes "$(hostname)" -o jsonpath='{.spec.taints}' | grep -q 'node-role.kubernetes.io/control-plane'; then
    log "Removing the control‑plane NoSchedule taint..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-
else
    log "Control‑plane taint already removed."
fi

log "All done! 🎉"

