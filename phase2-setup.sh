#!/bin/bash
set -e

echo "============================================"
echo " Phase 2: DevOps Platform K8s Setup"
echo " Namespace: devops"
echo " Components: Harbor + ArgoCD"
echo " CI/CD: GitHub Actions → Harbor → ArgoCD"
echo "============================================"

# -----------------------------------------------
# Step 1: 불필요한 리소스 정리
# -----------------------------------------------
echo ""
echo "[Step 1] 클러스터 정리"
echo "-----------------------------------------------"

# ContainerStatusUnknown / Unknown pod 정리
echo ">> 비정상 pod 정리..."
kubectl get pods -n user-containers --no-headers 2>/dev/null | \
  grep -iE "unknown|completed" | awk '{print $1}' | \
  xargs -r kubectl delete pod -n user-containers --force --grace-period=0 2>/dev/null || true

# Completed pod 전체 네임스페이스 정리
echo ">> Completed pod 정리..."
kubectl get pods -A --no-headers 2>/dev/null | \
  grep "Completed" | awk '{print $1, $2}' | \
  while read ns name; do kubectl delete pod -n "$ns" "$name" --force --grace-period=0 2>/dev/null || true; done

# nginx-test 삭제
echo ">> nginx-test 삭제..."
kubectl delete deployment nginx-test -n default --ignore-not-found

echo ">> 정리 완료!"
echo ""

# -----------------------------------------------
# Step 2: devops 네임스페이스 생성
# -----------------------------------------------
echo "[Step 2] devops 네임스페이스 생성"
echo "-----------------------------------------------"
kubectl create namespace devops --dry-run=client -o yaml | kubectl apply -f -
echo ">> devops namespace ready"
echo ""

# -----------------------------------------------
# Step 3: Helm 설치 확인
# -----------------------------------------------
echo "[Step 3] Helm 확인"
echo "-----------------------------------------------"
if ! command -v helm &> /dev/null; then
    echo ">> Helm 미설치 → 설치 중..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo ">> Helm $(helm version --short) 확인"
fi
echo ""

# -----------------------------------------------
# Step 4: Harbor 설치
# -----------------------------------------------
echo "[Step 4] Harbor 설치"
echo "-----------------------------------------------"

helm repo add harbor https://helm.goharbor.io
helm repo update

cat > /tmp/harbor-values.yaml << 'EOF'
expose:
  type: nodePort
  nodePort:
    ports:
      http:
        nodePort: 30080
      https:
        nodePort: 30443
  tls:
    enabled: false

externalURL: http://192.168.2.2:30080

nodeSelector:
  node-role.kubernetes.io/control-plane: ""
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

persistence:
  enabled: true
  persistentVolumeClaim:
    registry:
      size: 10Gi
      storageClass: ""
    database:
      size: 2Gi
      storageClass: ""
    redis:
      size: 1Gi
      storageClass: ""
    jobservice:
      jobLog:
        size: 1Gi
        storageClass: ""

portal:
  resources:
    requests: { memory: 64Mi, cpu: 50m }
nginx:
  resources:
    requests: { memory: 64Mi, cpu: 50m }
core:
  resources:
    requests: { memory: 128Mi, cpu: 100m }
jobservice:
  resources:
    requests: { memory: 128Mi, cpu: 50m }
registry:
  resources:
    requests: { memory: 128Mi, cpu: 100m }
database:
  internal:
    resources:
      requests: { memory: 256Mi, cpu: 100m }
redis:
  internal:
    resources:
      requests: { memory: 64Mi, cpu: 50m }
trivy:
  enabled: false

harborAdminPassword: "Harbor12345"
EOF

echo ">> Harbor 설치 중... (약 2~3분)"
helm install harbor harbor/harbor \
  -n devops \
  -f /tmp/harbor-values.yaml \
  --wait \
  --timeout 10m

echo ">> Harbor 설치 완료!"
echo ""

