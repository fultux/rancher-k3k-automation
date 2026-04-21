# 1. Create the Provisioning Cluster Representation in Rancher
# Using kubernetes_manifest (via kubernetes.rancher) to utilize the native 'wait' block for status fields
resource "kubernetes_manifest" "rancher_cluster" {
  provider = kubernetes.rancher

  manifest = {
    apiVersion = "provisioning.cattle.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = var.vcluster_name
      namespace = var.fleet_namespace
      labels = {
        "deploy-metallb" = "allowed"
      }
      annotations = {
        "ui.rancher/k3k-namespace"                       = var.vcluster_namespace
        "ui.rancher/parent-cluster-display"              = var.host_cluster_name
        "ui.rancher/provider"                            = "k3k"
        "rancher.io/imported-cluster-version-management" = "false"
      }
    }
    spec = {}
  }

  wait {
    fields = {
      "status.clusterName" = "*"
    }
  }
}

# 2. Generate Cluster Registration Token dynamically
resource "kubernetes_manifest" "cluster_registration_token" {
  provider = kubernetes.rancher

  manifest = {
    apiVersion = "management.cattle.io/v3"
    kind       = "ClusterRegistrationToken"
    metadata = {
      name = "terraform-token"
      # try() safely handles the Terraform plan phase when the status map doesn't exist yet
      namespace = try(kubernetes_manifest.rancher_cluster.object.status.clusterName, "unknown")
    }
    spec = {
      clusterName = try(kubernetes_manifest.rancher_cluster.object.status.clusterName, "unknown")
    }
  }

  wait {
    fields = {
      "status.insecureCommand" = "*"
    }
  }
}

# 3. Deploy the k3k virtual cluster custom resource to the host cluster
# Using kubernetes_manifest (via kubernetes.host) to deploy the raw CRD
resource "kubernetes_manifest" "k3k_cluster" {
  provider = kubernetes.host

  manifest = {
    apiVersion = "k3k.io/v1beta1"
    kind       = "Cluster"
    metadata = {
      name      = var.vcluster_name
      namespace = var.vcluster_namespace
    }
    spec = {
      mode    = "shared"
      version = var.k3k_version
      servers = 1
      agents  = 1
      persistence = {
        type               = "dynamic"
        storageClassName   = var.storage_class
        storageRequestSize = "3Gi"
      }
    }
  }
}

# 4. Agent Injection Job on the host cluster
# Using kubernetes_job (via kubernetes.host) as it is a core Kubernetes resource
resource "kubernetes_job" "agent_injector" {
  provider = kubernetes.host

  metadata {
    name      = "${var.vcluster_name}-agent-injector"
    namespace = var.vcluster_namespace
  }

  spec {
    backoff_limit = 5

    template {
      metadata {
        name = "injector"
      }
      spec {
        container {
          name    = "injector"
          image   = "rancher/kubectl:v1.28.2" # Pre-packaged with curl and kubectl
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOF
            export KUBECONFIG=/etc/vcluster/kubeconfig.yaml
            echo "Executing Rancher import command against the k3k virtual cluster..."
            ${try(kubernetes_manifest.cluster_registration_token.object.status.insecureCommand, "")}
            EOF
          ]

          volume_mount {
            name       = "kubeconfig"
            mount_path = "/etc/vcluster"
            read_only  = true
          }
        }

        volume {
          name = "kubeconfig"
          secret {
            # This secret is created automatically by the k3k operator on the host cluster.
            secret_name = "k3k-${var.vcluster_name}-kubeconfig"
          }
        }

        restart_policy = "OnFailure"
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_manifest.k3k_cluster,
    kubernetes_manifest.cluster_registration_token
  ]
}
