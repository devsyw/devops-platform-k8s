#!/bin/bash
# 호스트(Mac)에서 실행: worker 노드에 Harbor insecure registry 설정
set -e

for NODE in node1 node2; do
  echo ">> $NODE containerd insecure registry 설정..."
  multipass exec $NODE -- bash -c '
    sudo mkdir -p /etc/containerd/certs.d/192.168.2.2:30080
    cat << TOML | sudo tee /etc/containerd/certs.d/192.168.2.2:30080/hosts.toml
server = "http://192.168.2.2:30080"

[host."http://192.168.2.2:30080"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
TOML
    sudo systemctl restart containerd
  '
  echo ">> $NODE 완료"
done

echo ">> 전체 worker 노드 설정 완료!"
