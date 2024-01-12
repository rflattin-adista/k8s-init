helm repo add cilium https://helm.cilium.io/
#    --version 1.11.2 \
#    --version 1.14 \
#    --version 1.13.2 \
#    --set k8s.requireIPv4PodCIDR=true \
#    --set kubeProxyReplacement=disabled \
#    --set bpf.masquerade=true \
helm template cilium cilium/cilium \
    --version 1.12.4 \
    --namespace kube-system \
    --set tunnel=disabled \
    --set ipam.mode=kubernetes \
    --set ipam.operator.clusterPoolIPv4PodCIDR="100.126.0.0/17" \
    --set autoDirectNodeRoutes=true \
    --set debug.enabled=true \
    --set securityContext.privileged=true \
    --set ipv4NativeRoutingCIDR="100.126.0.0/17" \
    --set kubeProxyReplacement=strict \
    --set loadBalancer.mode=dsr \
    --set loadBalancer.algorithm=maglev \
    --set operator.replicas="1" \
    --set hubble.listenAddress=":4244" \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true > cilium.yaml
