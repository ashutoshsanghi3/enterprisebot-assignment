#!/usr/bin/env bash
# Exit immediately if a pipeline returns a non-zero status
set -euo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"

echo "==> 1. Checking/Creating kind cluster '${CLUSTER_NAME}'..."
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  # The cluster doesn't exist, so create it
  kind create cluster --name "${CLUSTER_NAME}"
else
  echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
fi

echo "==> 2. Installing ingress-nginx..."
# kubectl apply is inherently idempotent
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Waiting for ingress-nginx to be ready (this avoids webhook timeout errors)..."
sleep 10
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

echo "==> 3. Building and loading the Docker image..."
docker build -t demo-service:local ./service
kind load docker-image demo-service:local --name "${CLUSTER_NAME}"

echo "==> 4. Installing Helm chart..."
# 'upgrade --install' is idempotent: it installs on run 1, and just updates on run 2
helm upgrade --install "${RELEASE_NAME}" ./chart \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait

echo "==> Setup complete!"