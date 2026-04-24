#!/bin/bash
set -e

# Change to the root of the repository
cd "$(dirname "$0")/.."

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "Error: You have uncommitted changes. Please commit or stash them before generating a new branch."
    exit 1
fi

# --- Configuration & Defaults ---
export VCLUSTER_NAME=${VCLUSTER_NAME:-"k3k-fleet-test"}
export VCLUSTER_NAMESPACE=${VCLUSTER_NAMESPACE:-"tenant2"}
export VCLUSTER_VERSION=${VCLUSTER_VERSION:-"v1.33.10-k3s1"}
export HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"kubevip"}
export FLEET_NAMESPACE=${FLEET_NAMESPACE:-"fleet-default"}
export STORAGE_CLASS=${STORAGE_CLASS:-"harvester"}
export STORAGE_SIZE=${STORAGE_SIZE:-"3Gi"}
export PARENT_CLUSTER_ID=${PARENT_CLUSTER_ID:-"c-m-8jclnfjn"}
export PARENT_CLUSTER_NAME=${PARENT_CLUSTER_NAME:-"kubevip"}
export IP_POOL_RANGE=${IP_POOL_RANGE:-"10.10.12.16/28"}
export MY_ASN=${MY_ASN:-"64512"}
export PEER_ASN=${PEER_ASN:-"64511"}
export PEER_ADDRESS=${PEER_ADDRESS:-"192.168.8.99"}
export GIT_REPO_URL=${GIT_REPO_URL:-"https://github.com/fultux/rancher-k3k-automation.git"}

# Define the branch name
export GIT_BRANCH="deploy-${VCLUSTER_NAME}"

# Ensure we are not already on the branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" == "$GIT_BRANCH" ]; then
    echo "You are already on the branch $GIT_BRANCH. Aborting to avoid double-rendering."
    exit 1
fi

echo "Creating deployment branch: $GIT_BRANCH"
git checkout -b "$GIT_BRANCH"

echo "Rendering YAML templates..."
for file in $(find manifests virtual-cluster fleet -name '*.yaml'); do
    # envsubst safely replaces variables and writes to a tmp file
    envsubst < "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
done

echo "Committing rendered manifests..."
git add manifests virtual-cluster fleet
git commit -m "chore: render templates for $VCLUSTER_NAME"

echo "========================================="
echo "Branch '$GIT_BRANCH' created and templates rendered successfully!"
echo "Next steps:"
echo "1. Push this branch: git push -u origin $GIT_BRANCH"
echo "2. Run deployment:   VCLUSTER_NAME=\"$VCLUSTER_NAME\" ./scripts/deploy.sh"
echo "========================================="
