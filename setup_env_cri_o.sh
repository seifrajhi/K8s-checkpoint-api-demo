#!/bin/bash

# Exit immediately if a command exits with a non-zero status, Treat unset variables as an error and exit immediately, The return value of a pipeline is the status of the last command to exit with a non-zero status
set -euo pipefail

# Function to print colorful messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}\033[0m"
}

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

# Check if figlet and toilet are installed, if not, install them
if ! command -v figlet &> /dev/null || ! command -v toilet &> /dev/null; then
    print_message $YELLOW "Figlet or Toilet not found, installing..."
    sudo apt-get update && sudo apt-get install -y figlet toilet
fi

# Print the title using figlet
figlet -f smblock "Script to setup forensic container checkpointing with CRIU in Kubernetes 1.30 and cri-o runtime v1.28"

# Prompt the user for confirmation
echo "Do you wish to continue?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) 
            print_message $GREEN "Proceeding with installation..."
            break
            ;;
        No ) 
            print_message $RED "Installation aborted."
            exit
            ;;
    esac
done

# Start of the script
print_message $BLUE "Starting the script..."

# Disable swap
print_message $YELLOW "Disabling swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab
sleep 1

# Load necessary kernel modules
print_message $YELLOW "Loading kernel modules..."
cat >>/etc/modules-load.d/crio.conf<<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
sleep 1

# Configure sysctl for Kubernetes
print_message $YELLOW "Configuring sysctl for Kubernetes..."
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sleep 1

# Disable UFW
print_message $YELLOW "Disabling UFW..."
ufw disable
sleep 1

# Remove unnecessary packages
print_message $YELLOW "Removing unnecessary packages..."
sudo apt-get remove containernetworking-plugins -y && sudo apt-get remove conmon -y
sleep 1

# Create keyrings directory
print_message $YELLOW "Creating keyrings directory..."
mkdir -p /etc/apt/keyrings/
sleep 1

# Add CRI-O repository and install CRI-O
print_message $YELLOW "Adding CRI-O repository and installing CRI-O..."
OS=xUbuntu_20.04
CRIO_VERSION=1.28
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:1.28/xUbuntu_20.04/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y \
  libbtrfs-dev \
  git \
  containers-common \
  libassuan-dev \
  libglib2.0-dev \
  libc6-dev \
  libgpgme-dev \
  libgpg-error-dev \
  libseccomp-dev \
  libsystemd-dev \
  libselinux1-dev \
  pkg-config \
  go-md2man \
  libudev-dev \
  software-properties-common \
  gcc \
  make \
  cri-o \
  cri-tools \
  cri-o-runc
sleep 1

# Output version of CRI-O
print_message $BLUE "CRI-O version:"
crio --version
sleep 1

# Enable and start CRI-O
print_message $YELLOW "Enabling and starting CRI-O..."
systemctl daemon-reload
systemctl enable --now crio
sleep 1

# Add Kubernetes repository and install Kubernetes components
print_message $YELLOW "Adding Kubernetes repository and installing components..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update
sudo apt-get install kubelet kubeadm kubectl -y
sudo apt-mark hold kubelet kubeadm kubectl
sleep 1

# Output versions of Kubernetes components
print_message $BLUE "Kubernetes components versions:"
kubeadm version
kubelet --version
kubectl version --client
sleep 1

# Enable and start kubelet
print_message $YELLOW "Enabling and starting kubelet..."
sudo systemctl enable --now kubelet
sleep 1

# Initialize Kubernetes cluster
print_message $YELLOW "Initializing Kubernetes cluster..."
kubeadm init --pod-network-cidr=192.168.0.0/16 --cri-socket unix:///var/run/crio/crio.sock --ignore-preflight-errors=NumCPU
sleep 1

# Configure kubectl for the current user
print_message $YELLOW "Configuring kubectl for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info dump
sleep 1

# Remove taints on control-plane nodes
print_message $YELLOW "Removing taints on control-plane nodes..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl get nodes -o wide
sleep 1

# Enable CRIU support in CRI-O
print_message $YELLOW "Enabling CRIU support in CRI-O..."
sed -i 's/# enable_criu_support = false/enable_criu_support = true/' /etc/crio/crio.conf
sudo systemctl restart crio
sleep 5

# Ensure the default service account exists
print_message $YELLOW "Ensuring the default service account exists..."
kubectl create serviceaccount default || true
sleep 1

# Deploy a sample webserver pod
print_message $YELLOW "Deploying a sample webserver pod..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: webserver
spec:
  containers:
  - name: webserver
    image: nginx:latest
    ports:
    - containerPort: 80
    env:
    - name: GLIBC_TUNABLES
      value: "glibc.pthread.rseq=0"
EOF
sleep 1

# Wait for the pod to be in running state
print_message $YELLOW "Waiting for the webserver pod to be in running state..."
kubectl get pods -o wide
sleep 1

# Checkpoint the webserver pod
print_message $YELLOW "Checkpointing the webserver pod..."
curl -sk -X POST "https://localhost:10250/checkpoint/default/webserver/webserver" \
  --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
  --cacert /etc/kubernetes/pki/ca.crt \
  --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt
sleep 1

# List checkpoints
print_message $YELLOW "Listing checkpoints..."
ls -l /var/lib/kubelet/checkpoints
sleep 1

# Output version of CRIU
print_message $BLUE "CRIU version:"
criu --version
sleep 1

# End of the script
print_message $GREEN "Script execution completed successfully!"

# Exit the script
exit 0
