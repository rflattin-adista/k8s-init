#!/bin/bash

set -e

# Set verbosity
if [ "${DEBUG}" = 1 ]; then
    set -x
    KUBEADM_VERBOSE="-v=8"
else
    KUBEADM_VERBOSE="-v=3"
fi

BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
SERVICE_DIR="/etc/systemd/system"
COMMAND=$1

# Define global compatibility matrix
declare -A versions=(
    ["containerd"]="v1.7.16"
    ["runc"]="v1.1.11"
    ["cni"]="v1.4.0"
    ["crictl"]="v1.29.0"
)

# Helper function to display usage information
helper() {
    cat <<EOF
Usage:

  ENV=... yaki <init|join|reset|help>
    or
  curl -sfL https://goyaki.clastix.io | ENV=... bash -s <init|join|reset|help>

  You must be sudo to run this script.

Commands:

  init: Deploy the first control-plane node of the Kubernetes cluster
    - This command initializes the Kubernetes control-plane on the first node.
    - Requires: JOIN_URL (optional), KUBEADM_CONFIG (optional), ADVERTISE_ADDRESS(optional), BIND_PORT (optional), KUBERNETES_VERSION (optional)
    - Example: KUBERNETES_VERSION=v1.30.2 yaki init
    - Example: JOIN_URL=<control-plane-endpoint>:<port> KUBERNETES_VERSION=v1.30.2 yaki init
    - Example: KUBEADM_CONFIG=kubeadm-config.yaml yaki init

  join: Join a control plane node to the cluster
    - This command joins the node as control plane to an existing Kubernetes cluster.
    - It also installs all necessary prerequisites, container runtime, CNI plugins, and Kubernetes binaries.
    - Requires: JOIN_URL, JOIN_TOKEN, JOIN_TOKEN_CACERT_HASH, JOIN_ASCP, KUBERNETES_VERSION (optional)
    - Example: JOIN_URL=<control-plane-endpoint>:<port> JOIN_TOKEN=<token> JOIN_TOKEN_CERT_KEY=<key> JOIN_TOKEN_CACERT_HASH=sha256:<hash> JOIN_ASCP=1 KUBERNETES_VERSION=v1.30.2 yaki join

  join: Join a node to the cluster
    - This command joins the node to an existing Kubernetes cluster.
    - Requires: JOIN_URL, JOIN_TOKEN, JOIN_TOKEN_CACERT_HASH, KUBERNETES_VERSION (optional)
    - Example: JOIN_URL=<control-plane-endpoint>:<port> JOIN_TOKEN=<token> JOIN_TOKEN_CACERT_HASH=sha256:<hash> KUBERNETES_VERSION=v1.30.2 yaki join

  reset: Reset the node
    - This command removes all Kubernetes components and configurations from the node.
    - Example: yaki reset

  help: Print this help
    - Displays this help message.
    - Example: yaki help

Environment variables:

  +-------------------------+-------------------------------------------------------------+------------+
  | Variable                | Description                                                 | Default    |
  +-------------------------+-------------------------------------------------------------+------------+
  | KUBERNETES_VERSION      | Version of kubernetes to install.                           | v1.30.2    |
  | CONTAINERD_VERSION      | Version of container runtime containerd.                    | see matrix |
  | RUNC_VERSION            | Version of runc to install.                                 | see matrix |
  | CNI_VERSION             | Version of CNI plugins to install.                          | see matrix |
  | CRICTL_VERSION          | Version of crictl to install.                               | see matrix |
  | KUBEADM_CONFIG          | Path to the kubeadm config file to use.                     | Not set    |
  | ADVERTISE_ADDRESS       | Address to advertise for the api-server.                    | 0.0.0.0    |
  | BIND_PORT               | Port to use for the api-server.                             | 6443       |
  | JOIN_TOKEN              | Token to join the control-plane.                            | Not set    |
  | JOIN_TOKEN_CACERT_HASH  | Token Certificate Authority hash to join the control-plane. | Not set    |
  | JOIN_TOKEN_CERT_KEY     | Token Certificate Key to join the control-plane.            | Not set    |
  | JOIN_URL                | URL to join the control-plane.                              | Not set    |
  | JOIN_ASCP               | Switch to join either as control plane or worker.           | 0          |
  | DEBUG                   | Set to 1 for more verbosity during script execution.        | 0          |
  +-------------------------+-------------------------------------------------------------+------------+

EOF
}

# Log functions
info()  { echo "[INFO] $@"; }
warn()  { echo "[WARN] $@" >&2; }
fatal() { echo "[ERROR] $@" >&2; exit 1; }

# Setup architecture
setup_arch() {
    case ${ARCH:=$(uname -m)} in
        amd64|x86_64) ARCH=amd64 ;;
        arm64) ARCH=arm64 ;;
        *) fatal "unsupported architecture ${ARCH}" ;;
    esac
    SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
}

# Function to get compatible components version
get_version() {
    local component=$1
    echo "${versions[$component]}"
}

