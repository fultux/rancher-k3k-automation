#!/bin/bash
#Uncomment to enable debug
#set -x
set -e # Exit on error

# Change working directory to the project root
cd "$(dirname "$0")/.."

# --- Configuration & Defaults ---
VCLUSTER_NAME=${VCLUSTER_NAME:-"vcluster1"}
VCLUSTER_NAMESPACE=${VCLUSTER_NAMESPACE:-"tenant1"}
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"host"}
FLEET_NAMESPACE=${FLEET_NAMESPACE:-"fleet-default"}
INJECTOR_IMAGE=${INJECTOR_IMAGE:-"alpine:latest"}

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

if ! command -v envsubst &> /dev/null; then
    echo "Error: envsubst (gettext) is required but not installed."
    exit 1
fi

# Helper function for kubectl to the local rancher cluster
kc_local() {
    kubectl --kubeconfig="$RANCHER_KUBECONFIG" "$@"
}

echo "--- Deploying k3k cluster via Rancher Fleet ---"

# 1. Sync Fleet to create the placeholder and the pods
echo "Applying Fleet GitRepo definitions..."
kc_local apply -f manifests/fleet/git-repo.yaml

# 2. Wait for Rancher to process the placeholder
echo "Waiting for Virtual Cluster ID for '$VCLUSTER_NAME'..."
while true; do
    VCLUSTER_ID=$(kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.clusterName}' 2>/dev/null || true)
    if [ -n "$VCLUSTER_ID" ]; then break; fi
    sleep 5
done
echo "Virtual Cluster ID assigned: $VCLUSTER_ID"

# 3. Idempotency Check & Get Import Command
# Get Rancher server URL from kubeconfig
RANCHER_SERVER_URL=$(kc_local config view --minify -o jsonpath='{.clusters[0].cluster.server}')
RANCHER_BASE_URL=$(echo "$RANCHER_SERVER_URL" | sed 's|/k8s/clusters/local.*||')

echo "Checking if cluster is already fully provisioned and Active..."

IS_READY=$(kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$IS_READY" == "True" ]; then
    echo "Cluster is already Active! Skipping import command generation."
    IMPORT_CMD="echo 'Cluster already Active, no injection needed.'"
else
    echo "Getting Import Command for Rancher Virtual Cluster..."

    echo "Checking for existing ClusterRegistrationToken..."
    TOKEN_NAME=$(kc_local get clusterregistrationtokens.management.cattle.io -n "$VCLUSTER_ID" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$TOKEN_NAME" ]; then
        TOKEN_NAME="token-$(date +%s)"
        echo "Creating ClusterRegistrationToken $TOKEN_NAME..."
        export TOKEN_NAME VCLUSTER_ID
        envsubst '$TOKEN_NAME $VCLUSTER_ID' < templates/injector/registration-token.yaml | kc_local create -f -
    fi

    # Wait for the cluster registration secret or token to be generated
    while true; do
        # 1. Try to get token from status.tokenSecretName (Rancher >= 2.14)
        TOKEN_SECRET_NAME=$(kc_local get clusterregistrationtokens.management.cattle.io "$TOKEN_NAME" -n "$VCLUSTER_ID" -o jsonpath='{.status.tokenSecretName}' 2>/dev/null || true)
        if [ -n "$TOKEN_SECRET_NAME" ]; then
            TOKEN=$(kc_local get secret "$TOKEN_SECRET_NAME" -n "$VCLUSTER_ID" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
        else
            # 2. Fallback to status.token (Rancher < 2.14)
            TOKEN=$(kc_local get clusterregistrationtokens.management.cattle.io "$TOKEN_NAME" -n "$VCLUSTER_ID" -o jsonpath='{.status.token}' 2>/dev/null || true)
        fi

        if [ -n "$TOKEN" ]; then break; fi
        sleep 5
    done
    IMPORT_CMD="curl --insecure -sfL ${RANCHER_BASE_URL}/v3/import/${TOKEN}_${VCLUSTER_ID}.yaml | kubectl apply -f -"
fi

# 4. Wait for k3k to generate kubeconfig on host cluster
# Helper function for kubectl to the downstream host cluster via kubeconfig
kc_host() {
    kubectl --kubeconfig="$HOST_KUBECONFIG" "$@"
}

echo "Waiting for k3k pods to generate kubeconfig on host cluster ($HOST_CLUSTER_NAME)..."
SECRET_NAME="k3k-${VCLUSTER_NAME}-kubeconfig"
while ! kc_host get secret "$SECRET_NAME" -n "$VCLUSTER_NAMESPACE" > /dev/null 2>&1; do
    sleep 5
done

# 5. Inject the Agent via the Host Cluster Job
echo "Deploying agent injector job to the host cluster..."
kc_host delete job agent-injector -n "$VCLUSTER_NAMESPACE" 2>/dev/null || true

export VCLUSTER_NAMESPACE INJECTOR_IMAGE SECRET_NAME IMPORT_CMD
envsubst '$VCLUSTER_NAMESPACE $INJECTOR_IMAGE $SECRET_NAME $IMPORT_CMD' < templates/injector/agent-injector-job.yaml | kc_host apply -f -

# 6. Verify Injection Job finishes
echo "Waiting for the agent injection job to complete..."
kc_host wait --for=condition=complete job/agent-injector -n "$VCLUSTER_NAMESPACE" --timeout=120s

echo "Deployment fully complete! Agent is phoning home."
