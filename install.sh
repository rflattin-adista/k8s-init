export MASTER_IP=10.23.36.88
export KUBERNETES_VERSION=1.26.0
export CRICTL_VERSION=v1.26.0
export JOIN_URL=$MASTER_IP:6443
echo JOIN_URL=$JOIN_URL
export KUBEADM_CONFIG=kubeadm.conf

./nodesetup.sh init

kubectl apply -f calico.yaml

kubectl taint node  my-cluster-2-pool-0-jczf7 node.cluster.x-k8s.io/uninitialized:NoSchedule-

kubectl apply -f metrics-server.yaml
kubectl apply -f csi-cinder/
kubectl apply -f cinder-cs.yaml
