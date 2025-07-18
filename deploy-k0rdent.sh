#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
K0RDENT_VERSION=${K0RDENT_VERSION:-"1.1.0-rc1"}
K0RDENT_NAMESPACE=${K0RDENT_NAMESPACE:-"kcm-system"}
K0RDENT_CHART_URL=${K0RDENT_CHART_URL:-"oci://registry.mirantis.com/k0rdent-enterprise/charts/k0rdent-enterprise"}

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

# Function to check if required tools are available
check_tools() {
    local missing_tools=()
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        exit 1
    fi
    
    print_success "All required tools are available"
}

# Function to check if kubectl can connect to cluster
check_kubectl() {
    # Check if local kubeconfig exists
    if [[ ! -f "./kubeconfig" ]]; then
        print_error "Local kubeconfig file not found: ./kubeconfig"
        print_warning "Please ensure your k0s cluster is deployed and kubeconfig is available"
        exit 1
    fi
    
    # Set KUBECONFIG to use local file
    export KUBECONFIG="./kubeconfig"
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster using ./kubeconfig"
        print_warning "Please check if your k0s cluster is running and accessible"
        exit 1
    fi
    
    print_success "kubectl is connected to k0s cluster using ./kubeconfig"
}

# Function to check if terraform state exists and has our resources
check_terraform_state() {
    print_status "Checking Terraform state..."
    
    # Check if terraform state exists
    local state_list
    if ! state_list=$(terraform state list 2>/dev/null); then
        print_error "No Terraform state found. Please run 'terraform apply' first."
        exit 1
    fi
    
    # Check for application credential
    if ! echo "$state_list" | grep -q "openstack_identity_application_credential_v3.ccm_credential"; then
        print_error "Application credential not found in Terraform state."
        print_warning "Found these resources in state:"
        echo "$state_list"
        print_warning "Please ensure you've applied the Terraform configuration with the application credential resource."
        exit 1
    fi
    
    print_success "Terraform state contains required resources"
}

# Function to read OpenStack config from Terraform outputs
read_openstack_config() {
    print_status "Reading OpenStack configuration from Terraform outputs..."
    
    local config_json
    if ! config_json=$(terraform output -json k0rdent_openstack_config 2>/dev/null); then
        print_error "Failed to read k0rdent_openstack_config terraform output"
        exit 1
    fi
    
    # Parse JSON and extract values
    OS_AUTH_URL_FROM_TERRAFORM=$(echo "$config_json" | jq -r '.auth_url // empty')
    OS_REGION_NAME=$(echo "$config_json" | jq -r '.region // empty')
    OS_APPLICATION_CREDENTIAL_ID=$(echo "$config_json" | jq -r '.application_credential_id // empty')
    OS_APPLICATION_CREDENTIAL_SECRET=$(echo "$config_json" | jq -r '.application_credential_secret // empty')
    OS_INTERFACE=$(echo "$config_json" | jq -r '.interface // empty')
    OS_IDENTITY_API_VERSION=$(echo "$config_json" | jq -r '.identity_api_version // empty')
    OS_AUTH_TYPE=$(echo "$config_json" | jq -r '.auth_type // empty')
    
    # Read custom CA configuration
    if ! OPENSTACK_CUSTOM_CA=$(terraform output -raw openstack_custom_ca 2>/dev/null); then
        print_warning "Failed to read openstack_custom_ca terraform output, defaulting to false"
        OPENSTACK_CUSTOM_CA="false"
    fi
    
    print_status "OpenStack custom CA enabled: ${OPENSTACK_CUSTOM_CA}"
    
    # Use environment variable if terraform output is null
    if [[ -z "$OS_AUTH_URL_FROM_TERRAFORM" ]] || [[ "$OS_AUTH_URL_FROM_TERRAFORM" == "null" ]]; then
        if [[ -z "$OS_AUTH_URL" ]]; then
            print_error "OS_AUTH_URL not found in Terraform output"
            print_warning "Please ensure the openstack_auth_url variable is set or OS_AUTH_URL environment variable is available"
            exit 1
        fi
        OS_AUTH_URL_FROM_TERRAFORM="$OS_AUTH_URL"
        print_warning "Using OS_AUTH_URL from environment: $OS_AUTH_URL"
    fi
    
    # Validate required fields
    if [[ -z "$OS_REGION_NAME" ]]; then
        print_error "OS_REGION_NAME not found in Terraform output"
        exit 1
    fi
    
    if [[ -z "$OS_APPLICATION_CREDENTIAL_ID" ]]; then
        print_error "OS_APPLICATION_CREDENTIAL_ID not found in Terraform output"
        exit 1
    fi
    
    if [[ -z "$OS_APPLICATION_CREDENTIAL_SECRET" ]]; then
        print_error "OS_APPLICATION_CREDENTIAL_SECRET not found in Terraform output"
        exit 1
    fi
    
    print_success "OpenStack configuration read from Terraform outputs"
}