setup_env() {
    # Check if running as root
    [ "$(id -u)" -eq 0 ] || fatal "You need to be root to perform this install"
    # Set default values
    KUBERNETES_VERSION=${KUBERNETES_VERSION:-v1.30.2}
    CONTAINERD_VERSION=${CONTAINERD_VERSION:-$(get_version "containerd")}
    RUNC_VERSION=${RUNC_VERSION:-$(get_version "runc")}
    CNI_VERSION=${CNI_VERSION:-$(get_version "cni")}
    CRICTL_VERSION=${CRICTL_VERSION:-$(get_version "crictl")}
    ADVERTISE_ADDRESS=${ADVERTISE_ADDRESS:-0.0.0.0}
    BIND_PORT=${BIND_PORT:-6443}
}

# Check if prerequisites are installed
check_prerequisites() {
    info "Checking if prerequisites are installed"

    # List of required commands
    local required_commands=("conntrack" "socat" "ip" "iptables" "modprobe" "sysctl" "systemctl" "nsenter" "ebtables" "ethtool" "wget")

    for cmd in "${required_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            info "$cmd is not installed. Please install it before proceeding."
            exit 1
        fi
    done
}

# Configure system settings
configure_system_settings() {
    info "Configure system settings: "
    info "  - disable swap"
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    info "  - enable required kernel modules"
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter

    info "  - forwarding IPv4 and letting iptables see bridged traffic"
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    info "  - apply sysctl settings"
    sysctl --system
}

# Install containerd
install_containerd() {
    info "installing containerd"
    wget -q --progress=bar https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz
    tar Cxzvf /usr/local containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz
    rm -f containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz

    mkdir -p /usr/local/lib/systemd/system/
    wget -q --progress=bar https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
    mv containerd.service /usr/local/lib/systemd/system/

    info "installing runc"
    wget -q --progress=bar https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}
    chmod 755 runc.${ARCH}
    mv runc.${ARCH} ${SBIN_DIR}/runc

    info "installing CNI plugins"
    mkdir -p /opt/cni/bin
    wget -q --progress=bar https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz
    tar Cxzvf /opt/cni/bin cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz
    rm -f cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz

    info "configuring systemd cgroup driver in containers"
    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" > /etc/containerd/config.toml

    sed -i '/\[Service\]/a EnvironmentFile='/etc/environment'' /usr/local/lib/systemd/system/containerd.service
    systemctl daemon-reload && systemctl enable --now containerd && systemctl restart containerd
}

# Install crictl
install_crictl() {
    info "installing crictl"
    wget -qO- --progress=bar "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | tar -C "${BIN_DIR}" -xz
    rm -f crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz  # Cleanup downloaded tar.gz file
    cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF
}

# Install Kubernetes binaries
install_kube_binaries() {
    # Install kubeadm, kubelet
    info "installing kubeadm and kubelet"
    wget -q --progress=bar https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubeadm
    wget -q --progress=bar https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubelet
    chmod +x {kubeadm,kubelet}
    mv {kubeadm,kubelet} ${BIN_DIR}

    # Install kubelet service
    local VERSION="v0.16.2"
    wget -qO- --progress=bar "https://raw.githubusercontent.com/kubernetes/release/${VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /etc/systemd/system/kubelet.service
    mkdir -p /etc/systemd/system/kubelet.service.d
    wget -qO- --progress=bar "https://raw.githubusercontent.com/kubernetes/release/${VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl daemon-reload && systemctl enable --now kubelet

    # Install kubectl
    info "installing kubectl"
    wget -q --progress=bar https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubectl
    install -o root -g root -m 0755 kubectl ${BIN_DIR}/kubectl
    rm -f kubectl  # Cleanup downloaded binary
}


# Initialize Kubernetes cluster
init_cluster() {
    # Setting JOIN_URL:
    # If JOIN_URL is not already set, it is assigned the first IP address of the host followed by port 6443
    : ${JOIN_URL:=$(hostname -I | awk '{print $1}'):6443}
    
    # Ensuring Required Parameters:
    # Checks if both JOIN_URL and KUBEADM_CONFIG are unset. If so, it calls fatal to terminate.
    [ -z "${JOIN_URL}" ] && [ -z "${KUBEADM_CONFIG}" ] && fatal "Either JOIN_URL or KUBEADM_CONFIG must be set"

    info "Initializing the control-plane"
    local KUBEADM_ARGS="--upload-certs"

    # Appending Arguments:
    # If KUBEADM_CONFIG is set, it appends --config ${KUBEADM_CONFIG} to KUBEADM_ARGS.
    # Otherwise, it appends --control-plane-endpoint ${JOIN_URL} --apiserver-advertise-address ${ADVERTISE_ADDRESS} --apiserver-bind-port ${BIND_PORT} to KUBEADM_ARGS.
    [ -n "${KUBEADM_CONFIG}" ] && KUBEADM_ARGS="--config ${KUBEADM_CONFIG} ${KUBEADM_ARGS}" || KUBEADM_ARGS="--control-plane-endpoint ${JOIN_URL} --apiserver-advertise-address ${ADVERTISE_ADDRESS} --apiserver-bind-port ${BIND_PORT} ${KUBEADM_ARGS}"

    # Running kubeadm init:
    # Executes kubeadm init with the constructed KUBEADM_ARGS and any additional verbosity flags from KUBEADM_VERBOSE.
    kubeadm init ${KUBEADM_ARGS} ${KUBEADM_VERBOSE}

    # Possible Cases
    
    # Case 1: KUBEADM_CONFIG is set:
    # The function uses the configuration file specified by KUBEADM_CONFIG to initialize the cluster.

    # Case 2: KUBEADM_CONFIG is not set, but JOIN_URL is set:
    # The function uses JOIN_URL, ADVERTISE_ADDRESS, and BIND_PORT to initialize the cluster.

    # Case 3: Neither KUBEADM_CONFIG nor JOIN_URL is set:
    # The function attempts to set JOIN_URL to the first IP address of the host.
    # If JOIN_URL is still not set, the function terminates with an error message.
}

