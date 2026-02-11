#!/bin/bash
# =============================================================
# DevOps Platform - GitOps 파이프라인 전체 셋업
# 서버(kp-master01)에서 root로 실행
# =============================================================
set -e

GITEA_URL="https://gitea.devops.cicd.test"
GITEA_INTERNAL="http://gitea-http.devops-toolchain.svc.cluster.local:3000"
HARBOR_HOST="harbor.devops.cicd.test"
HARBOR_PROJECT="devops-platform"
ARGOCD_NS="devops-toolchain"
DEPLOY_NS="devops-tools"

# Gitea 계정 정보 (입력 받기)
read -p "Gitea 사용자명 [admin]: " GITEA_USER
GITEA_USER=${GITEA_USER:-admin}
read -sp "Gitea 비밀번호: " GITEA_PASS
echo ""

echo "============================================"
echo " Step 1: Gitea Actions 활성화 확인"
echo "============================================"
echo ""
echo "⚠️  Gitea pod에서 Actions가 비활성화되어 있을 수 있습니다."
echo "   helm values에 다음이 포함되어야 합니다:"
echo ""
echo '   gitea:'
echo '     config:'
echo '       actions:'
echo '         ENABLED: true'
echo ""
echo "   현재 설정 확인:"
kubectl exec -n devops-toolchain deploy/gitea -- cat /data/gitea/conf/app.ini 2>/dev/null | grep -A2 '\[actions\]' || echo "   [actions] 섹션 없음 - 활성화 필요"
echo ""
read -p "Actions가 이미 활성화되어 있습니까? (y/n): " ACTIONS_ENABLED

if [ "$ACTIONS_ENABLED" != "y" ]; then
  echo ""
  echo "Gitea Actions 활성화 중..."
  # Gitea ConfigMap 또는 helm upgrade로 활성화
  helm upgrade gitea gitea -n devops-toolchain \
    --reuse-values \
    --set gitea.config.actions.ENABLED=true \
    --set gitea.config.actions.DEFAULT_ACTIONS_URL=https://code.gitea.io 2>/dev/null || {
    echo "⚠️  helm upgrade 실패. 수동으로 활성화하세요:"
    echo "   kubectl exec -it -n devops-toolchain deploy/gitea -- vi /data/gitea/conf/app.ini"
    echo "   [actions] 섹션에 ENABLED = true 추가 후 pod 재시작"
  }
  echo "Gitea pod 재시작 대기..."
  kubectl rollout restart deployment/gitea -n devops-toolchain 2>/dev/null || true
  sleep 10
  kubectl rollout status deployment/gitea -n devops-toolchain --timeout=120s 2>/dev/null || true
fi

echo ""
echo "============================================"
echo " Step 2: Harbor 프로젝트 생성"
echo "============================================"
curl -sk -u "admin:vmffpdltm" \
  "https://${HARBOR_HOST}/api/v2.0/projects?name=${HARBOR_PROJECT}" | grep -q "$HARBOR_PROJECT" && {
  echo "✅ Harbor 프로젝트 '${HARBOR_PROJECT}' 이미 존재"
} || {
  curl -sk -u "admin:vmffpdltm" \
    -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":true}"
  echo "✅ Harbor 프로젝트 '${HARBOR_PROJECT}' 생성 완료"
}

echo ""
echo "============================================"
echo " Step 3: Gitea 저장소 생성"
echo "============================================"

# 소스 저장소
echo "--- devops-platform (소스) ---"
curl -sk -u "${GITEA_USER}:${GITEA_PASS}" \
  -X POST "${GITEA_URL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "devops-platform",
    "description": "DevOps Platform - Source Code",
    "private": false,
    "auto_init": false
  }' 2>/dev/null | grep -q '"name"' && echo "✅ 소스 저장소 생성 완료" || echo "⚠️  이미 존재하거나 생성 실패"

# GitOps 배포 저장소
echo "--- devops-platform-deploy (GitOps) ---"
curl -sk -u "${GITEA_USER}:${GITEA_PASS}" \
  -X POST "${GITEA_URL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "devops-platform-deploy",
    "description": "DevOps Platform - K8s Manifests (GitOps)",
    "private": false,
    "auto_init": true,
    "default_branch": "main"
  }' 2>/dev/null | grep -q '"name"' && echo "✅ 배포 저장소 생성 완료" || echo "⚠️  이미 존재하거나 생성 실패"

echo ""
echo "============================================"
echo " Step 4: Gitea Access Token 생성"
echo "============================================"
TOKEN_RESPONSE=$(curl -sk -u "${GITEA_USER}:${GITEA_PASS}" \
  -X POST "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ci-cd-token",
    "scopes": ["all"]
  }' 2>/dev/null)

GITEA_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
if [ -z "$GITEA_TOKEN" ]; then
  echo "⚠️  토큰 생성 실패 (이미 존재할 수 있음). 수동 생성 필요:"
  echo "   ${GITEA_URL}/-/user/settings/applications"
  read -p "Gitea Token 입력: " GITEA_TOKEN
else
  echo "✅ Gitea Token: ${GITEA_TOKEN}"
  echo "   ⚠️ 이 토큰을 안전하게 보관하세요!"
fi

echo ""
echo "============================================"
echo " Step 5: Gitea Actions Secrets 등록"
echo "============================================"
# Repository Secrets 설정 (소스 저장소)
for SECRET_NAME_VALUE in \
  "HARBOR_USERNAME:admin" \
  "HARBOR_PASSWORD:vmffpdltm" \
  "GITEA_USERNAME:${GITEA_USER}" \
  "GITEA_TOKEN:${GITEA_TOKEN}"; do

  SECRET_NAME=$(echo "$SECRET_NAME_VALUE" | cut -d: -f1)
  SECRET_VALUE=$(echo "$SECRET_NAME_VALUE" | cut -d: -f2-)

  curl -sk -u "${GITEA_USER}:${GITEA_PASS}" \
    -X PUT "${GITEA_URL}/api/v1/repos/${GITEA_USER}/devops-platform/actions/secrets/${SECRET_NAME}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": \"${SECRET_VALUE}\"}" >/dev/null 2>&1
  echo "  ✅ Secret: ${SECRET_NAME}"
