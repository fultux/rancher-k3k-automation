#!/bin/bash
#Uncomment to enable debug
#set -x
set -e # Exit on error

# Change working directory to the project root
cd "$(dirname "$0")/.."

# --- Configuration & Defaults ---
# Dynamically extract values from the rendered manifests
VCLUSTER_NAME=$(grep -A 2 'kind: Cluster' manifests/host/k3k.yaml | grep 'name:' | head -n 1 | awk '{print $2}')
VCLUSTER_NAMESPACE=$(grep -A 5 'kind: Cluster' manifests/host/k3k.yaml | grep 'namespace:' | head -n 1 | awk '{print $2}')
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"kubevip"}
FLEET_NAMESPACE=${FLEET_NAMESPACE:-"fleet-default"}

if [ -z "$VCLUSTER_NAME" ] || [ -z "$VCLUSTER_NAMESPACE" ]; then
    echo "Error: Could not extract cluster name or namespace from manifests/host/k3k.yaml. Did you run render.sh?"
    exit 1
fi

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

echo "--- Deploying k3k cluster via Rancher Fleet ---"

# 1. Sync Fleet to create the placeholder and the pods
echo "Applying Fleet GitRepo definitions..."
kc_local apply -f fleet/git-repo.yaml

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
    TOKEN_NAME=$(kc_local get clusterregistrationtoken -n "$VCLUSTER_ID" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$TOKEN_NAME" ]; then
        TOKEN_NAME="token-$(date +%s)"
        echo "Creating ClusterRegistrationToken $TOKEN_NAME..."
        cat <<EOF | kc_local create -f -
apiVersion: management.cattle.io/v3
kind: ClusterRegistrationToken
metadata:
  name: $TOKEN_NAME
  namespace: $VCLUSTER_ID
spec:
  clusterName: $VCLUSTER_ID
EOF
    fi

    # Wait for the cluster registration token to be generated
    while true; do
        IMPORT_CMD=$(kc_local get ClusterRegistrationToken.management.cattle.io "$TOKEN_NAME" -n "$VCLUSTER_ID" -o jsonpath='{.status.insecureCommand}' 2>/dev/null || true)
        if [ -n "$IMPORT_CMD" ]; then break; fi
        sleep 5
    done
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

cat <<EOF | kc_host apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: agent-injector
  namespace: $VCLUSTER_NAMESPACE
spec:
  backoffLimit: 3
  template:
    spec:
      containers:
      - name: injector
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            apk add --no-cache curl
            curl -sLO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
            chmod +x kubectl && mv kubectl /usr/local/bin/
            export KUBECONFIG=/etc/vcluster/kubeconfig.yaml
            echo "Executing import command..."
            $IMPORT_CMD
        volumeMounts:
        - name: kubeconfig
          mountPath: /etc/vcluster
          readOnly: true
      volumes:
      - name: kubeconfig
        secret:
          secretName: $SECRET_NAME
      restartPolicy: OnFailure
EOF

# 6. Verify Injection Job finishes
echo "Waiting for the agent injection job to complete..."
kc_host wait --for=condition=complete job/agent-injector -n "$VCLUSTER_NAMESPACE" --timeout=120s

echo "Deployment fully complete! Agent is phoning home."
