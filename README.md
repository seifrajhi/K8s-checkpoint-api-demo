# Backup and restore of containers with Kubernetes checkpointing API

Kubernetes v1.25 introduced the Container Checkpointing API as [an alpha feature](https://kubernetes.io/blog/2022/12/05/forensic-container-checkpointing-alpha/), and it has reached [beta in Kubernetes v1.30](https://kubernetes.io/docs/reference/node/kubelet-checkpoint-api/).

This provides a way to backup-and-restore containers running in Pods, without ever stopping them.
