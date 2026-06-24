#!/usr/bin/env bash
# Discover what Amazon Rekognition detects in an image, so you can choose
# realistic EXPECTED_LABELS for your widget demo.
#
# Usage:
#   ./scripts/detect.sh path/to/widget.jpg [min_confidence]
#
# Then set the labels on the deployed Lambda (no redeploy needed):
#   aws lambda update-function-configuration \
#     --function-name inspectflow-inspection \
#     --environment "Variables={EXPECTED_LABELS=screw,bracket,label,INSPECTED_BUCKET=...,SNS_TOPIC_ARN=...,INSPECTED_PREFIX=inspected,MIN_CONFIDENCE=80}"
#   (or just edit EXPECTED_LABELS in the Lambda console)
set -euo pipefail

IMG="${1:?Usage: ./scripts/detect.sh path/to/image.jpg [min_confidence]}"
MINCONF="${2:-80}"
REGION="${AWS_REGION:-us-east-1}"

if [[ ! -f "$IMG" ]]; then
  echo "Image not found: $IMG" >&2
  exit 1
fi

echo "Detecting labels in $IMG (min confidence ${MINCONF}%)..."
aws rekognition detect-labels \
  --image-bytes "fileb://$IMG" \
  --min-confidence "$MINCONF" \
  --region "$REGION" \
  --query 'Labels[].{Label:Name,Confidence:Confidence}' \
  --output table
