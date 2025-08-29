#!/bin/bash

# Karpenter Installation Script for GadgetsOnline EKS Cluster
# This script installs the latest version of Karpenter using Helm

set -e

# Environment variables (set these before running)
export CLUSTER_NAME=${EKS_CLUSTER_NAME:-"GadgetsOnline"}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-"ap-south-1"}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Installing Karpenter for cluster: $CLUSTER_NAME in region: $AWS_DEFAULT_REGION"

# 1. Create OIDC provider for the cluster (if not exists)
echo "Setting up OIDC provider..."
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve

# 2. Create Karpenter IAM role and service account
echo "Creating Karpenter IAM service account..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --name karpenter \
  --namespace karpenter \
  --role-name "${CLUSTER_NAME}-karpenter" \
  --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterNodeInstancePolicy" \
  --role-only \
  --approve || echo "Service account may already exist"

# 3. Create Karpenter node instance policy
echo "Creating Karpenter node instance policy..."
cat > karpenter-node-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ec2:DescribeImages",
                "ec2:RunInstances",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeLaunchTemplates",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:DescribeAvailabilityZones",
                "ec2:DeleteLaunchTemplate",
                "ec2:CreateTags",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateFleet",
                "ec2:DescribeSpotPriceHistory",
                "pricing:GetProducts"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "ec2:TerminateInstances",
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "ec2:ResourceTag/karpenter.sh/provisioner-name": "*"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": "ec2:RunInstances",
            "Resource": [
                "arn:aws:ec2:*:${AWS_ACCOUNT_ID}:launch-template/*",
                "arn:aws:ec2:*:${AWS_ACCOUNT_ID}:security-group/*",
                "arn:aws:ec2:*:${AWS_ACCOUNT_ID}:subnet/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
        }
    ]
}
EOF

aws iam create-policy \
  --policy-name KarpenterNodeInstancePolicy \
  --policy-document file://karpenter-node-policy.json || echo "Policy may already exist"

# 4. Create Karpenter controller policy
echo "Creating Karpenter controller policy..."
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/main/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > karpenter-cfn.yaml

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-body file://karpenter-cfn.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

# 5. Tag subnets for Karpenter discovery
echo "Tagging subnets for Karpenter discovery..."
for NODEGROUP in $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --query 'nodegroups' --output text); do
    aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP \
        --query 'nodegroup.subnets' --output text | tr '\t' '\n' | \
        while read SUBNET; do
            aws ec2 create-tags \
                --resources $SUBNET \
                --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
        done
done

# 6. Tag security groups for Karpenter discovery
echo "Tagging security groups for Karpenter discovery..."
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
aws ec2 create-tags \
    --resources $CLUSTER_SG \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"

# 7. Install Karpenter using Helm
echo "Installing Karpenter using Helm..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "0.37.0" \
  --namespace "karpenter" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

# 8. Verify installation
echo "Verifying Karpenter installation..."
kubectl get pods -n karpenter
kubectl get crd | grep karpenter

echo "Karpenter installation completed successfully!"
echo "Next steps:"
echo "1. Apply the NodePool configuration: kubectl apply -f K8s_Yaml/karpenter-nodepool.yaml"
echo "2. Update your deployments to remove node selectors if you want Karpenter to manage scheduling"

# Cleanup temporary files
rm -f karpenter-node-policy.json karpenter-cfn.yaml