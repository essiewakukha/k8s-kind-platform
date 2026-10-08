#!/usr/bin/env bash
# Creates the kind cluster, installs ingress and metrics-server, builds and loads
# the image, and deploys the app.
#   ./scripts/cluster-up.sh          deploy the dev overlay
#   ./scripts/cluster-up.sh prod     deploy the prod overlay
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

OVERLAY="${1:-dev}"
CLUSTER="shop"
IMAGE="shop-api:1.0.0"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml"
METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml"

[ -d "k8s/overlays/$OVERLAY" ] || { echo "Unknown overlay '$OVERLAY' (use dev or prod)"; exit 1; }
for tool in docker kind kubectl; do
  command -v "$tool" > /dev/null || { echo "Missing required tool: $tool"; exit 1; }
done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo ">> 1/6 Cluster '$CLUSTER' already exists"
else
  echo ">> 1/6 Creating kind cluster (1 control-plane + 2 workers)"
  kind create cluster --config kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" > /dev/null

echo ">> 2/6 Installing ingress-nginx"
kubectl apply -f "$INGRESS_URL" > /dev/null
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=240s

echo ">> 3/6 Installing metrics-server (needed by the autoscaler)"
kubectl apply -f "$METRICS_URL" > /dev/null
# kind kubelets use self-signed certificates
kubectl patch -n kube-system deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' > /dev/null 2>&1 || true
kubectl rollout status -n kube-system deployment/metrics-server --timeout=180s

echo ">> 4/6 Building and loading the image"
docker build -t "$IMAGE" app
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo ">> 5/6 Creating the namespace and the Secret"
kubectl apply -f k8s/base/namespace.yaml > /dev/null
# The Secret is created in the cluster only. It is never written to git.
if ! kubectl -n shop get secret shop-secrets > /dev/null 2>&1; then
  kubectl -n shop create secret generic shop-secrets \
    --from-literal=API_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

echo ">> 6/6 Deploying overlay: $OVERLAY"
kubectl apply -k "k8s/overlays/$OVERLAY"
kubectl -n shop rollout status deployment/shop-api --timeout=180s

echo ""
echo "Ready. Try:"
echo "  curl localhost:8080/info"
echo "  kubectl -n shop get pods,hpa"
echo "  ./scripts/smoke-test.sh"
echo "  ./scripts/loadtest.sh        (watch the autoscaler)"
echo "  ./scripts/chaos.sh rollout   (zero-downtime update test)"