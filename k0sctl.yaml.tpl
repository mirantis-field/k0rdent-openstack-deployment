apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: ${cluster_name}
spec:
  hosts:
%{ for i, controller_private_ip in controller_private_ips ~}
  - ssh:
      address: ${controller_private_ip}
%{ if bastion_enabled ~}
      bastion:
        address: ${bastion_ip}
        user: ${bastion_user}
        port: 22
        keyPath: ${ssh_key_path}
%{ endif ~}
      user: ubuntu
      port: 22
      keyPath: ${ssh_key_path}
    role: controller%{ if length(worker_private_ips) == 0 }+worker%{ endif }
    privateInterface: eth0
    privateAddress: ${controller_private_ip}
    hostname: ${cluster_name}-controller-${i + 1}
%{ if length(worker_private_ips) == 0 ~}
    noTaints: true
%{ endif ~}
    installFlags:
      - --debug
      - --enable-cloud-provider
%{ endfor ~}
%{ for i, worker_private_ip in worker_private_ips ~}
  - ssh:
%{ if length(worker_ips) > 0 ~}
      address: ${worker_ips[i]}
%{ else ~}
      address: ${worker_private_ip}
%{ if bastion_enabled ~}
      bastion:
        address: ${bastion_ip}
        user: ${bastion_user}
        port: 22
        keyPath: ${ssh_key_path}
%{ endif ~}
%{ endif ~}
      user: ubuntu
      port: 22
      keyPath: ${ssh_key_path}
    role: worker
    privateInterface: eth0
    privateAddress: ${worker_private_ip}
    hostname: ${cluster_name}-worker-${i + 1}
    installFlags:
      - --debug
      - --enable-cloud-provider
%{ endfor ~}
  k0s:
    version: v1.33.1+k0s.0
    dynamicConfig: false
    config:
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: ${cluster_name}
      spec:
        api:
          port: 6443
          k0sApiPort: 9443
          externalAddress: ${api_endpoint}
          sans:
%{ for san in api_sans ~}
            - ${san}
%{ endfor ~}
%{ for controller_ip in controller_private_ips ~}
            - ${controller_ip}
%{ endfor ~}
            - ${api_endpoint}
        controllerManager:
          extraArgs:
            bind-address: "0.0.0.0"
        scheduler:
          extraArgs:
            bind-address: "0.0.0.0"
        storage:
          type: etcd
        network:
          kubeProxy:
            disabled: false
          provider: "custom"
          podCIDR: ${pod_cidr}
          serviceCIDR: ${service_cidr}
        podSecurityPolicy:
          defaultPolicy: 00-k0s-privileged
        workerProfiles:
        - name: default
          values:
            kubelet:
              cgroupsPerQOS: true
              cgroupDriver: systemd
              volumePluginDir: /var/libexec/k0s/kubelet-plugins/volume/exec
              extraArgs:
                cloud-provider: external
        extensions:
          helm:
            repositories:
            - name: cpo
              url: https://kubernetes.github.io/cloud-provider-openstack
            - name: cilium
              url: "https://helm.cilium.io/"
            charts:
            - name: openstack-cloud-controller-manager
              chartname: cpo/openstack-cloud-controller-manager
              version: "2.32.0"
              namespace: kube-system
              order: 1
              values: |
                # Image configuration
                image:
                  repository: registry.k8s.io/provider-os/openstack-cloud-controller-manager
                  tag: ""
                
                # Additional environment variables
                extraEnv: []
                
                # Resources
                resources: {}
                
                # Probes
                livenessProbe: {}
                readinessProbe: {}
                
                # DNS policy
                dnsPolicy: ClusterFirst
                
                # Node selector for control plane nodes (FIXED for k0s)
                nodeSelector:
                  node-role.kubernetes.io/control-plane: "true"
                
                # Tolerations for control plane and uninitialized nodes
                tolerations:
                  - key: node.cloudprovider.kubernetes.io/uninitialized
                    value: "true"
                    effect: NoSchedule
                  - key: node-role.kubernetes.io/control-plane
                    effect: NoSchedule
                
                # Pod annotations and labels
                podAnnotations: {}
                podLabels: {}
                
                # Pod security context
                podSecurityContext:
                  runAsUser: 1001
                
                # Enabled controllers
                enabledControllers:
                  - cloud-node
                  - cloud-node-lifecycle
                  - route
                  - service
                
                # Extra arguments for the controller (FIXED format)
                controllerExtraArgs: |-
                  - --cluster-cidr=${pod_cidr}
                  - --allocate-node-cidrs=true
                  - --configure-cloud-routes=false
                
                # Service monitor
                serviceMonitor: {}
                
                # Secret configuration
                secret:
                  enabled: true
                  create: true
                  name: cloud-config
                
                # Log verbosity
                logVerbosityLevel: 2
                
                # Cluster name
                cluster:
                  name: ${cluster_name}
                
                # Pod priority
                priorityClassName:
                
                # Extra volumes for OCCM functionality
                extraVolumes:
                  - name: flexvolume-dir
                    hostPath:
                      path: /var/libexec/k0s/kubelet-plugins/volume/exec
                  - name: k0s-certs
                    hostPath:
                      path: /var/lib/k0s/pki
