# Rancher k3k Automation

This repository provides an automated workflow using **Rancher Fleet** and custom scripts to deploy [k3k](https://github.com/rancher/k3k) (Kubernetes in Kubernetes) virtual clusters and seamlessly integrate them into a Rancher management server.

## Architecture

The deployment relies on two distinct deployment targets managed by Fleet:
1. **Host Cluster (`render: host`)**: The downstream cluster running the `k3k` operator. We deploy the `k3k.io/v1beta1` Cluster object here to physically create the virtual control plane and worker nodes.
2. **Local Management Cluster (`render: rancher`)**: Where Rancher itself is installed. We create a `provisioning.cattle.io/v1` Cluster object here. This tells Rancher to track the k3k virtual cluster and provides the necessary metadata for the Rancher UI.

## Repository Structure

* `manifests/fleet/`: Contains `git-repo.yaml`, the core Fleet configuration defining the Git repositories, paths, and deployment targets.
* `charts/k3k-cluster/`: Helm chart rendered by Fleet. `values.yaml` holds the defaults; `fleet.yaml` selects the `host` (k3k Cluster) or `rancher` (provisioning Cluster) object per target cluster.
* `templates/injector/`: Manifests rendered with `envsubst` by `deploy.sh` (agent injector Job, ClusterRegistrationToken).
* `scripts/`: Contains the `deploy.sh` and `delete.sh` automation scripts for lifecycle management and automated Rancher importation.

## Prerequisites

* A Rancher Management Server with **Continuous Delivery (Fleet)** enabled.
* A downstream Kubernetes cluster registered in Rancher (the "host cluster") with the `k3k` operator installed.
* A valid StorageClass on the host cluster (e.g., `local-path`, `standard`, `harvester`).
* `kubectl` installed on the machine executing the automation scripts.

## Environment Variables

The automation scripts require explicit paths to your `kubeconfig` files to interact securely with both the Rancher management cluster and the downstream host cluster. You must export the following variables before running the scripts:

```bash
export RANCHER_KUBECONFIG="/path/to/rancher-local.yaml"
export HOST_KUBECONFIG="/path/to/downstream-host.yaml"
```

## Getting Started

### 1. Configure the Manifests

Update the provided examples to match your environment:

Edit `charts/k3k-cluster/values.yaml`:
* `name` and `namespace`: the virtual cluster name and its tenant namespace (e.g., `tenant1`). Both objects use them, so they cannot drift apart.
* `k3k.version` and `k3k.persistence.storageClassName`: the k3s version and a storage class available on your host cluster. An empty `storageClassName` uses the host cluster's default class.
* `rancher.parentCluster` and `rancher.parentClusterDisplay`: the Rancher Cluster ID (e.g., `c-m-dmj78vrr`) and display name of your host cluster. `parentCluster` ships as `REPLACE_WITH_HOST_CLUSTER_ID` and must be set.

In `charts/k3k-cluster/fleet.yaml`, set each `clusterName` to the Fleet cluster name of the management cluster (`local`) and of your host cluster.

### 2. Update the GitRepo Definitions

Edit `manifests/fleet/git-repo.yaml`:
* Change `spec.repo` in both definitions to the URL of your fork or copy of this repository.
* Ensure the branch matches your working branch.
* In the `k3k-automation-host` resource, update the `targets[0].clusterName` (also in `charts/k3k-cluster/fleet.yaml`) to match the exact Fleet cluster name of your downstream host cluster.

### 3. Deploy the Virtual Cluster

Once your manifests and fleet configurations are ready, use the deployment script. The script automatically applies the GitRepo definitions, waits for Rancher to process the cluster representation, dynamically generates an import token, and securely injects the registration command into the host cluster so the k3k virtual cluster can automatically phone home to Rancher.

```bash
./scripts/deploy.sh
```

Once complete, the Rancher UI and k3k operator will sync up, and the virtual cluster will securely register itself and appear as "Active" in the Rancher Dashboard.

### 4. Delete the Virtual Cluster

To cleanly tear down the environment—including Fleet definitions, k3k virtual cluster resources, Rancher provisioning cluster mappings, and dynamically generated tokens—run the deletion script:

```bash
./scripts/delete.sh
```
