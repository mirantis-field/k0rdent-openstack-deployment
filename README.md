# k0rdent Management Cluster on OpenStack

This Terraform configuration creates a production-ready, highly available k0s Kubernetes cluster on OpenStack for k0rdent management purposes. The cluster supports both single-controller and multi-controller HA deployments with integrated load balancing, bastion host access, and OpenStack Cloud Controller Manager.

## Architecture

### High Availability Setup (Default: 3 Controllers + Load Balancer)
- **3 Controller Nodes**: HA k0s control plane with etcd clustering
- **Load Balancer**: OpenStack Octavia LB distributing traffic across all k0s ports
- **2 Worker Nodes**: Run workloads and join the cluster automatically  
- **Bastion Host**: Secure SSH access point 
- **Networking**: Dedicated network with router and security groups
- **Storage**: Boot-from-volume with configurable storage backends
- **Cloud Integration**: OpenStack CCM for native cloud services

### Single Controller Setup (Optional)
- **1 Controller Node**: Single k0s control plane with direct floating IP
- **Worker Nodes**: Configurable number of worker nodes
- **No Load Balancer**: Direct access to controller (suitable for development)

## Load Balancer Configuration

The load balancer is automatically configured when `load_balancer_enabled = true` and `controller_count > 1`:

### Supported Ports (k0s HA Requirements)
- **6443**: Kubernetes API Server
- **8132**: Konnectivity (kubelet tunnel communication)  
- **9443**: Controller Join API (for adding new controllers)

### Features
- **Health Monitoring**: TCP health checks for all services
- **Round Robin**: Equal distribution across healthy controllers
- **Floating IP**: External access via dedicated floating IP
- **Security Groups**: Automatic external access rules for LB ports

### Configuration Example
```hcl
# Enable HA with load balancer (default)
load_balancer_enabled = true
controller_count = 3

# Single controller setup (no LB)
load_balancer_enabled = false  
controller_count = 1
```

## Bastion Host Configuration

The bastion host provides secure SSH access to the cluster:

### Features
- **Secure**: Only SSH port (22) exposed to internet
- **Jump Host**: All cluster access goes through bastion
- **Dedicated Security Group**: Isolated from cluster security group
- **Automatic**: Configured automatically when `bastion_enabled = true`

### SSH Access Patterns

```bash
# Direct access to bastion
ssh -i ssh-key ubuntu@<bastion-floating-ip>

# Jump to controller nodes via bastion
ssh -i ssh-key -J ubuntu@<bastion-ip> ubuntu@<controller-private-ip>

# Jump to worker nodes via bastion  
ssh -i ssh-key -J ubuntu@<bastion-ip> ubuntu@<worker-private-ip>
```

### Bastion Configuration Options
```hcl
# Bastion settings
bastion_enabled = true                         # Enable/disable bastion
bastion_flavor = "m1.small"                     # Minimal flavor for bastion
bastion_image_name = "ubuntu-22.04"            # Ubuntu image
bastion_user = "ubuntu"                        # SSH user for ubuntu
```

## Prerequisites

1. **OpenStack Environment**: Access to an OpenStack cloud with:
   - Compute service (Nova)
   - Network service (Neutron) 
   - Image service (Glance)
   - Identity service (Keystone)
   - Block Storage service (Cinder)
   - Load Balancer service (Octavia) - for HA clusters
   - Application Credentials support

2. **Terraform**: Version >= 1.0 installed

3. **k0sctl**: k0s cluster management tool (auto-installed by deployment script)

4. **OpenStack Credentials**: OpenStack RC file with your credentials

5. **Images**: Ubuntu 22.04 images available

## Configuration Variables

### Core Settings
| Variable | Description | Default |
|----------|-------------|---------|
| `resource_prefix` | Prefix for all resource names | `mirantis` |
| `cluster_name` | Base cluster name (will be prefixed) | `k0rdent` |
| `controller_count` | Number of controllers (1-3) | `3` |
| `worker_count` | Number of worker nodes | `2` |

### High Availability
| Variable | Description | Default |
|----------|-------------|---------|
| `load_balancer_enabled` | Enable load balancer for HA | `true` |
| `bastion_enabled` | Enable bastion host for security | `true` |

### Instance Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `control_plane_flavor` | Flavor for control plane nodes | `m1.large` |
| `worker_flavor` | Flavor for worker nodes | `m1.medium` |
| `bastion_flavor` | Flavor for bastion host | `m1.tiny` |
| `volume_size` | Boot volume size in GB | `20` |
| `volume_type` | Volume type (empty for default) | `""` |

