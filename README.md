# Rancher k3k Automation (Kustomize Branch)

This repository provides an automated workflow using **Rancher Fleet**, **Kustomize**, and custom scripts to deploy [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) virtual clusters and seamlessly integrate them into a Rancher management server.

## Architecture

The deployment relies on two distinct deployment targets managed by Fleet:
1. **Host Cluster (`manifests/host/`)**: The downstream cluster running the `k3k` operator. We deploy the `k3k.io/v1beta1` Cluster object here.
2. **Local Management Cluster (`manifests/rancher/`)**: Where Rancher itself is installed. We create a `provisioning.cattle.io/v1` Cluster object here.

## Directory Structure

* `base/`: Contains the raw Kustomize base manifests for the host cluster, rancher cluster, and fleet definitions.
* `overlays/`: Contains specific deployment configurations (e.g., `dev-cluster`). This replaces the need for `envsubst` environment variables.
* `manifests/` & `fleet/`: Generated automatically by Kustomize.
* `scripts/`: Contains `render.sh` to generate the manifests, and `deploy.sh`/`delete.sh` for lifecycle management.

## Prerequisites

* A Rancher Management Server with **Continuous Delivery (Fleet)** enabled.
* A downstream Kubernetes cluster registered in Rancher with the `k3k` operator installed.
* `kubectl` installed on the machine executing the automation scripts.

## Environment Variables

Export the following variables before running the scripts:

```bash
export RANCHER_KUBECONFIG="/path/to/rancher-local.yaml"
export HOST_KUBECONFIG="/path/to/downstream-host.yaml"
```

## Getting Started

### 1. Configure the Overlay

Instead of editing raw files, create or modify a Kustomize overlay (e.g., `overlays/dev-cluster`):

*   **`overlays/dev-cluster/host/patch.yaml`**: Update server count, versions, etc.
*   **`overlays/dev-cluster/rancher/patch.yaml`**: Update annotations to point to your specific host cluster ID.

### 2. Render the Manifests

Use the provided render script to build the Kustomize templates into the static directories Fleet monitors:

```bash
./scripts/render.sh dev-cluster
```

This will write the final `k3k.yaml`, `cluster.yaml`, and `git-repo.yaml` files into the `manifests/` and `fleet/` directories at the root of the project.

### 3. Deploy the Virtual Cluster

**Important:** Because Fleet pulls from Git, you MUST commit and push the rendered `manifests/` and `fleet/` directories to your repository before proceeding.

Once pushed, run the deployment script. It will apply the `git-repo.yaml` definition, extract your cluster name from the rendered files, wait for Rancher, and inject the registration command into the host cluster.

```bash
./scripts/deploy.sh
```

### 4. Delete the Virtual Cluster

To cleanly tear down the environment—including Fleet definitions, k3k virtual cluster resources, Rancher provisioning cluster mappings, and dynamically generated tokens—run:

```bash
./scripts/delete.sh
```