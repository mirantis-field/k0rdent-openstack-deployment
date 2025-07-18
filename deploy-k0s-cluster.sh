#!/bin/bash

set -e

# Default options
FORCE_TERRAFORM=false

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-terraform)
                FORCE_TERRAFORM=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy k0rdent management cluster on OpenStack"
    echo ""
    echo "Options:"
    echo "  --force-terraform    Force Terraform deployment even if infrastructure exists"
    echo "  --help, -h          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                           # Deploy with infrastructure check"
    echo "  $0 --force-terraform         # Force redeploy infrastructure"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if OpenStack credentials are sourced
check_openstack_credentials() {
    if [[ -z "$OS_AUTH_URL" || -z "$OS_PROJECT_NAME" || -z "$OS_USERNAME" ]]; then
        print_error "OpenStack credentials not found!"
        print_warning "Please source your OpenStack credentials file:"
        print_warning "  source my-openrc.sh"
        exit 1
    fi
    print_success "OpenStack credentials found for project: $OS_PROJECT_NAME"
}

# Check if required tools are installed
check_dependencies() {
    print_status "Checking dependencies..."
    
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform is not installed. Please install Terraform >= 1.0"
        exit 1
    fi
    
    if ! command -v k0sctl &> /dev/null; then
        print_warning "k0sctl not found. Installing k0sctl..."
        curl -sSLf https://get.k0sctl.sh | sudo sh
        if ! command -v k0sctl &> /dev/null; then
            print_error "Failed to install k0sctl"
            exit 1
        fi
    fi
    
    print_success "All dependencies are available"
}

# Check if infrastructure already exists
check_existing_infrastructure() {
    print_status "Checking for existing infrastructure..."
    
    # Initialize terraform if needed
    if [[ ! -d ".terraform" ]]; then
        print_status "Initializing Terraform..."
        terraform init
    fi
    
    # Check if there are resources in the state
    local resource_count
    resource_count=$(terraform state list 2>/dev/null | wc -l)
    
    if [[ $resource_count -gt 0 ]]; then
        print_success "Infrastructure already exists ($resource_count resources found) - skipping Terraform deployment"
        return 0  # Infrastructure exists
    else
        print_status "No existing infrastructure found"
        return 1  # Infrastructure doesn't exist
    fi
}

# Deploy infrastructure with Terraform
deploy_infrastructure() {
    # Check if infrastructure already exists (unless forced)
    if [[ "$FORCE_TERRAFORM" != "true" ]] && check_existing_infrastructure; then
        print_warning "Infrastructure already deployed, skipping Terraform apply"
        print_status "Use --force-terraform to redeploy infrastructure"
        
        # Always ensure k0sctl.yaml is generated from existing infrastructure
        print_status "Ensuring k0sctl.yaml is up to date..."
        terraform apply -auto-approve -target=local_file.k0sctl_config >/dev/null 2>&1
        
        return 0
    fi
    
    if [[ "$FORCE_TERRAFORM" == "true" ]]; then
        print_warning "Force flag detected - redeploying infrastructure"
    fi
    
    print_status "Deploying infrastructure with Terraform..."
    
    if [[ ! -f "terraform.tfvars" ]]; then
        print_warning "terraform.tfvars not found. Using default values from terraform.tfvars.example"
        cp terraform.tfvars.example terraform.tfvars
        print_warning "Please review and customize terraform.tfvars if needed"
    fi
    
    terraform init
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
    
    print_success "Infrastructure deployed successfully"
}

# Deploy k0s cluster
deploy_cluster() {
    print_status "Deploying k0s cluster..."
    
    if [[ ! -f "k0sctl.yaml" ]]; then
        print_error "k0sctl.yaml not found. Please run terraform apply first."
        exit 1
    fi
    
    k0sctl apply --config k0sctl.yaml
    print_success "k0s cluster deployed successfully"
}

# Generate kubeconfig
setup_kubeconfig() {
    print_status "Setting up kubeconfig..."
    
    k0sctl kubeconfig --config k0sctl.yaml > kubeconfig
    export KUBECONFIG=./kubeconfig
    
    print_success "Kubeconfig generated: ./kubeconfig"
    print_status "To use kubectl with this cluster:"
    print_status "  export KUBECONFIG=./kubeconfig"
    print_status "  kubectl get nodes"
}

# Deploy custom CA secret if needed
deploy_custom_ca_secret() {
    print_status "Deploying custom CA secret..."
    
    # Check if openstack_custom_ca is set to true in terraform.tfvars
    if grep -q "openstack_custom_ca.*=.*true" terraform.tfvars 2>/dev/null; then
        print_status "Custom CA enabled - applying secret directly..."
        
        export KUBECONFIG=./kubeconfig
        
        # Apply the custom CA secret directly
        print_status "Creating custom CA secret from manifests/secret-ca-cert.yaml..."
        kubectl apply -f manifests/secret-ca-cert.yaml
        
        # Verify the secret was created
        if kubectl get secret custom-ca-cert -n kube-system >/dev/null 2>&1; then
    print_success "Custom CA secret 'custom-ca-cert' created successfully"
        else
            print_error "Failed to create custom CA secret"
            return 1
        fi
    else
        print_status "Custom CA not enabled - skipping secret deployment"
    fi
}

# Verify cluster
verify_cluster() {
    print_status "Verifying cluster..."
    
    export KUBECONFIG=./kubeconfig
    
    # Wait for nodes to be ready
    print_status "Waiting for nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    # Check CCM status
    print_status "Checking OpenStack Cloud Controller Manager..."
    kubectl get pods -n kube-system -l app=openstack-cloud-controller-manager
    
    # Show cluster status
    print_status "Cluster status:"
    kubectl get nodes -o wide
    
    print_success "Cluster verification completed!"
}

# Main deployment function
main() {
    parse_args "$@"
    
    print_status "Starting k0rdent management cluster deployment..."
    
    check_openstack_credentials
    check_dependencies
    deploy_infrastructure
    deploy_cluster
    setup_kubeconfig
    deploy_custom_ca_secret
    verify_cluster
    
    print_success "🎉 k0rdent management cluster deployed successfully!"
    print_status "Next steps:"
    print_status "  1. Export kubeconfig: export KUBECONFIG=./kubeconfig"
    print_status "  2. Verify cluster: kubectl get nodes"
    print_status "  3. Deploy k0rdent: kubectl apply -f <k0rdent-manifests>"
}

# Run main function
main "$@" 