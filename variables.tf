variable "resource_prefix" {
  description = "Prefix for all resource names (e.g., 'poc', 'dev', 'prod')"
  type        = string
  default     = "poc"
}

variable "cluster_name" {
  description = "Name of the k0s cluster (will be prefixed with resource_prefix)"
  type        = string
  default     = "k0rdent"
}

variable "image_name" {
  description = "Name of the OpenStack image to use (should be in raw format)"
  type        = string
  default     = "ubuntu-22.04"
}

variable "image_id" {
  description = "ID of the OpenStack image to use (takes precedence over image_name if specified)"
  type        = string
  default     = ""
}

variable "control_plane_flavor" {
  description = "Name of the OpenStack flavor to use for control plane nodes"
  type        = string
  default     = "m1.large"
}

variable "worker_flavor" {
  description = "Name of the OpenStack flavor to use for worker nodes"
  type        = string
  default     = "m1.medium"
}

variable "external_network_name" {
  description = "Name of the external network for floating IPs"
  type        = string
  default     = "public"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 10
    error_message = "Worker count must be between 0 and 10."
  }
}

variable "controller_count" {
  description = "Number of controller nodes (1-3 supported)"
  type        = number
  default     = 1
  validation {
    condition     = var.controller_count >= 1 && var.controller_count <= 3
    error_message = "Controller count must be between 1 and 3."
  }
}

variable "volume_size" {
  description = "Size of the boot volume in GB"
  type        = number
  default     = 20
}

variable "volume_type" {
  description = "Volume type for boot volumes (leave empty for default volume type)"
  type        = string
  default     = ""
}

variable "network_cidr" {
  description = "CIDR block for the cluster network"
  type        = string
  default     = "10.0.1.0/24"
}

variable "dns_nameservers" {
  description = "DNS nameservers for the cluster subnet. Use OpenStack internal DNS servers (e.g. ['10.130.18.1', '10.130.18.2']) to resolve OpenStack service hostnames, or public DNS servers (e.g. ['8.8.8.8', '8.8.4.4']) for external-only resolution"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "pod_cidr" {
  description = "CIDR block for Kubernetes pods"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.96.0.0/12"
}

variable "openstack_auth_url" {
  description = "OpenStack authentication URL"
  type        = string
  default     = ""
}

variable "openstack_region" {
  description = "OpenStack region name"
  type        = string
  default     = "RegionOne"
}

variable "openstack_services_ip" {
  description = "IP address of OpenStack services (keystone, nova, neutron, etc.)"
  type        = string
  default     = "172.18.172.56"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = list(string)
  default     = ["k0s", "k0rdent", "management"]
}

variable "worker_floating_ips" {
  description = "Whether to assign floating IPs to worker nodes (typically not needed)"
  type        = bool
  default     = false
}

variable "bastion_flavor" {
  description = "Name of the OpenStack flavor to use for bastion host"
  type        = string
  default     = "m1.small"
}

variable "bastion_enabled" {
  description = "Whether to create a bastion host for SSH access"
  type        = bool
  default     = true
}

variable "load_balancer_enabled" {
  description = "Whether to create a load balancer for control plane HA"
  type        = bool
  default     = true
}

variable "load_balancer_floating_ip_enabled" {
  description = "Whether to assign a floating IP to the load balancer (if false, load balancer will be internal-only)"
  type        = bool
  default     = true
}

variable "load_balancer_vip_subnet_id" {
  description = "Subnet ID for load balancer VIP (leave empty to use cluster subnet)"
  type        = string
  default     = ""
}

variable "bastion_image_name" {
  description = "Name of the OpenStack image to use for bastion host (CirrOS recommended)"
  type        = string
  default     = "cirros-0.6.2-x86_64-disk"
}

variable "bastion_image_id" {
  description = "ID of the OpenStack image to use for bastion host (takes precedence over bastion_image_name if specified)"
  type        = string
  default     = ""
}

variable "bastion_user" {
  description = "SSH user for bastion host (cirros for CirrOS, ubuntu for Ubuntu)"
  type        = string
  default     = "cirros"
}

# OpenStack SSL/TLS Configuration
variable "openstack_insecure" {
  description = "Skip TLS certificate verification for OpenStack API calls (useful for self-signed certificates)"
  type        = bool
  default     = false
}

variable "openstack_custom_ca" {
  description = "Enable custom CA certificate for OpenStack API calls (CCM and CSI)"
  type        = bool
  default     = false
}

# Existing network configuration
variable "use_existing_network" {
  description = "Whether to use an existing network instead of creating a new one"
  type        = bool
  default     = false
}

variable "existing_network_name" {
  description = "Name of the existing network to use (only used when use_existing_network is true)"
  type        = string
  default     = ""
}

variable "existing_subnet_name" {
  description = "Name of the existing subnet to use (only used when use_existing_network is true)"
  type        = string
  default     = ""
} 