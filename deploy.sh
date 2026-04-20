#!/bin/bash
# Exit on error
set -x
set -e

# --- Configuration & Defaults ---
VCLUSTER_NAME=${VCLUSTER_NAME:-"k3k-fleet-test"}
VCLUSTER_NAMESPACE=${VCLUSTER_NAMESPACE:-"tenant2"}
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"kubevip"}
FLEET_NAMESPACE=${FLEET_NAMESPACE:-"fleet-default"}

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
    # Get the bearer token for rancher CLI using kubectl
    RANCHER_TOKEN=$(kc_local get secret $(kc_local get serviceaccount default -n default -o jsonpath='{.secrets[0].name}') -n default -o jsonpath='{.data.token}' | base64 --decode || echo "")

    if [ -z "$RANCHER_TOKEN" ]; then
        echo "Could not find a token to log in with rancher cli, attempting to extract from kubeconfig"
        RANCHER_TOKEN=$(kc_local config view --minify -o jsonpath='{.users[0].user.token}')
    fi

    if [ -z "$RANCHER_TOKEN" ]; then
         echo "Error: Could not extract a token to log into the Rancher CLI to generate the import command."
         exit 1
    fi

    rancher login "$RANCHER_BASE_URL" --token "$RANCHER_TOKEN" --skip-verify --context local
    IMPORT_CMD=$(rancher cluster import "$VCLUSTER_NAME" | grep '^curl')
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
