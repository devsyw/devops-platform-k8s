#!/bin/bash
set -e

echo "============================================"
echo " Phase 2: CI/CD Pipeline Setup"
echo " ghcr.io + ArgoCD Image Updater"
echo "============================================"

# -----------------------------------------------
# 사용법: bash setup-cicd.sh <GITHUB_PAT>
# -----------------------------------------------
if [ -z "$1" ]; then
  echo "사용법: bash setup-cicd.sh <GITHUB_PAT>"
  echo "  GITHUB_PAT: ghcr.io read:packages 권한이 있는 토큰"
  exit 1
fi

GITHUB_PAT=$1
GITHUB_USER=devsyw
NAMESPACE=devops

echo ""
echo "[Step 1] ghcr.io pull secret 생성"
echo "-----------------------------------------------"
kubectl create secret docker-registry ghcr-secret \
  -n $NAMESPACE \
  --docker-server=ghcr.io \
  --docker-username=$GITHUB_USER \
  --docker-password=$GITHUB_PAT \
  --dry-run=client -o yaml | kubectl apply -f -
echo ">> ghcr-secret 생성 완료"
echo ""

echo "[Step 2] ArgoCD Image Updater 설치"
echo "-----------------------------------------------"
kubectl apply -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

echo ">> Image Updater Pod 대기..."
kubectl rollout status deployment/argocd-image-updater -n $NAMESPACE --timeout=120s
echo ">> ArgoCD Image Updater 설치 완료"
echo ""

echo "[Step 3] ArgoCD에 k8s repo 등록"
echo "-----------------------------------------------"
# ArgoCD CLI 설치
if ! command -v argocd &> /dev/null; then
  echo ">> ArgoCD CLI 설치 중..."
  curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-arm64
  chmod +x /usr/local/bin/argocd
fi

# ArgoCD 로그인
ARGOCD_PW=$(kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd login localhost:30070 --insecure --username admin --password "$ARGOCD_PW" --plaintext

# public repo라 credentials 불필요
argocd repo add https://github.com/devsyw/devops-platform-k8s.git --name devops-platform-k8s || true
echo ">> repo 등록 완료"
echo ""

echo "[Step 4] ArgoCD Application 등록"
echo "-----------------------------------------------"
kubectl apply -f - <<'APPEOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devops-platform
  namespace: devops
  annotations:
    argocd-image-updater.argoproj.io/image-list: >-
      backend=ghcr.io/devsyw/devops-platform-backend:latest,
      frontend=ghcr.io/devsyw/devops-platform-frontend:latest
    argocd-image-updater.argoproj.io/backend.update-strategy: digest
    argocd-image-updater.argoproj.io/frontend.update-strategy: digest
    argocd-image-updater.argoproj.io/backend.pull-secret: pullsecret:devops/ghcr-secret
    argocd-image-updater.argoproj.io/frontend.pull-secret: pullsecret:devops/ghcr-secret
    argocd-image-updater.argoproj.io/write-back-method: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/devsyw/devops-platform-k8s.git
    targetRevision: main
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: devops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
APPEOF
echo ">> Application 등록 완료"
echo ""

echo "[Step 5] 확인"
echo "-----------------------------------------------"
echo ">> devops pods:"
kubectl get pods -n $NAMESPACE
echo ""
echo ">> ArgoCD app 상태:"
argocd app get devops-platform --refresh 2>/dev/null || kubectl get app devops-platform -n $NAMESPACE
echo ""

echo "============================================"
echo " CI/CD 파이프라인 구성 완료!"
echo "============================================"
echo ""
echo " 전체 흐름:"
echo "   1. backend/frontend repo에 git push"
echo "   2. GitHub Actions → ARM64 이미지 빌드 → ghcr.io push"
echo "   3. ArgoCD Image Updater → 새 이미지 감지"
echo "   4. ArgoCD → K8s 자동 배포"
echo ""
echo " 접속:"
echo "   Frontend: http://192.168.2.2:30000"
echo "   ArgoCD:   http://192.168.2.2:30070 (admin / $ARGOCD_PW)"
echo ""
echo " GitHub repo secrets 설정 필요:"
echo "   backend/frontend repo → Settings → Secrets → Actions"
echo "   (GITHUB_TOKEN은 자동 제공되므로 추가 설정 불필요)"
echo "============================================"