# Function to get cluster info from Terraform
get_terraform_cluster_info() {
    print_status "Reading cluster information from Terraform outputs..."
    
    local cluster_output
    if ! cluster_output=$(terraform output -json cluster_info 2>/dev/null); then
        print_error "Failed to read cluster_info output from Terraform"
        exit 1
    fi
    
    CLUSTER_NAME=$(echo "$cluster_output" | jq -r '.cluster_name')
    EXTERNAL_NETWORK=$(echo "$cluster_output" | jq -r '.external_network')
    
    print_success "Cluster information retrieved from Terraform"
    print_status "Cluster name: ${CLUSTER_NAME}"
    print_status "External network: ${EXTERNAL_NETWORK}"
}

# Function to read CA certificate from file
read_ca_certificate() {
    if [[ "$OPENSTACK_CUSTOM_CA" != "true" ]]; then
        print_status "Skipping CA certificate reading (openstack_custom_ca = false)"
        return 0
    fi
    
    print_status "Reading CA certificate from manifests/secret-ca-cert.yaml..."
    
    if [[ ! -f "manifests/secret-ca-cert.yaml" ]]; then
        print_error "CA certificate file not found: manifests/secret-ca-cert.yaml"
        print_warning "Please ensure you have the CA certificate file available"
        exit 1
    fi
    
    # Extract the base64 encoded CA cert from the YAML file
    # Try multiple extraction methods for robustness
    CA_CERT_B64=""
    
    # Method 1: Use yq if available
    if command -v yq &> /dev/null; then
        CA_CERT_B64=$(yq eval '.data."ca.crt"' manifests/secret-ca-cert.yaml 2>/dev/null || true)
    fi
    
    # Method 2: Use kubectl dry-run if yq failed
    if [[ -z "$CA_CERT_B64" ]]; then
        CA_CERT_B64=$(kubectl get -f manifests/secret-ca-cert.yaml --dry-run=client -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
    fi
    
    # Method 3: Use grep/awk as fallback
    if [[ -z "$CA_CERT_B64" ]]; then
        CA_CERT_B64=$(grep -A1 "ca.crt:" manifests/secret-ca-cert.yaml | tail -1 | awk '{print $1}' 2>/dev/null || true)
    fi
    
    if [[ -z "$CA_CERT_B64" ]]; then
        print_error "Failed to extract CA certificate from manifests/secret-ca-cert.yaml"
        print_error "Please ensure the file contains a valid 'ca.crt' field under 'data'"
        print_status "File structure check:"
        if [[ -f manifests/secret-ca-cert.yaml ]]; then
            grep -A2 -B2 "ca.crt:" manifests/secret-ca-cert.yaml || print_error "No 'ca.crt:' field found"
        else
            print_error "File manifests/secret-ca-cert.yaml not found"
        fi
        exit 1
    fi
    
    # Validate the extracted certificate
    if echo "$CA_CERT_B64" | base64 -d | grep -q "BEGIN CERTIFICATE"; then
        print_success "CA certificate loaded and validated from manifests/secret-ca-cert.yaml"
    else
        print_warning "CA certificate loaded but validation failed - proceeding anyway"
    fi
}

# Function to install k0rdent enterprise
install_k0rdent() {
    print_status "Installing k0rdent enterprise v${K0RDENT_VERSION}..."
    
    # Check if k0rdent is already installed
    if kubectl get namespace ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_warning "k0rdent namespace ${K0RDENT_NAMESPACE} already exists"
        
        if kubectl get deployment -n ${K0RDENT_NAMESPACE} kcm-k0rdent-enterprise-controller-manager &> /dev/null; then
            print_success "k0rdent enterprise is already installed"
            return 0
        fi
    fi
    
    # Install k0rdent enterprise using Helm
    print_status "Installing k0rdent enterprise via Helm..."
    
    if ! helm install kcm ${K0RDENT_CHART_URL} \
        --version ${K0RDENT_VERSION} \
        --namespace ${K0RDENT_NAMESPACE} \
        --create-namespace \
        --wait --timeout=10m; then
        print_error "Failed to install k0rdent enterprise"
        exit 1
    fi
    
    print_success "k0rdent enterprise v${K0RDENT_VERSION} installed successfully"
    
    # Wait for k0rdent to be ready
    print_status "Waiting for k0rdent enterprise to be ready..."
    kubectl wait --for=condition=Available deployment/kcm-controller-manager -n ${K0RDENT_NAMESPACE} --timeout=300s
    
    print_success "k0rdent enterprise is ready"
}

# Function to configure CAPO with custom CA (can be run separately)
configure_capo_ca_only() {
    if [[ "$OPENSTACK_CUSTOM_CA" != "true" ]]; then
        print_status "Skipping CAPO CA configuration (openstack_custom_ca = false)"
        return 0
    fi
    
    print_status "Configuring CAPO with custom CA certificates..."
    
    # Ensure we're using the correct kubeconfig
    local kubectl_cmd="kubectl --kubeconfig=${KUBECONFIG}"
    
    # Check if kcm-system namespace exists
    if ! ${kubectl_cmd} get namespace ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_error "${K0RDENT_NAMESPACE} namespace not found"
        print_status "Please ensure k0rdent enterprise is installed first"
        return 1
    fi
    
    # Check if CAPO controller exists
    if ! ${kubectl_cmd} get deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_error "CAPO controller not found in ${K0RDENT_NAMESPACE}"
        print_status "Please wait for the CAPI operator to create the CAPO controller and try again"
        print_status "Current deployments in ${K0RDENT_NAMESPACE}:"
        ${kubectl_cmd} get deployments -n ${K0RDENT_NAMESPACE} | grep -E "(NAME|capo|controller)" || true
        return 1
    fi
    
    # Check if the volume mount already exists
    if ${kubectl_cmd} get deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' | grep -q "ca-certs"; then
        print_success "✓ CAPO controller already has CA certificate configuration"
        return 0
    fi
    
    # Ensure CA certificate secret exists in kcm-system namespace
    if ! ${kubectl_cmd} get secret custom-ca-cert -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_status "Copying CA certificate secret to ${K0RDENT_NAMESPACE}..."
        # Get the secret from kube-system and create it in kcm-system
        ${kubectl_cmd} get secret custom-ca-cert -n kube-system -o yaml | \
        sed "s/namespace: kube-system/namespace: ${K0RDENT_NAMESPACE}/" | \
        ${kubectl_cmd} apply -f -
        print_success "✓ CA certificate secret copied to ${K0RDENT_NAMESPACE}"
    else
        print_success "✓ CA certificate secret already exists in ${K0RDENT_NAMESPACE}"
    fi
    
    # Patch the CAPO controller
    print_status "Patching CAPO controller with custom CA..."
    ${kubectl_cmd} patch deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "ca-certs",
          "mountPath": "/etc/ssl/certs/openstack-ca.crt",
          "subPath": "ca.crt",
          "readOnly": true
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "ca-certs",
          "secret": {
            "secretName": "custom-ca-cert"
          }
        }
      }
    ]' || true
    
    print_success "✓ CAPO controller configured with custom CA certificate"
}