### Networking
| Variable | Description | Default |
|----------|-------------|---------|
| `external_network_name` | External network for floating IPs | `public` |
| `network_cidr` | Cluster network CIDR | `10.0.1.0/24` |
| `pod_cidr` | Kubernetes pod CIDR | `10.244.0.0/16` |
| `service_cidr` | Kubernetes service CIDR | `10.96.0.0/12` |

### OpenStack Integration
| Variable | Description | Default |
|----------|-------------|---------|
| `openstack_auth_url` | OpenStack auth URL (from env if empty) | `""` |
| `openstack_region` | OpenStack region name | `RegionOne` |
| `openstack_services_ip` | IP for OpenStack services DNS | `172.18.172.56` |

## Quick Start

### Automated Deployment (Recommended)

```bash
# 1. Copy and customize configuration
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# 2. Source OpenStack credentials  
source your-openrc.sh

# 3. Run automated deployment
./deploy-k0s-cluster.sh

# 4. Deploy k0rdent and configure OpenStack credentials for CAPO
./deploy-k0rdent.sh
```

### Manual Deployment

```bash
# 1. Source credentials
source your-openrc.sh

# 2. Initialize and deploy infrastructure
terraform init
terraform apply

# 3. Deploy k0s cluster
k0sctl apply --config k0sctl.yaml

# 4. Get kubeconfig
k0sctl kubeconfig --config k0sctl.yaml > kubeconfig
export KUBECONFIG=./kubeconfig
```

## Architecture Diagrams

### High Availability Setup
```
                        ┌─────────────────┐
                        │  Load Balancer  │
                        │  (Octavia LB)   │
                        │                 │
                        │ Ports: 6443     │
                        │        8132     │
                        │        9443     │
                        └─────────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │                    │                    │
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │  Controller 1    │ │  Controller 2    │ │  Controller 3    │
   │                  │ │                  │ │                  │
   │ - k0s controller │ │ - k0s controller │ │ - k0s controller │
   └──────────────────┘ └──────────────────┘ └──────────────────┘
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 │
                       ┌──────────────────┐
                       │  Cluster Network │
                       │ e.g 10.0.1.0/24  │
                       └──────────────────┘
                                 │
        ┌─────────────────┐      │      ┌─────────────────┐
        │    Worker 1     │──────┼──────│    Worker 2     │
        │                 │      │      │                 │
        │ - k0s worker    │      │      │ - k0s worker    │
        └─────────────────┘      │      └─────────────────┘
                                 │
                        ┌─────────────────┐
                        │   Bastion Host  │
                        │    (Ubuntu)     │
                        │   SSH Gateway   │
                        │    (optional)   │
                        └─────────────────┘
```

### Network Security Model (optional)
```
Internet
    │
    │ (SSH: 22)
    ▼
┌────────────────────┐
│    Bastion Host    │ ◄─── Floating IP
│ (Ubuntu/m1.small)  │
└────────────────────┘
    │
    │ (SSH Tunnel)
    ▼
┌─────────────────┐      ┌───────────────────┐
│  Load Balancer  │ ◄────┤ Controller/Worker │
│ (6443/8132/9443)│      │       Nodes       │ 
└─────────────────┘      │   (Private IPs)   │
    ▲                    └───────────────────┘
    │ (API Access)
    │ Floating IP
Internet
```

## Boot-from-Volume Configuration

All VMs use persistent block storage:

### Volume Features
- **Persistent**: Data survives compute node failures
- **Configurable**: Choose storage backend via `volume_type`
- **Efficient**: 20GB default size, customizable
- **Automatic**: Volumes created and attached automatically

### Storage Backend Examples
```hcl
# Default storage
volume_type = ""

# Pure Storage backend
volume_type = "purestorage-backend"

# SSD storage  
volume_type = "ssd"
```

## Security Configuration

### Security Groups
- **Cluster Security Group**: Controls traffic between cluster components
- **Bastion Security Group**: Isolated SSH access for bastion
- **Load Balancer Rules**: External access only for LB when HA enabled

### Port Access Matrix
| Port | Source | Purpose | Security Group |
|------|--------|---------|----------------|
| 22 | Internet | SSH to bastion | Bastion |
| 22 | Bastion | SSH to cluster nodes | Cluster |
| 6443 | Internet | Kubernetes API (via LB) | Cluster |
| 8132 | Internet | Konnectivity (via LB) | Cluster |
| 9443 | Internet | Controller Join (via LB) | Cluster |
| 10250 | Cluster | Kubelet API | Cluster |
| 8472 | Cluster | Cilium VXLAN | Cluster |