done

echo ""
echo "============================================"
echo " Step 6: Runner 등록 토큰 발급 & 배포"
echo "============================================"
# Instance-level runner token
RUNNER_TOKEN_RESP=$(curl -sk -u "${GITEA_USER}:${GITEA_PASS}" \
  -X GET "${GITEA_URL}/api/v1/admin/runners/registration-token" 2>/dev/null)
RUNNER_TOKEN=$(echo "$RUNNER_TOKEN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$RUNNER_TOKEN" ]; then
  echo "⚠️  Runner token API 실패. 수동 발급 필요:"
  echo "   ${GITEA_URL}/-/admin/actions/runners"
  read -p "Runner Registration Token 입력: " RUNNER_TOKEN
else
  echo "✅ Runner Token: ${RUNNER_TOKEN}"
fi

# Secret 업데이트 후 Runner 배포
kubectl create secret generic act-runner-secret \
  --namespace=devops-toolchain \
  --from-literal=GITEA_INSTANCE_URL="${GITEA_INTERNAL}" \
  --from-literal=GITEA_RUNNER_REGISTRATION_TOKEN="${RUNNER_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  Runner 배포 중..."
kubectl apply -f /home/ubuntu/devops-platform/k8s/devops-tools/05-act-runner.yaml
kubectl rollout status deployment/act-runner -n devops-toolchain --timeout=120s
echo "  ✅ Runner 배포 완료"

echo ""
echo "============================================"
echo " Step 7: GitOps 배포 저장소 초기 Push"
echo "============================================"
cd /tmp
rm -rf devops-platform-deploy
git clone "http://${GITEA_USER}:${GITEA_TOKEN}@gitea-http.devops-toolchain.svc.cluster.local:3000/${GITEA_USER}/devops-platform-deploy.git" 2>/dev/null || \
git clone "https://${GITEA_USER}:${GITEA_TOKEN}@gitea.devops.cicd.test/${GITEA_USER}/devops-platform-deploy.git"

cd devops-platform-deploy

# 매니페스트 복사
cp /home/ubuntu/devops-platform/k8s/devops-tools/gitops/* .

git add .
git config user.name "admin"
git config user.email "admin@devops.cicd.test"
git diff --cached --quiet || git commit -m "init: K8s manifests for devops-platform"
git push origin main
echo "✅ GitOps 저장소 초기화 완료"

echo ""
echo "============================================"
echo " Step 8: ArgoCD에 Gitea 저장소 연결"
echo "============================================"

# ArgoCD에 Gitea 저장소 등록 (insecure TLS)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: devops-toolchain
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://gitea.devops.cicd.test/${GITEA_USER}/devops-platform-deploy.git
  username: "${GITEA_USER}"
  password: "${GITEA_PASS}"
  insecure: "true"
EOF
echo "✅ ArgoCD 저장소 인증 등록"

echo ""
echo "============================================"
echo " Step 9: ArgoCD Application 생성"
echo "============================================"

# Application YAML의 repoURL을 실제 사용자로 업데이트
sed "s|admin/devops-platform-deploy|${GITEA_USER}/devops-platform-deploy|g" \
  /home/ubuntu/devops-platform/k8s/devops-tools/argocd/application.yaml | kubectl apply -f -
echo "✅ ArgoCD Application 생성 완료"

echo ""
echo "============================================"
echo " Step 10: 초기 이미지 빌드 & 푸시"
echo "============================================"
echo "  (첫 배포를 위해 수동으로 이미지를 빌드합니다)"

cd /home/ubuntu/devops-platform

# Harbor 로그인
docker login ${HARBOR_HOST} -u admin -p vmffpdltm

# Backend
echo "--- Backend 빌드 ---"
docker build -t ${HARBOR_HOST}/${HARBOR_PROJECT}/backend:latest ./backend
docker push ${HARBOR_HOST}/${HARBOR_PROJECT}/backend:latest

# Frontend
echo "--- Frontend 빌드 ---"
docker build -t ${HARBOR_HOST}/${HARBOR_PROJECT}/frontend:latest ./frontend
docker push ${HARBOR_HOST}/${HARBOR_PROJECT}/frontend:latest

echo "✅ 초기 이미지 푸시 완료"

echo ""
echo "============================================"
echo " 🎉 셋업 완료!"
echo "============================================"
echo ""
echo " 📦 소스 저장소:  ${GITEA_URL}/${GITEA_USER}/devops-platform"
echo " 📋 배포 저장소:  ${GITEA_URL}/${GITEA_USER}/devops-platform-deploy"
echo " 🚀 ArgoCD:      https://argocd.devops.cicd.test"
echo " 🌐 Frontend:    http://platform.devops.cicd.test:31741"
echo " 🔌 Backend API: http://platform-api.devops.cicd.test:31741"
echo ""
echo " 🔄 파이프라인 흐름:"
echo "    main push → Gitea Actions → Harbor push → GitOps 업데이트 → ArgoCD 자동 배포"
echo ""
echo " 💡 Mac에서 소스 push 방법:"
echo "    cd ~/Desktop/영우/04.사내서버/01.devops-team-service/devops-platform"
echo "    git remote add gitea https://gitea.devops.cicd.test/${GITEA_USER}/devops-platform.git"
echo "    git push gitea main"
echo ""