# -----------------------------------------------
# Step 5: ArgoCD 설치
# -----------------------------------------------
echo "[Step 5] ArgoCD 설치"
echo "-----------------------------------------------"

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

cat > /tmp/argocd-values.yaml << 'EOF'
global:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

configs:
  params:
    server.insecure: true

server:
  service:
    type: NodePort
    nodePortHttp: 30070
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }

controller:
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

repoServer:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 250m, memory: 256Mi }

redis:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 100m, memory: 128Mi }

applicationSet:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 100m, memory: 128Mi }

notifications:
  enabled: false

dex:
  enabled: false
EOF

echo ">> ArgoCD 설치 중... (약 2~3분)"
helm install argocd argo/argo-cd \
  -n devops \
  -f /tmp/argocd-values.yaml \
  --wait \
  --timeout 10m

ARGOCD_PW=$(kubectl -n devops get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "추출실패-수동확인필요")
echo ">> ArgoCD 설치 완료!"
echo ""

# -----------------------------------------------
# Step 6: Harbor devops 프로젝트 생성
# -----------------------------------------------
echo "[Step 6] Harbor 'devops' 프로젝트 생성"
echo "-----------------------------------------------"
sleep 15
for i in {1..10}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://192.168.2.2:30080/api/v2.0/projects \
    -H "Content-Type: application/json" \
    -u "admin:Harbor12345" \
    -d '{"project_name":"devops","public":true}')
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    echo ">> Harbor 'devops' 프로젝트 OK (HTTP $HTTP_CODE)"
    break
  fi
  echo ">> Harbor API 대기 중... ($i/10)"
  sleep 10
done
echo ""

# -----------------------------------------------
# Step 7: containerd insecure registry 설정
# -----------------------------------------------
echo "[Step 7] containerd insecure registry 설정 (현재 노드)"
echo "-----------------------------------------------"

sudo mkdir -p /etc/containerd/certs.d/192.168.2.2:30080
cat << 'TOML' | sudo tee /etc/containerd/certs.d/192.168.2.2:30080/hosts.toml
server = "http://192.168.2.2:30080"

[host."http://192.168.2.2:30080"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
TOML

sudo systemctl restart containerd
echo ">> master containerd 설정 완료"
echo ""
echo ">> ⚠️  worker 노드에도 동일 설정 필요:"
echo "   multipass exec node1 -- bash -c '"
echo "     sudo mkdir -p /etc/containerd/certs.d/192.168.2.2:30080"
echo '     echo '\''server = "http://192.168.2.2:30080"'
echo ''
echo '     [host."http://192.168.2.2:30080"]'
echo '       capabilities = ["pull", "resolve", "push"]'
echo "       skip_verify = true'\'' | sudo tee /etc/containerd/certs.d/192.168.2.2:30080/hosts.toml"
echo "     sudo systemctl restart containerd"
echo "   '"
echo ""

# -----------------------------------------------
# Step 8: 설치 확인
# -----------------------------------------------
echo "[Step 8] 설치 확인"
echo "-----------------------------------------------"
echo ""
echo ">> devops 네임스페이스 Pod:"
kubectl get pods -n devops -o wide
echo ""
echo ">> devops 네임스페이스 Service:"
kubectl get svc -n devops
echo ""

echo "============================================"
echo " Phase 2 설치 완료!"
echo "============================================"
echo ""
echo " Harbor:  http://192.168.2.2:30080"
echo "          admin / Harbor12345"
echo ""
echo " ArgoCD:  http://192.168.2.2:30070"
echo "          admin / $ARGOCD_PW"
echo ""
echo " CI/CD 흐름:"
echo "   GitHub Push"
echo "     → GitHub Actions (docker build + push to Harbor)"
echo "     → Update K8s manifests (image tag)"
echo "     → ArgoCD auto-sync → K8s deploy"
echo ""
echo "============================================"