### Authentication
- **Application Credentials**: Secure CCM authentication
- **Generated SSH Keys**: Automatic key pair creation
- **No Passwords**: Password-less authentication throughout

## OpenStack Cloud Controller Manager

### Version & Features
- **Version**: 2.32.0 (latest stable)
- **LoadBalancer Services**: Automatic Octavia load balancer creation
- **Persistent Volumes**: Cinder block storage integration
- **Node Management**: Automatic OpenStack metadata labeling
- **Network Integration**: Native Neutron networking

### CCM Configuration
```yaml
# Automatic configuration in k0sctl.yaml
enabledControllers:
  - cloud-node
  - cloud-node-lifecycle  
  - route
  - service

# Authentication via application credentials
cloudConfig:
  global:
    application-credential-id: <auto-generated>
    application-credential-secret: <auto-generated>
```

## k0rdent Enterprise Integration

The cluster includes k0rdent enterprise v1.1.0-rc1 for cluster lifecycle management:

### Enhanced Deployment with Custom CA Support
```bash
# k0rdent enterprise is automatically installed via the enhanced deploy script
# The script now includes:
# - Automatic k0rdent enterprise installation via Helm
# - Custom CA certificate configuration for OpenStack endpoints
# - CAPO integration with custom CA certificates

# Run the enhanced deployment script
./deploy-k0rdent-with-openstack-creds.sh

# After cluster deployment, check k0rdent enterprise status
kubectl get pods -n kcm-system
```

### Custom CA Certificate Support
The enhanced script automatically configures:
- Custom CA certificates for secure OpenStack communication
- CAPO (ClusterAPI OpenStack) integration with custom CA
- Proper CA certificate mounting in CAPO controllers
- Template configuration with CA support for cluster deployments

### Configuration
Custom CA certificates are read from `manifests/secret-ca-cert.yaml` and automatically:
- Applied to the kube-system namespace for OpenStack CCM
- Configured in CAPO controllers via volume mounts
- Included in k0rdent enterprise template configurations
- Set up for secure OpenStack endpoint communication

## Troubleshooting

### Check Load Balancer Status
```bash
# OpenStack CLI
openstack loadbalancer list
openstack loadbalancer show <lb-id>

# Terraform outputs
terraform output load_balancer_floating_ip
```

### Bastion Access Issues
```bash
# Test bastion connectivity
ssh -i ssh-key ubuntu@$(terraform output bastion_floating_ip)

# Check bastion security group
openstack security group list | grep bastion
```

### Konnectivity Issues
```bash
# Check Konnectivity agents
kubectl get pods -n kube-system | grep konnectivity

# Verify load balancer ports
kubectl get endpoints -n kube-system konnectivity-server
```

### CCM Authentication Issues
```bash
# Check OpenStack credentials
kubectl get secret -n kube-system cloud-config -o yaml

# Test application credentials
openstack server list --os-application-credential-id <id>
```

## Cleanup

```bash
# Reset k0s cluster first
k0sctl reset --config k0sctl.yaml

# Destroy infrastructure
terraform destroy

# Clean up local files
rm -f ssh-key ssh-key.pub kubeconfig k0sctl.yaml
```

## Support & Documentation

- **k0s**: [k0s documentation](https://docs.k0sproject.io/)
- **k0sctl**: [k0sctl repository](https://github.com/k0sproject/k0sctl)
- **OpenStack CCM**: [cloud-provider-openstack](https://github.com/kubernetes/cloud-provider-openstack)
- **k0rdent**: [k0rdent documentation](https://github.com/k0rdent/k0rdent)
- **Terraform OpenStack**: [terraform-provider-openstack](https://registry.terraform.io/providers/terraform-provider-openstack/openstack)

## Recent Updates

### Load Balancer Enhancement
- **Complete k0s Port Support**: Added Konnectivity (8132) and Controller Join (9443) ports
- **Health Monitoring**: TCP health checks for all services  
- **Security Integration**: Automatic external access rules for LB ports
- **HA Compliance**: Full compliance with k0s HA requirements

### Bastion Host Implementation  
- **SSH Tunneling**: Secure access to all cluster nodes
- **Security Isolation**: Dedicated security group for bastion
- **Configurable**: Enable/disable and customize bastion settings

### Boot-from-Volume Implementation
- **Persistent Storage**: All VMs use Cinder volumes
- **Storage Backend Flexibility**: Configurable volume types
- **Data Protection**: Volumes survive compute node failures
- **Performance Options**: Support for different storage backends 