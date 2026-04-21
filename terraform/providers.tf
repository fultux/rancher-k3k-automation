terraform {
  required_version = ">= 1.3.0"

  required_providers {
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 4.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25.0"
    }
  }
}

# Kubernetes provider for the Rancher management cluster
provider "kubernetes" {
  alias       = "rancher"
  config_path = var.rancher_kubeconfig
}

# Kubernetes provider for the downstream host cluster
provider "kubernetes" {
  alias       = "host"
  config_path = var.host_kubeconfig
}

# Rancher2 provider for native Rancher API interactions
provider "rancher2" {
  api_url   = var.rancher_api_url
  token_key = var.rancher_token_key
  insecure  = true
}
