#!/bin/bash
set -e

# Change to the root of the repository
cd "$(dirname "$0")/.."

OVERLAY=${1:-"dev-cluster"}

echo "Rendering Kustomize templates for overlay: $OVERLAY..."

# Check if the overlay exists
if [ ! -d "overlays/$OVERLAY" ]; then
    echo "Error: Overlay directory overlays/$OVERLAY does not exist."
    exit 1
fi

mkdir -p manifests/host manifests/rancher fleet

echo "Processing Host cluster manifests..."
kubectl kustomize "overlays/$OVERLAY/host" > manifests/host/k3k.yaml

echo "Processing Rancher cluster manifests..."
kubectl kustomize "overlays/$OVERLAY/rancher" > manifests/rancher/cluster.yaml

echo "Processing Fleet definitions..."
kubectl kustomize "overlays/$OVERLAY/fleet" > fleet/git-repo.yaml

echo "Successfully rendered all manifests in $(pwd)."
echo "Remember: You MUST commit and push these files to Git for Fleet to apply them."
