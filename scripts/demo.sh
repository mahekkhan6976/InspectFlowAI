#!/usr/bin/env bash
# One-command live demo / smoke test for InspectFlowAI.
#
# Uploads a widget image to the source bucket, then tails the Lambda's
# CloudWatch logs and lists the resulting artifacts in the inspected bucket.
#
# Usage:
#   SOURCE_BUCKET="inspectflow-source-yourname" \
#   INSPECTED_BUCKET="inspectflow-inspected-yourname" \
#   ./scripts/demo.sh path/to/widget.jpg
#
# Tip: run it once with a "good" image (all components) and once with a "bad"
# image (missing a component) to show the PASS and FAIL paths.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_PATH="${1:?Usage: ./scripts/demo.sh path/to/widget.jpg}"
SOURCE_BUCKET="${SOURCE_BUCKET:-inspectflow-source-bucket}"
INSPECTED_BUCKET="${INSPECTED_BUCKET:-inspectflow-inspected-bucket}"
FUNCTION_NAME="${FUNCTION_NAME:-inspectflow-inspection}"
REGION="${AWS_REGION:-us-east-1}"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "Image not found: $IMAGE_PATH" >&2
  exit 1
fi

KEY="$(date +%Y%m%d-%H%M%S)-$(basename "$IMAGE_PATH")"

echo "==> Uploading $IMAGE_PATH to s3://$SOURCE_BUCKET/$KEY"
aws s3 cp "$IMAGE_PATH" "s3://$SOURCE_BUCKET/$KEY" --region "$REGION"

echo
echo "==> Tailing Lambda logs (Ctrl-C to stop). Inspection result appears in a few seconds..."
# --since rewinds a little so we don't miss the start of this invocation.
aws logs tail "$LOG_GROUP" --region "$REGION" --follow --since 10s --format short &
TAIL_PID=$!

# Give the pipeline time to run, then show the archived artifacts.
sleep 20
echo
echo "==> Artifacts in s3://$INSPECTED_BUCKET/inspected/"
aws s3 ls "s3://$INSPECTED_BUCKET/inspected/" --recursive --region "$REGION" || true

echo
echo "(Logs still tailing in the background as PID $TAIL_PID. Press Ctrl-C or run: kill $TAIL_PID)"
wait $TAIL_PID
