#!/usr/bin/env bash
# Tear down the InspectFlowAI stack to stop any charges (protect the $50 budget).
# S3 buckets must be emptied before CloudFormation can delete them.
set -euo pipefail

STACK_NAME="${STACK_NAME:-inspectflow-ai}"
REGION="${AWS_REGION:-us-east-1}"
SOURCE_BUCKET="${SOURCE_BUCKET:-inspectflow-source-bucket}"
INSPECTED_BUCKET="${INSPECTED_BUCKET:-inspectflow-inspected-bucket}"
DEPLOY_BUCKET="${DEPLOY_BUCKET:-}"

echo "Emptying buckets (ignore errors if they are already empty/gone)..."
aws s3 rm "s3://$SOURCE_BUCKET" --recursive --region "$REGION" || true
aws s3 rm "s3://$INSPECTED_BUCKET" --recursive --region "$REGION" || true

echo "Deleting stack '$STACK_NAME'..."
# Works whether you deployed with SAM or with 'aws cloudformation deploy'.
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" || true

# The code-packaging bucket is created outside the stack, so remove it too.
if [[ -n "$DEPLOY_BUCKET" ]]; then
  echo "Removing deploy bucket '$DEPLOY_BUCKET'..."
  aws s3 rb "s3://$DEPLOY_BUCKET" --force --region "$REGION" || true
fi

echo "Done."
