#!/usr/bin/env bash
# Deploy the lab app to Azure Kubernetes Service (AKS):
# resource group -> Azure Container Registry -> amd64 image -> AKS (managed identity, AcrPull) -> public LoadBalancer.
# Run from the repository root after "az login". Remove everything again with azure/cleanup.sh.
set -euo pipefail

RG="${RG:-rg-javalab}"
LOC="${LOC:-denmarkeast}"                 # must be an allowed region with quota for NODE_SIZE (see README)
ACR="${ACR:-javalab$RANDOM}"              # globally unique: becomes <name>.azurecr.io
AKS="${AKS:-aks-javalab}"
NODE_SIZE="${NODE_SIZE:-Standard_B2s_v2}" # 2 vCPU / 8 GB, Bsv2 family
IMAGE="${ACR}.azurecr.io/lab-app:1.0"

echo "== Subscription"
az account show --query "{name:name, state:state}" -o table

echo "== Resource providers"
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait

echo "== Resource group ${RG} and registry ${ACR} in ${LOC}"
az group create --name "$RG" --location "$LOC" -o none
az acr create --resource-group "$RG" --name "$ACR" --sku Basic -o none

echo "== Build the amd64 image and push it (ACR Tasks are not available on student subscriptions)"
az acr login --name "$ACR"
docker buildx build --platform linux/amd64 -t "$IMAGE" --push app/

echo "== AKS cluster ${AKS} (free tier, 1 node ${NODE_SIZE}, kubelet identity gets AcrPull)"
az aks create --resource-group "$RG" --name "$AKS" --location "$LOC" \
  --tier free --node-count 1 --node-vm-size "$NODE_SIZE" \
  --attach-acr "$ACR" --generate-ssh-keys -o none
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
CTX="$AKS"
kubectl --context "$CTX" get nodes -o wide

echo "== Deploy the same manifests as minikube; only the image reference is environment-specific"
kubectl --context "$CTX" apply -f k8s/00-namespace.yaml -f k8s/configmap.yaml -f k8s/secret.yaml -f k8s/service.yaml
sed "s#image: lab-app:1.0#image: ${IMAGE}#" k8s/deployment.yaml | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" -n lab rollout status deployment/lab-app --timeout=300s

echo "== Expose through an Azure Standard Load Balancer"
kubectl --context "$CTX" -n lab patch service lab-app -p '{"spec":{"type":"LoadBalancer"}}'
EXTERNAL_IP=""
for _ in $(seq 1 30); do
  EXTERNAL_IP=$(kubectl --context "$CTX" -n lab get service lab-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$EXTERNAL_IP" ] && break
  sleep 10
done
if [ -z "$EXTERNAL_IP" ]; then
  echo "No public IP after 5 minutes - check: kubectl --context $CTX -n lab describe service lab-app" >&2
  exit 1
fi

echo "== Health check over the internet"
curl -fsS --max-time 10 "http://${EXTERNAL_IP}:8080/app/health"
echo "App: http://${EXTERNAL_IP}:8080/app/health  (plain HTTP - lab only; production would use Ingress/App Gateway with TLS)"
