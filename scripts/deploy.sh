#!/usr/bin/env bash
# Deploy the InspectFlowAI stack using the AWS CLI (no SAM CLI required).
#
# Prereqs:
#   - AWS CLI installed
#   - Learner Lab credentials exported in this shell (copy them from the lab's
#     "AWS Details"); paste the 3 export lines, then run this script.
#
# Zero-config usage (recommended) -- everything is derived from your account:
#   ./scripts/deploy.sh
#
# Optional overrides:
#   QC_EMAIL="you@example.com" \          # enables the SNS email subscription
#   EXPECTED_LABELS="hardware|machine|motor,qr code" \
#   ./scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-inspectflow-ai}"

# 1. Verify credentials and learn the account id.
echo "Checking AWS credentials..."
if ! ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  echo "ERROR: AWS credentials are missing or expired." >&2
  echo "Open the Learner Lab, click 'AWS Details', and paste the 3 export lines" >&2
  echo "(AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN) into this shell." >&2
  exit 1
fi
echo "  account: $ACCOUNT_ID  region: $REGION"

# 2. Derive sensible defaults (override via env vars if you like).
LAB_ROLE_ARN="${LAB_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/LabRole}"
SOURCE_BUCKET="${SOURCE_BUCKET:-inspectflow-source-${ACCOUNT_ID}}"
INSPECTED_BUCKET="${INSPECTED_BUCKET:-inspectflow-inspected-${ACCOUNT_ID}}"
DEPLOY_BUCKET="${DEPLOY_BUCKET:-inspectflow-deploy-${ACCOUNT_ID}-${REGION}}"
EXPECTED_LABELS="${EXPECTED_LABELS:-hardware|machine|motor,qr code}"
MIN_CONFIDENCE="${MIN_CONFIDENCE:-80}"
QC_EMAIL="${QC_EMAIL:-}"   # optional; blank = no SNS subscription created

# 3. Ensure a bucket exists to hold the packaged Lambda code.
if ! aws s3 ls "s3://${DEPLOY_BUCKET}" --region "$REGION" >/dev/null 2>&1; then
  echo "Creating deploy bucket ${DEPLOY_BUCKET}..."
  aws s3 mb "s3://${DEPLOY_BUCKET}" --region "$REGION"
fi

# 4. Package (zips lambda/ and uploads it) then deploy via CloudFormation.
echo "Packaging..."
aws cloudformation package \
  --template-file template.yaml \
  --s3-bucket "$DEPLOY_BUCKET" \
  --output-template-file packaged.yaml >/dev/null

echo "Deploying stack '$STACK_NAME'..."
aws cloudformation deploy \
  --template-file packaged.yaml \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    LabRoleArn="$LAB_ROLE_ARN" \
    NotificationEmail="$QC_EMAIL" \
    SourceBucketName="$SOURCE_BUCKET" \
    InspectedBucketName="$INSPECTED_BUCKET" \
    ExpectedLabels="$EXPECTED_LABELS" \
    MinConfidence="$MIN_CONFIDENCE"

echo
echo "Done."
echo "  Source bucket   : $SOURCE_BUCKET   (upload widget images here)"
echo "  Inspected bucket: $INSPECTED_BUCKET"
echo "  Rule            : EXPECTED_LABELS='$EXPECTED_LABELS'"
if [[ -n "$QC_EMAIL" ]]; then
  echo "  IMPORTANT: confirm the SNS subscription email sent to $QC_EMAIL."
else
  echo "  (No QC email set — re-run with QC_EMAIL=you@example.com to enable notifications.)"
fi
echo
echo "Try it:  ./scripts/demo.sh dataset/01-compliant/compliant-pcb.png"