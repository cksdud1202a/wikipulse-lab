#!/usr/bin/env bash
# wikipulse-lab 로컬 환경 부트스트랩 스크립트
# 실행: bash scripts/bootstrap.sh

set -euo pipefail

CLUSTER_NAME="wikipulse"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 색상 출력 헬퍼 ────────────────────────────────────────────────
info()    { echo "[INFO] $*"; }
success() { echo "[OK]   $*"; }
error()   { echo "[ERR]  $*" >&2; exit 1; }

# ── 1. 사전 요구사항 확인 ─────────────────────────────────────────
info "Checking prerequisites..."
command -v docker  >/dev/null || error "docker not found"
command -v kind    >/dev/null || error "kind not found"
command -v kubectl >/dev/null || error "kubectl not found"
success "All prerequisites found."

# ── 2. kind 클러스터 생성 ─────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  info "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster \
    --config "${REPO_ROOT}/kind-cluster.yaml" \
    --name "${CLUSTER_NAME}"
  success "Cluster created."
fi

# context 전환
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 3. ArgoCD 설치 ────────────────────────────────────────────────
info "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# ArgoCD 폴링 주기 60초로 설정
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"timeout.reconciliation":"60s"}}'

# application-controller 준비될 때까지 대기
info "Waiting for ArgoCD to be ready..."
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=120s
success "ArgoCD ready."

# ── 4. root-app 등록 ──────────────────────────────────────────────
info "Registering root-app..."
kubectl apply -f "${REPO_ROOT}/gitops/argocd/apps/root-app.yaml"
success "root-app registered."

# ── 5. SSE Consumer 이미지 빌드 + kind 로드 ───────────────────────
info "Building SSE consumer image..."
docker build -t sse-consumer:latest "${REPO_ROOT}/services/sse-consumer/"

info "Loading image into kind cluster..."
kind load docker-image sse-consumer:latest --name "${CLUSTER_NAME}"
success "Image loaded."

# ── 완료 ──────────────────────────────────────────────────────────
echo ""
success "Bootstrap complete!"
echo ""
echo "  ArgoCD UI : kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Kafka UI  : kubectl port-forward svc/platform-kafka-ui -n kafka 8081:80"
echo ""
echo "  ArgoCD 초기 비밀번호:"
echo "  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
