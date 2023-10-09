kubectl apply -f calico.yaml

kubectl taint node  my-cluster-2-pool-0-jczf7 node.cluster.x-k8s.io/uninitialized:NoSchedule-

kubectl apply -f metrics-server.yaml
kubectl apply -f csi-cinder/
kubectl apply -f cinder-cs.yaml