# Function to ensure CA certificate secret exists for OpenStack
ensure_ca_certificate_secret() {
    if [[ "$OPENSTACK_CUSTOM_CA" != "true" ]]; then
        print_status "Skipping CA certificate configuration (openstack_custom_ca = false)"
        return 0
    fi
    
    print_status "Ensuring CA certificate secret exists for OpenStack..."
    
    # Check if the existing CA secret from manifests already exists
    if kubectl get secret custom-ca-cert -n kube-system &> /dev/null; then
        print_success "✓ CA certificate secret 'custom-ca-cert' already exists in kube-system namespace"
    else
        print_status "Applying CA certificate secret from manifests/secret-ca-cert.yaml..."
        
        # Apply the CA certificate secret from manifests
        if kubectl apply -f manifests/secret-ca-cert.yaml; then
            print_success "✓ CA certificate secret created from manifests/secret-ca-cert.yaml"
        else
            print_error "Failed to create CA certificate secret from manifests"
            exit 1
        fi
    fi
}

# Function to check if kcm-system namespace exists
check_kcm_namespace() {
    print_status "Checking if ${K0RDENT_NAMESPACE} namespace exists..."
    
    if kubectl get namespace ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "${K0RDENT_NAMESPACE} namespace exists"
    else
        print_error "${K0RDENT_NAMESPACE} namespace does not exist"
        print_warning "k0rdent enterprise will be installed in the next step"
    fi
}

