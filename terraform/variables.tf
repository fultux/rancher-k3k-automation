variable "rancher_api_url" {
  type        = string
  description = "Rancher API URL (e.g., https://rancher.example.com)"
  default     = ""
}

variable "rancher_token_key" {
  type        = string
  description = "Rancher API Bearer Token (e.g., token-xxxxx:yyyyyyyyyyy)"
  sensitive   = true
  default     = ""
}

variable "rancher_kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file for the Rancher management cluster"
  default     = "~/.kube/config"
}

variable "host_kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file for the downstream host cluster"
  default     = "~/.kube/config"
}

variable "vcluster_name" {
  type        = string
  description = "Name of the k3k virtual cluster"
  default     = "k3k-terraform-test"
}

variable "vcluster_namespace" {
  type        = string
  description = "Namespace on the host cluster where k3k will be deployed"
  default     = "tenant2"
}

variable "host_cluster_name" {
  type        = string
  description = "Name of the downstream host cluster in Rancher (display name)"
  default     = "kubevip"
}

variable "fleet_namespace" {
  type        = string
  description = "Namespace in Rancher for cluster provisioning"
  default     = "fleet-default"
}

variable "k3k_version" {
  type        = string
  description = "Kubernetes version for the k3k virtual cluster"
  default     = "v1.33.10-k3s1"
}

variable "storage_class" {
  type        = string
  description = "StorageClass name to use for k3k persistence"
  default     = "harvester"
}
