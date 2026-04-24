#!/bin/bash
#Uncomment to enable debug
#set -x
# Exit on error
set -e # Exit on error

# Change to the root of the repository
cd "$(dirname "$0")/.."

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
export GIT_BRANCH=${GIT_BRANCH:-"template"}

if [ -z "$RANCHER_KUBECONFIG" ] || [ -z "$HOST_KUBECONFIG" ]; then
    echo "Error: RANCHER_KUBECONFIG and HOST_KUBECONFIG environment variables must be set."
    echo "Example: export RANCHER_KUBECONFIG=/path/to/rancher.yaml"
    echo "         export HOST_KUBECONFIG=/path/to/downstream.yaml"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is required but not installed."
    exit 1
fi

# Helper function for kubectl to the local rancher cluster
kc_local() {
    kubectl --kubeconfig="$RANCHER_KUBECONFIG" "$@"
}

# Helper function for kubectl to the downstream host cluster via kubeconfig
kc_host() {
    kubectl --kubeconfig="$HOST_KUBECONFIG" "$@"
}

echo "--- Deleting k3k cluster via Rancher Fleet ---"

# Get the Virtual Cluster ID for cleanup reference before it's deleted
VCLUSTER_ID=$(kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.clusterName}' 2>/dev/null || true)

# 1. Delete the agent injector job
echo "Deleting agent injector job from the host cluster..."
kc_host delete job agent-injector -n "$VCLUSTER_NAMESPACE" --ignore-not-found || true

# 2. Delete Fleet GitRepo definitions
echo "Deleting Fleet GitRepo definitions..."
if [ -f "fleet/git-repo.yaml" ]; then
    kc_local delete -f "fleet/git-repo.yaml" --ignore-not-found || true
fi

# 3. Ensure Rancher provisioning cluster is deleted
echo "Ensuring Rancher provisioning cluster is deleted..."
kc_local delete cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" --ignore-not-found --wait=false || true

# 4. Ensure host k3k cluster resource is deleted
echo "Ensuring host k3k cluster resource is deleted..."
kc_host delete clusters.k3k.io "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" --ignore-not-found --wait=false || true

# 5. Wait for resources to be fully removed
echo "Waiting for Rancher cluster object to be fully removed..."
while kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" > /dev/null 2>&1; do
    sleep 5
done

echo "Waiting for host k3k cluster object to be fully removed..."
while kc_host get clusters.k3k.io "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" > /dev/null 2>&1; do
    sleep 5
done

# 6. Cleanup cluster registration tokens
if [ -n "$VCLUSTER_ID" ]; then
    echo "Cleaning up any dangling ClusterRegistrationTokens for cluster $VCLUSTER_ID..."
    for token in $(kc_local get clusterregistrationtoken -n "$VCLUSTER_ID" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
        if [ -n "$token" ]; then
            kc_local delete clusterregistrationtoken "$token" -n "$VCLUSTER_ID" --ignore-not-found || true
        fi
    done
fi

echo "Cleanup complete! The k3k cluster '$VCLUSTER_NAME' has been successfully deleted."
