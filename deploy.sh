#!/bin/bash
# Exit on error
set -e

# --- Configuration & Defaults ---
VCLUSTER_NAME=${VCLUSTER_NAME:-"k3k-automated-test"}
VCLUSTER_NAMESPACE=${VCLUSTER_NAMESPACE:-"tenant2"}
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"host-cl-calio-multus"}
FLEET_NAMESPACE=${FLEET_NAMESPACE:-"fleet-default"}

if [ -z "$RANCHER_SERVER_URL" ] || [ -z "$RANCHER_TOKEN" ]; then
    echo "Error: RANCHER_SERVER_URL and RANCHER_TOKEN environment variables must be set."
    echo "Example: export RANCHER_SERVER_URL=https://rancher.example.com/k8s/clusters/local"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is required but not installed."
    exit 1
fi

if ! command -v rancher &> /dev/null; then
    echo "Error: rancher CLI is required but not installed."
    echo "Download from: https://github.com/rancher/cli/releases"
    exit 1
fi

# Helper function for kubectl to the local rancher cluster
kc_local() {
    kubectl --server="$RANCHER_SERVER_URL" --token="$RANCHER_TOKEN" --insecure-skip-tls-verify=true "$@"
}

echo "--- Deploying k3k cluster via Rancher Fleet ---"

# 1. Sync Fleet to create the placeholder and the pods
echo "Applying Fleet GitRepo definitions..."
kc_local apply -f git-repo.yaml

# 2. Wait for Rancher to process the placeholder
echo "Waiting for Virtual Cluster ID for '$VCLUSTER_NAME'..."
while true; do
    VCLUSTER_ID=$(kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.clusterName}' 2>/dev/null || true)
    if [ -n "$VCLUSTER_ID" ]; then break; fi
    sleep 5
done
echo "Virtual Cluster ID assigned: $VCLUSTER_ID"

# 3. Idempotency Check & Get Import Command
RANCHER_BASE_URL=$(echo "$RANCHER_SERVER_URL" | sed 's|/k8s/clusters/local.*||')
echo "Checking if cluster is already fully provisioned and Active..."

IS_READY=$(kc_local get cluster.provisioning.cattle.io "$VCLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$IS_READY" == "True" ]; then
    echo "Cluster is already Active! Skipping import command generation."
    IMPORT_CMD="echo 'Cluster already Active, no injection needed.'"
else
    echo "Logging into Rancher Local Control Plane..."
    # We explicitly pass '--context local' to skip the dangerous numbered prompt entirely!
    rancher login "$RANCHER_BASE_URL" --token "$RANCHER_TOKEN" --skip-verify --context local
    IMPORT_CMD=$(rancher cluster import "$VCLUSTER_NAME" | grep '^curl')
fi

# 4. Wait for k3k to generate kubeconfig on host cluster
HOST_ID=$(kc_local get cluster.provisioning.cattle.io "$HOST_CLUSTER_NAME" -n "$FLEET_NAMESPACE" -o jsonpath='{.status.clusterName}')

if [ -z "$HOST_ID" ]; then
    echo "Error: Could not find Host Cluster ID for '$HOST_CLUSTER_NAME'."
    exit 1
fi

# Helper function for kubectl to the downstream host cluster via Rancher proxy
kc_host() {
    kubectl --server="$RANCHER_BASE_URL/k8s/clusters/$HOST_ID" --token="$RANCHER_TOKEN" --insecure-skip-tls-verify=true "$@"
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
