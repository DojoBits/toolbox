#!/bin/bash

set -e

# Global Defaults

K8S_VER="v1.30"
K8S_VER_MIN="1"
CRI_VER="v1.30.0"
CIL_VER="1.15.5"


# Detect OS arch

arch=$(uname -m)

if [[ "$arch" == "x86_64" ]]; then
  arch="amd64"
elif [[ "$arch" == "aarch64" ]]; then
  arch="arm64"
fi

## Disable SWAP

sudo swapoff -a
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

# Configure kernel parameters

sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# Install containerd runtime and dependencies

sudo apt-get update -y
sudo apt-get install ca-certificates curl gnupg -y

# Add Docker’s official GPG key:

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Configure Docker APT repository

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install containerd

sudo apt-get update -y
sudo apt-get install containerd.io -y

# Generate default configuration file for containerd

sudo containerd config default | sudo tee /etc/containerd/config.toml

# Enable usage of Systemd Cgroups

sudo sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml


# Restart and enable containerd service

sudo systemctl restart containerd
sudo systemctl enable containerd

# Install kubeadm, kubelet and kubectl

sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Download the Kubernetes public signing key:

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the Kubernetes apt repository:

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update apt package index, install kubelet, kubeadm and kubectl, and pin their version:

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# apt-mark hold will prevent the package from being automatically upgraded or removed.

sudo apt-mark hold kubelet kubeadm kubectl

# Enable and start kubelet service

sudo systemctl daemon-reload
sudo systemctl start kubelet
sudo systemctl enable kubelet.service

# Initialize K8s cluster
sudo kubeadm init --cri-socket=unix:///var/run/containerd/containerd.sock --kubernetes-version="${K8S_VER}.${K8S_VER_MIN}"


# configure kubectl client

mkdir -p "${HOME}/.kube"
sudo cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

# Install crictl

wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRI_VER/crictl-$CRI_VER-linux-${arch}.tar.gz
sudo tar zxvf crictl-$CRI_VER-linux-${arch}.tar.gz -C /usr/local/bin
rm -f crictl-$CRI_VER-linux-${arch}.tar.gz
echo "runtime-endpoint: unix:///run/containerd/containerd.sock" | sudo tee /etc/crictl.yaml

# Install Cilium CNI

curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm


helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version "${CIL_VER}" --namespace kube-system --set operator.replicas=1

# Install Cilium CNI

CIL_CLI_VER=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CIL_CLI_VER}/cilium-linux-${arch}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${arch}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${arch}.tar.gz /usr/local/bin
rm cilium-linux-${arch}.tar.gz{,.sha256sum}

# Remove the taints

kubectl patch node "$(hostname)" -p '{"spec":{"taints":[]}}'
