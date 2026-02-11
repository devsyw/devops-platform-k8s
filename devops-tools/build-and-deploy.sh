#!/bin/bash
# =============================================================
# DevOps Platform - 빌드 & 배포 스크립트
# Mac에서 실행: ./build-and-deploy.sh
# =============================================================
set -e

# === 설정 ===
HARBOR_HOST="harbor.devops.cicd.test"
HARBOR_PROJECT="devops-platform"
HARBOR_USER="admin"
HARBOR_PASS="vmffpdltm"
SERVER="ubuntu@10.10.11.143"
SSH_KEY="~/.ssh/test-kp2.pem"
TAG="${1:-latest}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " DevOps Platform Build & Deploy"
echo " Tag: $TAG"
echo "============================================"

# === Step 1: Harbor 프로젝트 생성 (최초 1회) ===
echo ""
echo "[Step 1] Harbor 프로젝트 확인/생성..."
curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" \
  "https://${HARBOR_HOST}/api/v2.0/projects?name=${HARBOR_PROJECT}" | grep -q "$HARBOR_PROJECT" || \
curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" \
  -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":true}"
echo "  ✓ Harbor 프로젝트: ${HARBOR_PROJECT}"

# === Step 2: 프로젝트를 서버로 복사 ===
echo ""
echo "[Step 2] 소스를 서버로 복사..."
rsync -avz --exclude='node_modules' --exclude='.gradle' --exclude='build' \
  -e "ssh -i $SSH_KEY" \
  "$PROJECT_DIR/" "${SERVER}:~/devops-platform/"
echo "  ✓ 소스 복사 완료"

# === Step 3: 서버에서 Docker 빌드 & 푸시 ===
echo ""
echo "[Step 3] 서버에서 Docker 빌드 & Harbor 푸시..."
ssh -i $SSH_KEY $SERVER << REMOTE
set -e

cd ~/devops-platform

# Harbor 로그인
echo "${HARBOR_PASS}" | sudo docker login ${HARBOR_HOST} -u ${HARBOR_USER} --password-stdin

# Backend 빌드
echo "--- Backend 빌드 ---"
cd backend
sudo docker build -t ${HARBOR_HOST}/${HARBOR_PROJECT}/backend:${TAG} .
sudo docker push ${HARBOR_HOST}/${HARBOR_PROJECT}/backend:${TAG}
echo "  ✓ Backend 이미지 푸시 완료"

# Frontend 빌드
echo "--- Frontend 빌드 ---"
cd ../frontend
sudo docker build -t ${HARBOR_HOST}/${HARBOR_PROJECT}/frontend:${TAG} .
sudo docker push ${HARBOR_HOST}/${HARBOR_PROJECT}/frontend:${TAG}
echo "  ✓ Frontend 이미지 푸시 완료"

REMOTE

# === Step 4: K8s 배포 ===
echo ""
echo "[Step 4] K8s 배포..."
ssh -i $SSH_KEY $SERVER << REMOTE
set -e
export KUBECONFIG=/etc/kubernetes/admin.conf

# Harbor Pull Secret 생성
sudo kubectl create secret docker-registry harbor-pull-secret \
  --namespace=devops-tools \
  --docker-server=${HARBOR_HOST} \
  --docker-username=${HARBOR_USER} \
  --docker-password=${HARBOR_PASS} \
  --dry-run=client -o yaml | sudo kubectl apply -f -

# 매니페스트 적용 (순서대로)
cd ~/devops-platform/k8s/devops-tools

echo "--- PostgreSQL ---"
sudo kubectl apply -f 01-postgresql.yaml
echo "  PostgreSQL 대기중..."
sudo kubectl rollout status deployment/devops-postgres -n devops-tools --timeout=120s

echo "--- Backend ---"
sudo kubectl apply -f 02-backend.yaml
echo "  Backend 대기중..."
sudo kubectl rollout status deployment/devops-backend -n devops-tools --timeout=180s

echo "--- Frontend ---"
sudo kubectl apply -f 03-frontend.yaml
echo "  Frontend 대기중..."
sudo kubectl rollout status deployment/devops-frontend -n devops-tools --timeout=60s

echo "--- Ingress ---"
sudo kubectl apply -f 04-ingress.yaml

echo ""
echo "============================================"
echo " 배포 완료!"
echo " Frontend: http://platform.devops.cicd.test"
echo " Backend:  http://platform-api.devops.cicd.test"
echo " Swagger:  http://platform-api.devops.cicd.test/swagger-ui.html"
echo "============================================"
sudo kubectl get pods -n devops-tools
REMOTE
