#!/usr/bin/env bash
# InspectFlowAI — one command to do EVERYTHING.
#
#   1. verifies your AWS (Learner Lab) credentials
#   2. deploys the full stack (idempotent — safe to re-run)
#   3. waits for the Lambda + SQS trigger to be ready
#   4. uploads the whole labeled dataset, triggering a live inspection each
#   5. prints the PASS/FAIL results matrix
#   6. shows where everything lives (buckets, dashboard, logs)
#
# Usage:
#   export AWS_ACCESS_KEY_ID=...      # paste the 3 lines from the lab's
#   export AWS_SECRET_ACCESS_KEY=...  # "AWS Details"
#   export AWS_SESSION_TOKEN=...
#   ./run.sh
#
#   # optional: enable QC email notifications
#   QC_EMAIL="you@example.com" ./run.sh
set -euo pipefail

cd "$(dirname "$0")"

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-inspectflow-ai}"
FUNCTION_NAME="${FUNCTION_NAME:-inspectflow-inspection}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# --- 1. credentials -------------------------------------------------------
step "Checking AWS credentials"
if ! ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  die "AWS credentials missing/expired. Open the Learner Lab -> 'AWS Details' and
       paste the 3 export lines (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
       AWS_SESSION_TOKEN) into this shell, then re-run ./run.sh"
fi
ok "account $ACCOUNT_ID, region $REGION"

SOURCE_BUCKET="inspectflow-source-${ACCOUNT_ID}"
INSPECTED_BUCKET="inspectflow-inspected-${ACCOUNT_ID}"
export SOURCE_BUCKET INSPECTED_BUCKET   # for deploy.sh / teardown.sh

# --- 2. deploy ------------------------------------------------------------
step "Deploying the stack (idempotent)"
./scripts/deploy.sh

# --- 3. wait for readiness -----------------------------------------------
step "Waiting for the Lambda SQS trigger to be enabled"
for i in $(seq 1 30); do
  state="$(aws lambda list-event-source-mappings --function-name "$FUNCTION_NAME" \
            --region "$REGION" --query 'EventSourceMappings[0].State' --output text 2>/dev/null || true)"
  if [[ "$state" == "Enabled" ]]; then ok "trigger enabled"; break; fi
  sleep 3
  [[ $i -eq 30 ]] && die "SQS trigger did not become Enabled in time"
done

# --- 4. run the whole dataset --------------------------------------------
step "Uploading the labeled dataset (one inspection per image)"
TS="$(date +%H%M%S)"
COUNT=0
while IFS= read -r f; do
  scen="$(basename "$(dirname "$f")")"; base="$(basename "$f")"
  aws s3 cp "$f" "s3://${SOURCE_BUCKET}/run-${TS}/${scen}__${base}" \
    --region "$REGION" --only-show-errors
  COUNT=$((COUNT+1))
done < <(find dataset -type f -name '*.png' | sort)
ok "uploaded $COUNT images"

step "Waiting for inspections to complete"
sleep $(( COUNT * 3 + 15 ))

# --- 5. results matrix ----------------------------------------------------
step "Inspection results"
python3 - "$INSPECTED_BUCKET" "$REGION" <<'PY'
import boto3, json, subprocess, sys
bucket, region = sys.argv[1], sys.argv[2]
s3 = boto3.client("s3", region_name=region)
files = sorted(subprocess.check_output(
    ["find", "dataset", "-type", "f", "-name", "*.png"]).decode().split())
npass = nfail = 0
for f in files:
    parts = f.split("/")
    key = f"{parts[1]}__{parts[-1]}"
    rep = None
    for folder in ("pass", "fail"):
        try:
            o = s3.get_object(Bucket=bucket, Key=f"inspected/{folder}/{key}.report.json")
            rep = json.loads(o["Body"].read()); break
        except s3.exceptions.NoSuchKey:
            continue
    if not rep:
        print(f"  ??   {key}  (no report yet)"); continue
    st = rep["inspection_status"]; npass += st == "PASS"; nfail += st == "FAIL"
    color = "\033[1;32m" if st == "PASS" else "\033[1;31m"
    miss = "" if not rep["missing_labels"] else f"  missing={rep['missing_labels']}"
    print(f"  {color}{st:4}\033[0m {parts[1]:30} {parts[-1]:30}{miss}")
print(f"\n  Total: {npass} PASS, {nfail} FAIL")
PY

# --- 6. where to look -----------------------------------------------------
step "Done — where everything lives"
cat <<EOF
  Source bucket    : s3://${SOURCE_BUCKET}/        (upload images here)
  Inspected bucket : s3://${INSPECTED_BUCKET}/inspected/{pass,fail}/
  CloudWatch logs  : /aws/lambda/${FUNCTION_NAME}
  Dashboard        : https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=InspectFlowAI

  Single demo image:  ./scripts/demo.sh dataset/01-compliant/compliant-pcb.png
  Tear down (save \$): DEPLOY_BUCKET=inspectflow-deploy-${ACCOUNT_ID}-${REGION} \\
                      SOURCE_BUCKET=${SOURCE_BUCKET} INSPECTED_BUCKET=${INSPECTED_BUCKET} \\
                      ./scripts/teardown.sh
EOF