# Join node to Kubernetes cluster
join_node() {
    # Ensure required parameters are set
    # Check if JOIN_URL is set, if not, terminate with an error message
    [ -z "${JOIN_URL}" ] && fatal "JOIN_URL is not set"
    # Check if JOIN_TOKEN is set, if not, terminate with an error message
    [ -z "${JOIN_TOKEN}" ] && fatal "JOIN_TOKEN is not set"
    # Check if JOIN_TOKEN_CACERT_HASH is set, if not, terminate with an error message
    [ -z "${JOIN_TOKEN_CACERT_HASH}" ] && fatal "JOIN_TOKEN_CACERT_HASH is not set"

    info "Joining the node to the cluster"
    # Construct the initial kubeadm join arguments
    local KUBEADM_ARGS="${JOIN_URL} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${JOIN_TOKEN_CACERT_HASH}"

    # If the node is joining as control plane, add control plane specific arguments
    if [ "${JOIN_ASCP}" ]; then
        # Check if JOIN_TOKEN_CERT_KEY is set, if not, terminate with an error message
        [ -z "${JOIN_TOKEN_CERT_KEY}" ] && fatal "JOIN_TOKEN_CERT_KEY is not set for control plane join"
        # Append control plane specific arguments to KUBEADM_ARGS
        KUBEADM_ARGS="${KUBEADM_ARGS} --control-plane --certificate-key ${JOIN_TOKEN_CERT_KEY}"
    fi

    # If KUBEADM_CONFIG is provided, use it
    # Check if the KUBEADM_CONFIG file exists, if so, use it for kubeadm join
    [ -f "${KUBEADM_CONFIG}" ] && KUBEADM_ARGS="--config ${KUBEADM_CONFIG}"

    # Execute kubeadm join with the constructed arguments and any additional verbosity flags
    kubeadm join ${KUBEADM_ARGS} ${KUBEADM_VERBOSE}
}

# Remove Kubernetes components
remove_kube() {
    info "removing kubernetes components"
    systemctl stop kubelet || true
    kubeadm reset -f || true
    rm -rf ${BIN_DIR}/{kubeadm,kubelet,kubectl} /etc/kubernetes /var/run/kubernetes /var/lib/kubelet /var/lib/etcd ${SERVICE_DIR}/kubelet.service ${SERVICE_DIR}/kubelet.service.d
    info "Kubernetes components removed"
}

# Remove containerd
remove_containerd() {
    info "removing containerd"
    systemctl stop containerd || true
    rm -rf ${BIN_DIR}/containerd* ${BIN_DIR}/ctr /etc/containerd/ /usr/local/lib/systemd/system/containerd.service
    rm -rf ${SBIN_DIR}/runc ${BIN_DIR}/crictl /etc/crictl.yaml
}

# Remove binaries and configuration files
remove_binaries() {
    info "removing side configuration files and binaries"
    rm -rf /etc/cni/net.d /opt/cni/bin /var/lib/cni /var/log/containers /var/log/pods
}

# Clean up iptables
clean_iptables() {
    info "cleaning up iptables"
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
}

# Reboot the machine
reboot_machine() {
    info "Rebooting the machine now..."
    systemctl reboot
}

# Main commands
do_kube_setup() {
    info "Prepare the machine for kubernetes"
    check_prerequisites
    configure_system_settings
    install_containerd
    install_crictl
    install_kube_binaries
}

do_kube_init() {
    do_kube_setup
    info "Initializing node as control-plane"
    init_cluster
}

do_kube_join() {
    do_kube_setup
    info "Joining node to the control-plane"
    join_node
}

do_reset() {
    info "Cleaning up"
    remove_kube
    remove_containerd
    remove_binaries
    clean_iptables
    reboot_machine
}

# Main script execution
setup_arch
setup_env

case ${COMMAND} in
    setup)  do_kube_setup && info "setup completed successfully" ;;
    init)  do_kube_init && info "init completed successfully" ;;
    join)  do_kube_join && info "join completed successfully" ;;
    reset) do_reset && info "reset completed successfully" ;;
    help)  helper ;;
    *)     helper && fatal "use command: init|join|reset|help" ;;
esac