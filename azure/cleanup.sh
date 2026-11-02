#!/usr/bin/env bash
# Remove everything deploy-aks.sh created: the resource group (registry + AKS, which also removes its
# MC_* node resource group) and the cluster's entries in ~/.kube/config.
set -euo pipefail

RG="${RG:-rg-javalab}"
AKS="${AKS:-aks-javalab}"

echo "== Deleting resource group ${RG} in the background"
az group delete --name "$RG" --yes --no-wait

echo "== Removing ${AKS} from kubeconfig (context, cluster and credentials)"
kubectl config delete-context "$AKS" 2>/dev/null || true
kubectl config delete-cluster "$AKS" 2>/dev/null || true
kubectl config delete-user "clusterUser_${RG}_${AKS}" 2>/dev/null || true

echo "== Check progress until ${RG} and MC_${RG}_* are gone:"
echo "   az group list -o table"
