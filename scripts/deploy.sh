#!/usr/bin/env bash
# Deploy the InspectFlowAI stack with AWS SAM.
#
# Prereqs:
#   - AWS SAM CLI installed (https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html)
#   - Learner Lab credentials exported (copy them from "AWS Details" in the lab)
#
# Usage:
#   LAB_ROLE_ARN="arn:aws:iam::123456789012:role/LabRole" \
#   QC_EMAIL="you@example.com" \
#   SOURCE_BUCKET="inspectflow-source-yourname" \
#   INSPECTED_BUCKET="inspectflow-inspected-yourname" \
#   EXPECTED_LABELS="screw,bracket,label" \
#   ./scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${LAB_ROLE_ARN:?Set LAB_ROLE_ARN (IAM > Roles > LabRole ARN)}"
: "${QC_EMAIL:?Set QC_EMAIL (Quality Control notification email)}"
SOURCE_BUCKET="${SOURCE_BUCKET:-inspectflow-source-bucket}"
INSPECTED_BUCKET="${INSPECTED_BUCKET:-inspectflow-inspected-bucket}"
EXPECTED_LABELS="${EXPECTED_LABELS:-screw,bracket,label}"
MIN_CONFIDENCE="${MIN_CONFIDENCE:-80}"
STACK_NAME="${STACK_NAME:-inspectflow-ai}"
REGION="${AWS_REGION:-us-east-1}"

echo "Building..."
sam build

echo "Deploying stack '$STACK_NAME' to $REGION..."
sam deploy \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --resolve-s3 \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    LabRoleArn="$LAB_ROLE_ARN" \
    NotificationEmail="$QC_EMAIL" \
    SourceBucketName="$SOURCE_BUCKET" \
    InspectedBucketName="$INSPECTED_BUCKET" \
    ExpectedLabels="$EXPECTED_LABELS" \
    MinConfidence="$MIN_CONFIDENCE"

echo
echo "Done. IMPORTANT: confirm the SNS subscription email sent to $QC_EMAIL."
echo "Then upload an image to s3://$SOURCE_BUCKET to trigger an inspection."