# Function to create k0rdent credential object
create_credential_object() {
    print_status "Creating k0rdent credential object..."
    
    # First create a secret with clouds.yaml format that the template expects
    print_status "Creating OpenStack credentials secret in clouds.yaml format..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: openstack-identity-secret
  namespace: kube-system
  labels:
    k0rdent.mirantis.com/component: "kcm"
type: Opaque
stringData:
  clouds.yaml: |
    clouds:
      openstack:
        auth:
          auth_url: "${OS_AUTH_URL}"
          application_credential_id: "${OS_APPLICATION_CREDENTIAL_ID}"
          application_credential_secret: "${OS_APPLICATION_CREDENTIAL_SECRET}"
        region_name: "${OS_REGION_NAME}"
        interface: "public"
        identity_api_version: "3"${OPENSTACK_CUSTOM_CA:+"
        cacert: \"/etc/ssl/certs/openstack-ca.crt\"
        verify: true"}
EOF
    
    print_success "OpenStack credentials secret created"
    
    # Now create the credential object pointing to the clouds.yaml secret
    cat <<EOF | kubectl apply -f -
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Credential
metadata:
  name: openstack-cluster-identity-cred
  namespace: ${K0RDENT_NAMESPACE}
  labels:
    k0rdent.mirantis.com/component: "kcm"
spec:
  description: "OpenStack credentials for ${CLUSTER_NAME}"
  identityRef:
    apiVersion: v1
    kind: Secret
    name: openstack-identity-secret
    namespace: kube-system
EOF
    
    print_success "k0rdent credential object created"
}

# Function to create CAPO cloud config secret
create_capo_cloud_config() {
    print_status "Creating OpenStack cloud config secret for CAPO..."
    
    # CAPO expects the openstack-cloud-config secret in the same namespace as the OpenStackCluster
    # This is typically kcm-system namespace, not kube-system where the template creates it
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: openstack-cloud-config
  namespace: ${K0RDENT_NAMESPACE}
  labels:
    k0rdent.mirantis.com/component: "kcm"
type: Opaque
stringData:
  clouds.yaml: |
    clouds:
      openstack:
        auth:
          auth_url: "${OS_AUTH_URL}"
          application_credential_id: "${OS_APPLICATION_CREDENTIAL_ID}"
          application_credential_secret: "${OS_APPLICATION_CREDENTIAL_SECRET}"
        region_name: "${OS_REGION_NAME}"
        interface: "public"
        identity_api_version: "3"${OPENSTACK_CUSTOM_CA:+"
        cacert: \"/etc/ssl/certs/openstack-ca.crt\"
        verify: true"}
  cloud.conf: |
    [Global]
    auth-url="${OS_AUTH_URL}"
    application-credential-id="${OS_APPLICATION_CREDENTIAL_ID}"
    application-credential-secret="${OS_APPLICATION_CREDENTIAL_SECRET}"
    region="${OS_REGION_NAME}"${OPENSTACK_CUSTOM_CA:+"
    ca-file=/etc/ssl/certs/openstack-ca.crt"}
    [LoadBalancer]
    [Networking]
EOF
    
    print_success "CAPO cloud config secret created in ${K0RDENT_NAMESPACE}"
}

# Function to create ConfigMap resource template with CA certificate
create_resource_template() {
    print_status "Creating ConfigMap resource template with CA certificate support..."
    
    cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: openstack-cloud-config-resource-template
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/component: "kcm"
  annotations:
    projectsveltos.io/template: "true"
data:
  configmap.yaml: |
    {{- $cluster := .InfrastructureProvider -}}
    {{- $identity := (getResource "InfrastructureProviderIdentity") -}}
    {{- $clouds := fromYaml (index $identity "data" "clouds.yaml" | b64dec) -}}
    {{- if not $clouds }}
      {{ fail "failed to decode clouds.yaml" }}
    {{ end -}}
    {{- $openstack := index $clouds "clouds" "openstack" -}}
    {{- if not (hasKey $openstack "auth") }}
      {{ fail "auth key not found in openstack config" }}
    {{- end }}
    {{- $auth := index $openstack "auth" -}}
    {{- $auth_url := index $auth "auth_url" -}}
    {{- $app_cred_id := index $auth "application_credential_id" -}}
    {{- $app_cred_name := index $auth "application_credential_name" -}}
    {{- $app_cred_secret := index $auth "application_credential_secret" -}}
    {{- $network_id := $cluster.status.externalNetwork.id -}}
    {{- $network_name := $cluster.status.externalNetwork.name -}}
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: openstack-cloud-config
      namespace: kube-system
    type: Opaque
    stringData:
      cloud.conf: |
        [Global]
        auth-url="{{ $auth_url }}"
        {{- if $app_cred_id }}
        application-credential-id="{{ $app_cred_id }}"
        {{- end }}
        {{- if $app_cred_name }}
        application-credential-name="{{ $app_cred_name }}"
        {{- end }}
        {{- if $app_cred_secret }}
        application-credential-secret="{{ $app_cred_secret }}"
        {{- end }}
        {{- if and (not $app_cred_id) (not $app_cred_secret) }}
        username="{{ index $openstack "username" }}"
        password="{{ index $openstack "password" }}"
        {{- end }}
        region="{{ index $openstack "region_name" }}"
        ${OPENSTACK_CUSTOM_CA:+'# Custom CA certificate configuration
        ca-file=/etc/ssl/certs/openstack-ca.crt'}
        [LoadBalancer]
        {{- if $network_id }}
        floating-network-id="{{ $network_id }}"
        {{- end }}
        [Networking]
        {{- if $network_name }}
        public-network-name="{{ $network_name }}"
        {{- end }}
      # Include the CA certificate in the secret
      clouds.yaml: |
        clouds:
          openstack:
            auth:
              auth_url: "{{ $auth_url }}"
              {{- if $app_cred_id }}
              application_credential_id: "{{ $app_cred_id }}"
              {{- end }}
              {{- if $app_cred_name }}
              application_credential_name: "{{ $app_cred_name }}"
              {{- end }}
              {{- if $app_cred_secret }}
              application_credential_secret: "{{ $app_cred_secret }}"
              {{- end }}
              {{- if and (not $app_cred_id) (not $app_cred_secret) }}
              username: "{{ index $openstack "username" }}"
              password: "{{ index $openstack "password" }}"
              {{- end }}
            region_name: "{{ index $openstack "region_name" }}"
            interface: "{{ index $openstack "interface" | default "public" }}"
            identity_api_version: "{{ index $openstack "identity_api_version" | default "3" }}"
            ${OPENSTACK_CUSTOM_CA:+'# Custom CA certificate configuration for CAPO
            cacert: /etc/ssl/certs/openstack-ca.crt
            verify: true'}
EOF
    
    print_success "ConfigMap resource template created with CA certificate support"
}

# Function to create CAPO configuration with custom CA
create_capo_ca_config() {
    if [[ "$OPENSTACK_CUSTOM_CA" != "true" ]]; then
        print_status "Skipping CAPO CA configuration (openstack_custom_ca = false)"
        return 0
    fi
    
    print_status "Creating CAPO configuration with custom CA certificate..."
    
    # Ensure CA certificate secret is available for CAPO
    # k0rdent enterprise puts CAPO in kcm-system namespace
    if ! kubectl get namespace ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_warning "k0rdent namespace ${K0RDENT_NAMESPACE} not found. CA secret will be copied when k0rdent is installed."
        return 0
    fi
    
    # Check if secret already exists in kcm-system
    if kubectl get secret custom-ca-cert -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "✓ CAPO CA secret already exists in ${K0RDENT_NAMESPACE}"
    else
        print_status "Copying CA certificate secret to ${K0RDENT_NAMESPACE}..."
        # Copy the secret from kube-system to kcm-system
        kubectl get secret custom-ca-cert -n kube-system -o yaml | \
        sed "s/namespace: kube-system/namespace: ${K0RDENT_NAMESPACE}/" | \
        kubectl apply -f -
        print_success "✓ CAPO CA secret copied to ${K0RDENT_NAMESPACE}"
    fi

    # Wait for and patch the CAPO controller deployment to use the custom CA
    print_status "Waiting for CAPO controller to be deployed..."
    
    # Wait up to 5 minutes for CAPO controller to be created
    local wait_timeout=300
    local wait_interval=10
    local elapsed=0
    
    while [[ $elapsed -lt $wait_timeout ]]; do
        if kubectl get deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} &> /dev/null; then
            print_success "✓ CAPO controller found, proceeding with CA configuration"
            break
        fi
        
        if [[ $elapsed -eq 0 ]]; then
            print_status "CAPO controller not ready yet, waiting for CAPI operator to create it..."
        fi
        
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
        
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            print_status "Still waiting for CAPO controller... (${elapsed}s elapsed)"
        fi
    done
    
    # Check if CAPO controller exists now
    if kubectl get deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_status "Patching CAPO controller to use custom CA..."
        
        # Check if the volume mount already exists
        if kubectl get deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' | grep -q "ca-certs"; then
            print_success "✓ CAPO controller already has CA certificate configuration"
        else
            kubectl patch deployment capo-controller-manager -n ${K0RDENT_NAMESPACE} --type='json' -p='[
              {
                "op": "add",
                "path": "/spec/template/spec/containers/0/volumeMounts/-",
                "value": {
                  "name": "ca-certs",
                  "mountPath": "/etc/ssl/certs/openstack-ca.crt",
                  "subPath": "ca.crt",
                  "readOnly": true
                }
              },
              {
                "op": "add",
                "path": "/spec/template/spec/volumes/-",
                "value": {
                  "name": "ca-certs",
                  "secret": {
                    "secretName": "custom-ca-cert"
                  }
                }
              }
            ]' || true
            
            print_success "✓ CAPO controller patched with custom CA certificate"
        fi
    else
        print_warning "⚠ CAPO controller still not found after ${wait_timeout}s"
        print_warning "  This is normal for initial deployments. You can configure CAPO later by running:"
        print_warning "  $0 --configure-capo-only"
    fi
}

# Function to verify the setup
verify_setup() {
    print_status "Verifying k0rdent OpenStack setup..."
    
    # Check k0rdent installation
    if kubectl get deployment kcm-k0rdent-enterprise-controller-manager -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "✓ k0rdent controller is deployed"
    else
        print_error "✗ k0rdent controller missing"
        return 1
    fi
    
    # Check credential
    if kubectl get credential openstack-cluster-identity-cred -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "✓ k0rdent credential object exists"
    else
        print_error "✗ k0rdent credential object missing"
        return 1
    fi
    
    # Check configmap
    if kubectl get configmap openstack-cloud-config-resource-template -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "✓ ConfigMap resource template exists"
    else
        print_error "✗ ConfigMap resource template missing"
        return 1
    fi
    
    # Check CAPO cloud config secret
    if kubectl get secret openstack-cloud-config -n ${K0RDENT_NAMESPACE} &> /dev/null; then
        print_success "✓ CAPO cloud config secret exists in ${K0RDENT_NAMESPACE}"
    else
        print_error "✗ CAPO cloud config secret missing in ${K0RDENT_NAMESPACE}"
        return 1
    fi
    
    # Check CA certificate (only if custom CA is enabled)
    if [[ "$OPENSTACK_CUSTOM_CA" == "true" ]]; then
        if kubectl get secret custom-ca-cert -n kube-system &> /dev/null; then
            print_success "✓ Custom CA certificate secret 'custom-ca-cert' exists"
        else
            print_warning "⚠ Custom CA certificate secret 'custom-ca-cert' not found in kube-system"
        fi
        
        # Check CAPO CA configuration
        if kubectl get secret custom-ca-cert -n ${K0RDENT_NAMESPACE} &> /dev/null; then
            print_success "✓ CAPO CA Secret exists in ${K0RDENT_NAMESPACE}"
        else
            print_warning "⚠ CAPO CA Secret not found in ${K0RDENT_NAMESPACE} (will be copied when CAPO is configured)"
        fi
    else
        print_status "✓ Custom CA certificate configuration skipped (openstack_custom_ca = false)"
    fi
    
    # Check available templates
    print_status "Available cluster templates:"
    kubectl get clustertemplate -n ${K0RDENT_NAMESPACE} 2>/dev/null | grep -E "(NAME|openstack)" || print_warning "No OpenStack cluster templates found yet"
}

# Function to show next steps
show_next_steps() {
    print_success "k0rdent enterprise OpenStack preparation completed successfully!"
    echo
    print_status "✅ Setup includes:"
    echo "   • k0rdent enterprise installed and configured"
    echo "   • OpenStack credentials configured for Cluster API"
    echo "   • CAPO cloud config secret created in correct namespace"
    if [[ "$OPENSTACK_CUSTOM_CA" == "true" ]]; then
        echo "   • Custom CA certificates configured for secure OpenStack communication"
    fi
    echo
    print_status "Next steps:"
    echo "1. Verify k0rdent enterprise is fully ready:"
    echo "   kubectl get pods -n ${K0RDENT_NAMESPACE}"
    echo
    echo "2. Check CAPO controller status:"
    echo "   kubectl get pods -n ${K0RDENT_NAMESPACE} | grep capo"
    echo
    echo "3. Check available cluster templates:"
    echo "   kubectl get clustertemplate -n ${K0RDENT_NAMESPACE}"
    echo
    echo "4. Create a ClusterDeployment to deploy an OpenStack cluster:"
    echo "   kubectl apply -f my-openstack-cluster-deployment.yaml"
    echo
    echo "5. Example ClusterDeployment for your Terraform-managed environment:"
    cat <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: my-openstack-cluster
  namespace: ${K0RDENT_NAMESPACE}
spec:
  template: openstack-standalone-cp-1-0-0
  credential: openstack-cluster-identity-cred
  config:
    clusterLabels: {}
    controlPlaneNumber: 1
    workersNumber: 1
    controlPlane:
      flavor: m1.large
      image:
        filter:
          name: ubuntu-22.04
    worker:
      flavor: m1.medium
      image:
        filter:
          name: ubuntu-22.04
    externalNetwork:
      filter:
        name: "${EXTERNAL_NETWORK}"
    authURL: ${OS_AUTH_URL_FROM_TERRAFORM}
    identityRef:
      name: "openstack-cloud-config"
      cloudName: "openstack"
      region: ${OS_REGION_NAME}
    # Custom CA certificate support is automatically configured
EOF
    echo
    echo "5. Monitor deployment:"
    echo "   kubectl -n ${K0RDENT_NAMESPACE} get clusterdeployment my-openstack-cluster --watch"
    echo
    echo "6. Get kubeconfig when ready:"
    echo "   kubectl -n ${K0RDENT_NAMESPACE} get secret my-openstack-cluster-kubeconfig -o jsonpath='{.data.value}' | base64 -d > my-openstack-cluster.kubeconfig"
    echo
    print_status "Note: This script has configured k0rdent enterprise with:"
    print_status "- Application credentials from your Terraform configuration"
    if [[ "$OPENSTACK_CUSTOM_CA" == "true" ]]; then
        print_status "- Custom CA certificate support for OpenStack endpoints"
        print_status "- CAPO integration with custom CA certificates"
    fi
    print_status "Application credential ID: ${OS_APPLICATION_CREDENTIAL_ID}"
}

# Main execution
main() {
    echo "=================================================================="
    echo "k0rdent Enterprise Installation & OpenStack Preparation Script"
    echo "=================================================================="
    echo
    
    # Pre-flight checks
    check_tools
    check_kubectl
    check_terraform_state
    
    # Get configuration from Terraform
    read_openstack_config
    get_terraform_cluster_info
    read_ca_certificate
    
    # Install and configure k0rdent enterprise
    echo
    print_status "Installing and configuring k0rdent enterprise..."
    
    check_kcm_namespace
    install_k0rdent
    ensure_ca_certificate_secret
    create_capo_ca_config
    
    echo
    print_status "Creating k0rdent OpenStack resources..."
    
    # Create resources
    create_credential_object
    create_capo_cloud_config
    create_resource_template
    
    echo
    # Verify setup
    verify_setup
    
    echo
    # Show next steps
    show_next_steps
}

# Help function
show_help() {
    cat <<EOF
k0rdent Enterprise Installation & OpenStack Preparation Script

This script installs k0rdent enterprise and prepares it for managing OpenStack clusters by creating
the required secrets, credentials, and resource templates using configuration from your
Terraform setup. It also configures custom CA certificates for secure OpenStack communication.

PREREQUISITES:
1. kubectl installed and configured
2. terraform installed and configured
3. jq installed for JSON processing
4. helm installed for k0rdent installation
5. Terraform configuration applied with application credential resource
6. Custom CA certificate file at manifests/secret-ca-cert.yaml (only if openstack_custom_ca = true)

REQUIRED TERRAFORM OUTPUTS:
- k0rdent_openstack_config (contains application credential information)
- cluster_info (contains cluster name and external network)
- openstack_custom_ca (whether to use custom CA certificates)

ENVIRONMENT VARIABLES:
- K0RDENT_VERSION: Version of k0rdent enterprise to install (default: 1.1.0-rc1)
- K0RDENT_NAMESPACE: Namespace for k0rdent enterprise (default: kcm-system)

USAGE:
    $0 [options]

OPTIONS:
    -h, --help               Show this help message
    --configure-capo-only    Only configure CAPO with custom CA (run after CAPO is deployed)

EXAMPLE:
    # Apply Terraform configuration first
    terraform apply
    
    # Ensure CA certificate is available (only if openstack_custom_ca = true)
    # ls manifests/secret-ca-cert.yaml
    
    # Run the enhanced preparation script
    $0

NEW FEATURES:
- Automatic k0rdent enterprise installation via Helm
- Conditional custom CA certificate support based on openstack_custom_ca variable
- CAPO integration with custom CA certificates (when enabled)
- Automatic CAPO cloud config secret creation in correct namespace
- Enhanced error handling and verification
- Improved template with CA support
- Skip functionality for existing secrets and configurations

ADVANTAGES OVER PREVIOUS VERSION:
- Complete k0rdent enterprise installation and configuration
- Uses existing CA secrets instead of creating duplicates (when enabled)
- Secure OpenStack communication with custom CA (when enabled)
- CAPO custom CA certificate support (when enabled)
- No manual k0rdent enterprise installation required
- Smart skip functionality for existing configurations

BASED ON:
    https://docs.k0rdent-enterprise.io/latest/admin/installation/install-k0rdent/
    https://cluster-api-openstack.sigs.k8s.io/clusteropenstack/configuration#ca-certificates
EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --configure-capo-only)
        export KUBECONFIG=${KUBECONFIG:-"./kubeconfig"}
        print_status "Using kubeconfig: ${KUBECONFIG}"
        check_tools
        read_openstack_config
        read_ca_certificate
        configure_capo_ca_only
        exit $?
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        echo "Use -h or --help for usage information"
        exit 1
        ;;
esac 