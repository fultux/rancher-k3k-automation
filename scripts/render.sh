#!/bin/bash
set -e

# Change to the root of the repository
cd "$(dirname "$0")/.."

# --- Configuration & Defaults (Synchronized with deploy.sh) ---
export VCLUSTER_NAME=${VCLUSTER_NAME:-"k3k-fleet-test"}
export VCLUSTER_NAMESPACE=${VCLUSTER_NAMESPACE:-"tenant2"}
export VCLUSTER_MODE=${VCLUSTER_MODE:-"shared"}
export VCLUSTER_VERSION=${VCLUSTER_VERSION:-"v1.33.10-k3s1"}
export VCLUSTER_TLS_SANS=${VCLUSTER_TLS_SANS:-""}
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
export GIT_BRANCH=${GIT_BRANCH:-"template"}

# Dynamically construct the TLS SANs YAML array
if [ -n "$VCLUSTER_TLS_SANS" ]; then
    FORMATTED_SANS="  tlsSANs:"
    # Split by comma or space
    for san in $(echo "$VCLUSTER_TLS_SANS" | tr ',' ' '); do
        FORMATTED_SANS="${FORMATTED_SANS}\n  - \"${san}\""
    done
    export TLS_SANS_BLOCK=$(echo -e "$FORMATTED_SANS")
else
    export TLS_SANS_BLOCK=""
fi

echo "Rendering templates for cluster: $VCLUSTER_NAME..."

# List of files to render (source -> destination)
TEMPLATES=(
  "templates/fleet/git-repo.yaml:fleet/git-repo.yaml"
  "templates/manifests/host/k3k.yaml:manifests/host/k3k.yaml"
  "templates/manifests/rancher/cluster.yaml:manifests/rancher/cluster.yaml"
  "templates/virtual-cluster/bgp/bgp-conf.yaml:virtual-cluster/bgp/bgp-conf.yaml"
  "templates/virtual-cluster/metallb/fleet.yaml:virtual-cluster/metallb/fleet.yaml"
)

for entry in "${TEMPLATES[@]}"; do
    src="${entry%%:*}"
    dst="${entry#*:}"

    mkdir -p "$(dirname "$dst")"

    if [ -f "$src" ]; then
        echo "Processing $src -> $dst"
        envsubst < "$src" > "$dst"
    else
        echo "Warning: Source template $src not found, skipping."
    fi
done

echo "Successfully rendered all manifests in $(pwd)."
echo "Remember: If you are using Rancher Fleet, you MUST commit and push these files to Git for Fleet to apply them."
