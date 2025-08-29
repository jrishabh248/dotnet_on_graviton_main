#!/bin/bash

# Final Karpenter Installation Script
# Run this after CloudFormation stack creation is complete

set -e

export CLUSTER_NAME=${EKS_CLUSTER_NAME:-"GadgetsOnline"}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-"ap-south-1"}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Installing Karpenter v0.37.0 on cluster: $CLUSTER_NAME"

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME

# Create OIDC provider
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve

# Create service account with IAM role
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --name karpenter \
  --namespace karpenter \
  --role-name "KarpenterController-${CLUSTER_NAME}" \
  --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterController-${CLUSTER_NAME}" \
  --approve

# Install Karpenter using Helm
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "0.37.0" \
  --namespace "karpenter" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterController-${CLUSTER_NAME}" \
  --wait

# Apply NodePool configuration
kubectl apply -f K8s_Yaml/karpenter-nodepool.yaml

echo "Karpenter installation completed!"
echo "Verify with: kubectl get pods -n karpenter"