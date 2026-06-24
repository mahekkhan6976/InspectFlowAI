#!/usr/bin/env bash
# Pre-demo readiness check for InspectFlowAI.
# Verifies your tooling, credentials, and deployed stack so there are no
# surprises during the live in-class demo.
#
# Usage:
#   SOURCE_BUCKET="inspectflow-source-yourname" \
#   INSPECTED_BUCKET="inspectflow-inspected-yourname" \
#   ./scripts/check.sh
set -uo pipefail

STACK_NAME="${STACK_NAME:-inspectflow-ai}"
REGION="${AWS_REGION:-us-east-1}"
SOURCE_BUCKET="${SOURCE_BUCKET:-inspectflow-source-bucket}"
INSPECTED_BUCKET="${INSPECTED_BUCKET:-inspectflow-inspected-bucket}"
FUNCTION_NAME="${FUNCTION_NAME:-inspectflow-inspection}"
TOPIC_NAME="${TOPIC_NAME:-inspectflow-quality-control}"

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; }

echo "== Tooling =="
command -v aws >/dev/null 2>&1 && ok "aws CLI installed ($(aws --version 2>&1))" || bad "aws CLI not found"
command -v sam >/dev/null 2>&1 && ok "sam CLI installed ($(sam --version 2>&1))" || warn "sam CLI not found (only needed to (re)deploy)"
command -v python3 >/dev/null 2>&1 && ok "python3 installed" || bad "python3 not found"

echo "== Credentials =="
CALLER=$(aws sts get-caller-identity --region "$REGION" 2>/dev/null)
if [[ -n "$CALLER" ]]; then
  ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json;print(json.load(sys.stdin)['Account'])" 2>/dev/null)
  ok "AWS credentials valid (account $ACCOUNT)"
else
  bad "AWS credentials invalid/expired — re-copy them from the Learner Lab 'AWS Details'"
fi

echo "== Unit tests (offline QA gate) =="
if (cd "$(dirname "$0")/.." && python3 -m unittest discover -s tests -p "test_*.py" >/dev/null 2>&1); then
  ok "unit tests pass"
else
  bad "unit tests failing — run: python3 -m unittest discover -s tests -v"
fi

echo "== Stack & resources =="
STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null)
case "$STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ok "stack '$STACK_NAME' is $STATUS" ;;
  "" ) bad "stack '$STACK_NAME' not found — run ./scripts/deploy.sh" ;;
  * ) warn "stack '$STACK_NAME' is in state $STATUS" ;;
esac

aws s3 ls "s3://$SOURCE_BUCKET" >/dev/null 2>&1 && ok "source bucket reachable: $SOURCE_BUCKET" || bad "source bucket missing: $SOURCE_BUCKET"
aws s3 ls "s3://$INSPECTED_BUCKET" >/dev/null 2>&1 && ok "inspected bucket reachable: $INSPECTED_BUCKET" || bad "inspected bucket missing: $INSPECTED_BUCKET"

aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1 \
  && ok "Lambda exists: $FUNCTION_NAME" || bad "Lambda missing: $FUNCTION_NAME"

echo "== SNS subscription (Quality Control) =="
TOPIC_ARN=$(aws sns list-topics --region "$REGION" 2>/dev/null \
  | python3 -c "import sys,json;
arns=[t['TopicArn'] for t in json.load(sys.stdin)['Topics'] if '$TOPIC_NAME' in t['TopicArn']];
print(arns[0] if arns else '')" 2>/dev/null)
if [[ -n "$TOPIC_ARN" ]]; then
  CONFIRMED=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" 2>/dev/null \
    | python3 -c "import sys,json;
subs=json.load(sys.stdin)['Subscriptions'];
print(sum(1 for s in subs if s['SubscriptionArn'].startswith('arn:')))" 2>/dev/null)
  if [[ "${CONFIRMED:-0}" -ge 1 ]]; then
    ok "SNS topic found with $CONFIRMED confirmed subscription(s)"
  else
    bad "SNS topic found but NO confirmed subscription — check your email and click confirm"
  fi
else
  bad "SNS topic '$TOPIC_NAME' not found"
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] && echo "Ready to demo." || echo "Fix the [FAIL] items above before demoing."
exit "$FAIL"
