output "bastion_floating_ip" {
  description = "Floating IP address of the bastion host for SSH access"
  value       = var.bastion_enabled ? openstack_networking_floatingip_v2.bastion_fip[0].address : null
}

output "load_balancer_floating_ip" {
  description = "Floating IP address of the load balancer for Kubernetes API"
  value       = var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? openstack_networking_floatingip_v2.lb_fip[0].address : null
}

output "controller_floating_ip" {
  description = "Floating IP address of the k0s controller node (single controller mode only)"
  value       = var.controller_count == 1 && !var.load_balancer_enabled ? openstack_networking_floatingip_v2.controller_fip[0].address : null
}

output "controller_private_ips" {
  description = "Private IP addresses of the k0s controller nodes"
  value       = openstack_compute_instance_v2.k0s_controllers[*].network[0].fixed_ip_v4
}

output "worker_floating_ips" {
  description = "Floating IP addresses of the k0s worker nodes (if enabled)"
  value       = var.worker_floating_ips ? openstack_networking_floatingip_v2.worker_fips[*].address : []
}

output "worker_private_ips" {
  description = "Private IP addresses of the k0s worker nodes"
  value       = openstack_compute_instance_v2.k0s_workers[*].network[0].fixed_ip_v4
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = "${path.cwd}/ssh-key"
}

output "ssh_public_key_path" {
  description = "Path to the generated SSH public key"
  value       = "${path.cwd}/ssh-key.pub"
}

output "ssh_command_bastion" {
  description = "SSH command to connect to the bastion host"
  value       = var.bastion_enabled ? "ssh -i ssh-key ${var.bastion_user}@${openstack_networking_floatingip_v2.bastion_fip[0].address}" : null
}

output "ssh_commands_controllers" {
  description = "SSH commands to connect to the controller nodes via bastion"
  value       = var.bastion_enabled ? [
    for i, ip in openstack_compute_instance_v2.k0s_controllers[*].network[0].fixed_ip_v4 : 
    "ssh -i ssh-key -J ${var.bastion_user}@${openstack_networking_floatingip_v2.bastion_fip[0].address} ubuntu@${ip}"
  ] : [
    var.controller_count == 1 && !var.load_balancer_enabled ? 
    "ssh -i ssh-key ubuntu@${openstack_networking_floatingip_v2.controller_fip[0].address}" : 
    "ssh -i ssh-key ubuntu@${openstack_compute_instance_v2.k0s_controllers[0].network[0].fixed_ip_v4}"
  ]
}

output "ssh_commands_workers" {
  description = "SSH commands to connect to the worker nodes"
  value       = var.worker_floating_ips ? [
    for ip in openstack_networking_floatingip_v2.worker_fips[*].address : "ssh -i ssh-key ubuntu@${ip}"
  ] : (
    var.bastion_enabled ? [
      for i, ip in openstack_compute_instance_v2.k0s_workers[*].network[0].fixed_ip_v4 : 
      "ssh -i ssh-key -J ${var.bastion_user}@${openstack_networking_floatingip_v2.bastion_fip[0].address} ubuntu@${ip}"
    ] : [
      for i, ip in openstack_compute_instance_v2.k0s_workers[*].network[0].fixed_ip_v4 : 
      var.controller_count == 1 && !var.load_balancer_enabled ? 
      "ssh -i ssh-key -J ubuntu@${openstack_networking_floatingip_v2.controller_fip[0].address} ubuntu@${ip}" :
      "ssh -i ssh-key ubuntu@${ip}"
    ]
  )
}

output "k0sctl_config_path" {
  description = "Path to the generated k0sctl configuration file"
  value       = "${path.cwd}/k0sctl.yaml"
}

output "cluster_info" {
  description = "Important cluster information"
  value = {
    cluster_name         = local.full_cluster_name
    controller_count     = var.controller_count
    controller_ips       = openstack_compute_instance_v2.k0s_controllers[*].network[0].fixed_ip_v4
    bastion_ip          = var.bastion_enabled ? openstack_networking_floatingip_v2.bastion_fip[0].address : null
    api_endpoint        = var.load_balancer_enabled && var.controller_count > 1 ? (
      var.load_balancer_floating_ip_enabled ?
        "https://${openstack_networking_floatingip_v2.lb_fip[0].address}:6443" :
        "https://${openstack_lb_loadbalancer_v2.k0s_api_lb[0].vip_address}:6443"
    ) : (
      var.controller_count == 1 && !var.load_balancer_enabled ? (
        "https://${openstack_networking_floatingip_v2.controller_fip[0].address}:6443"
      ) : "https://${openstack_compute_instance_v2.k0s_controllers[0].network[0].fixed_ip_v4}:6443"
    )
    load_balancer_ip    = var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? openstack_networking_floatingip_v2.lb_fip[0].address : null
    network_id          = local.network_id
    subnet_id           = local.subnet_id
    external_network    = var.external_network_name
  }
}

output "deployment_commands" {
  description = "Commands to deploy k0s cluster using k0sctl"
  value = [
    "# 1. Ensure OpenStack credentials are set:",
    "source my-openrc.sh",
    "",
    "# 2. Install k0sctl (if not already installed):",
    "curl -sSLf https://get.k0sctl.sh | sudo sh",
    "",
    "# 3. Deploy the cluster:",
    "k0sctl apply --config k0sctl.yaml",
    "",
    "# 4. Get kubeconfig:",
    "k0sctl kubeconfig --config k0sctl.yaml > kubeconfig",
    "export KUBECONFIG=./kubeconfig",
    "",
    "# 5. Verify cluster:",
    "kubectl get nodes",
    "kubectl get pods -A",
    "",
    "# 6. Check OpenStack CCM:",
    "kubectl get pods -n kube-system -l app=openstack-cloud-controller-manager"
  ]
}

output "openstack_resources" {
  description = "OpenStack resource IDs for reference"
  value = {
    network_id = local.network_id
    subnet_id  = local.subnet_id
    router_id  = !var.use_existing_network ? openstack_networking_router_v2.k0s_router[0].id : null
    security_group_id = openstack_networking_secgroup_v2.k0s_secgroup.id
    using_existing_network = var.use_existing_network
    existing_network_name = var.use_existing_network ? var.existing_network_name : null
    existing_subnet_name = var.use_existing_network ? var.existing_subnet_name : null
  }
}

# Output for k0rdent OpenStack integration
output "k0rdent_openstack_config" {
  description = "OpenStack configuration for k0rdent"
  value = {
    auth_url                      = var.openstack_auth_url != "" ? var.openstack_auth_url : null
    region                       = var.openstack_region
    application_credential_id    = openstack_identity_application_credential_v3.ccm_credential.id
    application_credential_secret = openstack_identity_application_credential_v3.ccm_credential.secret
    interface                    = "public"
    identity_api_version         = "3"
    auth_type                    = "v3applicationcredential"
  }
  sensitive = true
}

# Output for OpenStack insecure flag
output "openstack_insecure" {
  description = "Whether to skip TLS certificate verification for OpenStack API calls"
  value       = var.openstack_insecure
}

# Output for OpenStack custom CA flag
output "openstack_custom_ca" {
  description = "Whether to use custom CA certificate for OpenStack API calls"
  value       = var.openstack_custom_ca
} 