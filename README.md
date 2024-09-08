# Backup and restore of containers with Kubernetes checkpointing API

Kubernetes v1.25 introduced the Container Checkpointing API as [an alpha feature](https://kubernetes.io/blog/2022/12/05/forensic-container-checkpointing-alpha/), and it has reached [beta in Kubernetes v1.30](https://kubernetes.io/docs/reference/node/kubelet-checkpoint-api/).

This provides a way to backup-and-restore containers running in Pods, without ever stopping them.


## CRIU overview:

To implement Kubernetes checkpointing, we need to use a container runtime that supports [CRIU (Checkpoint/Restore in Userspace)](https://criu.org/Main_Page).

CRIU tool, in it’s simple terms, helps in taking a snapshot of a program while it’s running & then being able to resume it later, just like you might pause and resume a video or a video game.



## Kubernetes CRI-O and Checkpoint/Restore Setup

This guide will help you set up a Kubernetes cluster with CRI-O and enable checkpoint/restore functionality.

### Prerequisites

- Ubuntu 20.04
- Root or sudo access

### Steps

#### 1. Disable Swap

```sh
swapoff -a
sed -i '/swap/d' /etc/fstab
```

#### 2. Load Necessary Kernel Modules

```sh
cat >>/etc/modules-load.d/crio.conf<<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
```

#### 3. Configure Sysctl

```sh
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
```

#### 4. Disable UFW

```sh
ufw disable
```

#### 5. Install CRI-O

```sh
OS=xUbuntu_20.04
CRIO_VERSION=1.28
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.28:/1.28.0/xUbuntu_20.04/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -

sudo apt-get update
sudo apt-get update -qq
sudo export DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libbtrfs-dev \
  containers-common \
  git \
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
  cri-o-runc \
  libudev-dev \
  software-properties-common

sudo apt-get install -qq -y cri-o cri-tools

systemctl daemon-reload
systemctl enable --now crio
```

#### 6. Install Kubernetes Components

```sh
mkdir -p /etc/apt/keyrings/

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

sudo apt-get update
sudo apt-get install kubelet kubeadm kubectl -y
sudo systemctl enable --now kubelet
sudo apt-mark hold kubelet kubeadm kubectl
```

#### 7. Initialize Kubernetes Cluster

```sh
kubeadm init --pod-network-cidr=192.168.0.0/16 --cri-socket unix:///var/run/crio/crio.sock  --ignore-preflight-errors=NumCPU

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info dump

kubectl get nodes -o wide
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

PS: if you are using a k8s version lower than v1.30, add `--feature-gates ContainerCheckpoint=true` to the `kubeadm init` coomand.

#### 8. Install CRIU

```sh
sudo apt-get install criu
```

#### 9. Enable CRIU Support in CRI-O

```sh
sed -i 's/# enable_criu_support = false/enable_criu_support = true/' /etc/crio/crio.conf
systemctl restart crio
```

#### 10. Enable Checkpoint Feature Gates

Edit the following files to enable the `ContainerCheckpoint` feature gate:

- `/etc/kubernetes/manifests/kube-apiserver.yaml`:
  ```yaml
  - --feature-gates=ContainerCheckpoint=true
  ```

- `/var/lib/kubelet/config.yaml`:
  ```yaml
  featureGates:
    ContainerCheckpoint: true
  ```

Restart the kubelet:

```sh
sudo systemctl restart kubelet
```

#### 11. Deploy a Test Pod

```sh
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
```

#### 12. Check Pod Status

```sh
kubectl get pods -o wide
```

#### 13. Checkpoint the Pod

```sh
curl -sk -X POST "https://localhost:10250/checkpoint/default/webserver/webserver" \
  --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
  --cacert /etc/kubernetes/pki/ca.crt \
  --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt
```

#### 14. Verify Checkpoint

```sh
ls -l /var/lib/kubelet/checkpoints
```

#### 15. Restore the Pod

```sh
newcontainer=$(buildah from scratch)
buildah add $newcontainer /var/lib/kubelet/checkpoints/checkpoint-<pod-name>_<namespace-name>-<container-name>-<timestamp>.tar /
buildah config --annotation=io.kubernetes.cri-o.annotations.checkpoint.name=<container-name> $newcontainer
buildah commit $newcontainer checkpoint-image:latest
buildah rm $newcontainer
```
