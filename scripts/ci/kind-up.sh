#!/usr/bin/env bash
# Creates the local test cluster: kind, 1 control plane + 3 workers (one per "zone"),
# Calico CNI (enforces NetworkPolicy with iptables).
# KIND_NODE_IMAGE: Kubernetes >= 1.35 refuses cgroup v1 hosts. Docker Desktop's WSL2
# kernel may still be cgroup v1, hence the 1.34 default.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
KIND=${KIND:-kind}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.34.11}
# Calico 3.29: newer releases mount /sys/kernel/security, which Docker Desktop's WSL2
# kernel does not provide inside kind nodes.
CALICO_VERSION=${CALICO_VERSION:-v3.29.4}
cfg="$HERE/kind-config.yaml"
command -v cygpath >/dev/null 2>&1 && cfg=$(cygpath -m "$cfg")

"$KIND" create cluster --config "$cfg" --image "$KIND_NODE_IMAGE" --wait 0s
kubectl apply --server-side -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=10m
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -L topology.kubernetes.io/zone