%{ if openstack_config.custom_ca ~}
                  - name: custom-ca-cert
                    secret:
                      secretName: custom-ca-cert
                      items:
                        - key: ca.crt
                          path: ca.crt
%{ endif ~}
                
                extraVolumeMounts:
                  - name: flexvolume-dir
                    mountPath: /var/libexec/k0s/kubelet-plugins/volume/exec
                    readOnly: true
                  - name: k0s-certs
                    mountPath: /var/lib/k0s/pki
                    readOnly: true
%{ if openstack_config.custom_ca ~}
                  - name: custom-ca-cert
                    mountPath: /etc/ssl/certs/ca.crt
                    subPath: ca.crt
                    readOnly: true 
%{ endif ~}
                
                # RBAC configuration
                clusterRoleName: system:cloud-controller-manager
                serviceAccountName: cloud-controller-manager
                
                # OpenStack cloud configuration
                cloudConfig:
                  global:
                    auth-url: ${openstack_config.auth_url}
                    region: ${openstack_config.region}
                    application-credential-id: ${openstack_config.application_credential_id}
                    application-credential-secret: ${openstack_config.application_credential_secret}
%{ if openstack_config.insecure ~}
                    tls-insecure: ${openstack_config.insecure}
%{ endif ~}
%{ if openstack_config.custom_ca ~}
                    ca-file: /etc/ssl/certs/ca.crt
%{ endif ~}
                  networking:
                    public-network-name: ${external_network_name}
                    internal-network-name: ${network_name}
                  loadBalancer:
                    subnet-id: ${openstack_config.subnet_id}
                    floating-network-id: ${openstack_config.floating_network_id}
                    create-monitor: false
                    monitor-delay: "60s"
                    monitor-timeout: "30s"
                    monitor-max-retries: 3
                    use-octavia: true
                  blockStorage:
                    bs-version: v3
                    ignore-volume-az: true
                    trust-device-path: false
                  metadata:
                    search-order: "configDrive,metadataService"
                  route:
                    router-id: ""
                
                # Common annotations
                commonAnnotations: {}
                
                # Image pull secrets
                imagePullSecrets: []
                
                # Additional init containers
                extraInitContainers: []
            - name: openstack-csi
              chartname: cpo/openstack-cinder-csi
              version: 2.31.2
              order: 2
              namespace: kube-system
              values: |
                # CSI plugin configuration
                csi:
                  plugin:
                    nodePlugin:
                      kubeletDir: /var/lib/k0s/kubelet
                    volumes:
                      # Mount the existing cloud-config secret created by CCM
                      - name: cloud-config
                        secret:
                          secretName: cloud-config
%{ if openstack_config.custom_ca ~}
                      # Mount custom CA certificate
                      - name: custom-ca-cert
                        secret:
                          secretName: custom-ca-cert
                          items:
                            - key: ca.crt
                              path: ca.crt
%{ endif ~}
                    volumeMounts:
                      # Mount cloud config to expected CSI location
                      - name: cloud-config
                        mountPath: /etc/kubernetes
                        readOnly: true
%{ if openstack_config.custom_ca ~}
                      # Mount custom CA certificate
                      - name: custom-ca-cert
                        mountPath: /etc/ssl/certs/ca.crt
                        subPath: ca.crt
                        readOnly: true
%{ endif ~}
                # Secret configuration for CSI - reuse existing secret
                secret:
                  enabled: true
                  create: false
                  name: cloud-config
            - name: "cilium"
              chartname: "cilium/cilium"
              namespace: "kube-system"
              version: "1.13.1"
              order: 3