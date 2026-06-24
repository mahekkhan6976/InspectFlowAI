# InspectFlowAI — Serverless Widget Inspection

A fully serverless, event-driven AWS architecture that automates the manual
widget quality-inspection process for "Company X". A camera on the assembly
line uploads an image; the system automatically inspects it with Amazon
Rekognition, decides PASS/FAIL, archives the image + results for 3 years, and
notifies the Quality Control group — with no servers to manage.

## Architecture

```
[Assembly-line camera]
        |
        v  (1) upload image
+-------------------+        (2) S3 PUT event       +-------------------+
|  S3 SOURCE bucket | ----------------------------> |   SQS queue       |
+-------------------+                                +-------------------+
                                                       |            |
                                          (3) trigger  |            | failures
                                                       v            v
                                            +---------------+   +-----------+
                                            | Lambda        |   | SQS DLQ   |
                                            | (inspection)  |   +-----------+
                                            +---------------+
                                              |   |      |
                            (4) DetectLabels  |   |      | (6) notify
                                              v   |      v
                                  +----------------+   +-------------------+
                                  | Rekognition    |   | SNS topic         |
                                  +----------------+   | (Quality Control) |
                                              |        +-------------------+
                            (5) archive image |                 |
                                + report      v                 v
                                  +-------------------+   [QC group email/SMS]
                                  | S3 INSPECTED      |
                                  | bucket            |
                                  | -> Glacier (3 yr) |
                                  +-------------------+

         CloudWatch Logs <---- every step (monitoring for the support team)
```

### How each customer requirement is met

| Requirement | How it's satisfied |
|---|---|
| Fully automated inspection | S3 upload → SQS → Lambda → Rekognition with zero human steps |
| Serverless + best practices | S3, SQS, Lambda, Rekognition, SNS, Glacier — no servers; decoupled via queue |
| Event-based starting from the image | S3 `ObjectCreated:Put` event drives the whole flow |
| Image recognition inspection | Rekognition `DetectLabels` compares detected vs. expected components |
| Notify Quality Control group | SNS topic with the PASS/FAIL result and details |
| Store results + image in "inspected" folder | Lambda copies image + writes JSON report to the inspected bucket |
| 3-year compliance retention | S3 lifecycle: transition to Glacier, expire after 1095 days |
| Monitoring (support team) | CloudWatch dashboard `InspectFlowAI` + DLQ alarm + Lambda logs |
| Security (support team) | Least-privilege IAM role + SQS access policy restricting S3 principal |
| QA before production | `tests/local_invoke.py` + a test image, validated before go-live |

## Repository layout

```
template.yaml                          # SAM/CloudFormation: deploy the whole stack
scripts/deploy.sh                      # One-command deploy (uses LabRole)
scripts/demo.sh                        # One-command live demo (upload + tail logs)
scripts/detect.sh                      # Discover Rekognition labels for an image
scripts/check.sh                       # Pre-demo readiness check
scripts/teardown.sh                    # Empty buckets + delete the stack
docs/slides.md                         # Marp slide deck (renders to PDF/PPTX)
lambda/inspection_function.py          # The Lambda (core deliverable)
infrastructure/sqs-access-policy.json  # SQS policy fix (allows S3 to send)
infrastructure/lambda-execution-policy.json   # Least-privilege IAM policy
infrastructure/s3-lifecycle-3yr-retention.json # Glacier + 3yr expiration
dataset/                               # Labeled widget images (all combinations) + results matrix
tests/test_inspection.py               # Unit tests (mocked AWS) — offline QA gate
tests/sample_sqs_event.json            # Sample event for local testing
tests/local_invoke.py                  # Run the handler locally against AWS
docs/PRESENTATION.md                   # 15-minute demo outline (rubric-mapped)
docs/SPEAKER_NOTES.md                  # Word-for-word speaker script + Q&A prep
```

## Lambda environment variables

| Variable | Example | Purpose |
|---|---|---|
| `EXPECTED_LABELS` | `hardware\|machine\|motor,qr code` | Required components (comma); `\|` = synonyms within a component |
| `MIN_CONFIDENCE` | `80` | Min Rekognition confidence (%) to count a label |
| `MAX_LABELS` | `20` | Max labels Rekognition returns |
| `INSPECTED_BUCKET` | `inspectflow-inspected-bucket` | Archive/compliance bucket |
| `INSPECTED_PREFIX` | `inspected` | Folder prefix in the inspected bucket |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:...:inspectflow-quality-control` | QC notifications |

## Option A — Deploy with one command (AWS SAM)

This is the fastest path and is reproducible. The template uses the Learner Lab's
existing **LabRole** (the lab blocks creating new IAM roles), so pass its ARN.

```bash
# 1. Install the SAM CLI (one time): https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html
# 2. Export your Learner Lab credentials (copy from "AWS Details" in the lab).
# 3. Deploy:
LAB_ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/LabRole" \
QC_EMAIL="you@example.com" \
SOURCE_BUCKET="inspectflow-source-yourname" \
INSPECTED_BUCKET="inspectflow-inspected-yourname" \
EXPECTED_LABELS="screw,bracket,label" \
./scripts/deploy.sh
```

Then **confirm the SNS subscription email**, upload an image to the source
bucket, and watch the pipeline run. To remove everything and protect your
budget:

```bash
SOURCE_BUCKET="inspectflow-source-yourname" \
INSPECTED_BUCKET="inspectflow-inspected-yourname" \
./scripts/teardown.sh
```

The whole stack (`template.yaml`) creates the source bucket + S3→SQS
notification, the queue + DLQ + access policy, the inspected bucket with the
3-year Glacier lifecycle, the SNS topic + subscription, and the Lambda with its
SQS trigger and environment variables.

## Option B — Setup via the AWS Console

> In the AWS Academy Learner Lab, attach the existing **LabRole** to the Lambda
> instead of creating a new role (you can't create IAM roles in the lab). The
> `lambda-execution-policy.json` documents the least-privilege intent for a real
> production account.

1. **S3 buckets** — create `inspectflow-source-bucket` and
   `inspectflow-inspected-bucket` (use globally-unique names).
2. **SNS** — create a Standard topic `inspectflow-quality-control` and
   subscribe the QC group's email; confirm the subscription.
3. **SQS** — create a Standard queue `inspectflow-queue` and a second queue
   `inspectflow-dlq`. On the main queue, set the DLQ as the dead-letter target
   (e.g. maxReceiveCount = 3).
4. **SQS access policy** — on `inspectflow-queue`, open **Access policy** and
   paste `infrastructure/sqs-access-policy.json` (replace `ACCOUNT_ID` and the
   bucket/queue names). This is the fix from the professor's slides: the
   principal must be `"Service": "s3.amazonaws.com"` so S3 can send the PUT event.
5. **S3 → SQS event** — on `inspectflow-source-bucket`, add an event
   notification for **All object create events** with the SQS queue as the
   destination.
6. **Lambda** — create a Python function, paste `lambda/inspection_function.py`,
   set the environment variables above, attach **LabRole**, and add the SQS
   queue as a **trigger**.
7. **Lifecycle rule** — on `inspectflow-inspected-bucket`, add the lifecycle
   rule from `infrastructure/s3-lifecycle-3yr-retention.json` (Glacier + 3-year
   expiration on the `inspected/` prefix).

## Demo / QA test

Upload a widget image to `inspectflow-source-bucket` and watch:
- the SQS queue receive then drain the message,
- the Lambda CloudWatch logs print the bucket/key and PASS/FAIL,
- the `inspected/pass/` or `inspected/fail/` folder fill with the image + report,
- the QC email arrive via SNS.

### One-command live demo

After deploying, run the whole demo (upload + tail logs + list artifacts) with:

```bash
SOURCE_BUCKET="inspectflow-source-yourname" \
INSPECTED_BUCKET="inspectflow-inspected-yourname" \
./scripts/demo.sh path/to/good-widget.jpg
# then again with a failing image:
./scripts/demo.sh path/to/bad-widget.jpg
```

It uploads the image, tails the Lambda's CloudWatch logs so the PASS/FAIL line
shows live in class, and then lists the `inspected/` artifacts.

### Choosing EXPECTED_LABELS (important for a clean demo)

Stock Rekognition returns generic labels, so set `EXPECTED_LABELS` to what it
actually detects on your real widget photos:

```bash
./scripts/detect.sh path/to/real-widget.jpg 80
```

Pick a few labels that appear on a *compliant* widget but where at least one is
absent on a *non-compliant* one. `EXPECTED_LABELS` supports **synonym groups**:
comma separates required components, and `|` lists synonyms within a component
that satisfy it (e.g. `hardware|machine|motor,qr code` — handy because
Rekognition labels a motor assembly `Machine`, not `Hardware`). Then update the
live Lambda (no redeploy):

```bash
# Lambda console -> inspectflow-inspection -> Configuration -> Environment variables
# edit EXPECTED_LABELS, e.g. "circuit board,screw,label"
```

### Monitoring

The stack deploys a CloudWatch dashboard named **InspectFlowAI** (Lambda
invocations/errors/duration, SQS queue depth, DLQ depth) and an alarm
**inspectflow-dlq-not-empty** that fires when an image repeatedly fails
inspection. Show these live for the monitoring portion of the rubric.

### Slides

`docs/slides.md` is a [Marp](https://marp.app/) deck. Render it with the Marp
VS Code extension (preview/export to PDF/PPTX) or the Marp CLI:

```bash
npx @marp-team/marp-cli docs/slides.md -o docs/slides.pdf
```

### Unit tests (offline QA gate)

These mock all AWS calls, so they run with no account and no network. This is
the "QA test before production" the assignment requires:

```bash
python3 -m unittest discover -s tests -p "test_*.py" -v
```

### Pre-demo readiness check

Before presenting, confirm everything is wired up (tooling, credentials, stack,
buckets, Lambda, and a confirmed SNS subscription):

```bash
SOURCE_BUCKET="inspectflow-source-yourname" \
INSPECTED_BUCKET="inspectflow-inspected-yourname" \
./scripts/check.sh
```

### Local logic test

To test the logic locally against real AWS services:

```bash
pip install -r requirements.txt
export EXPECTED_LABELS="screw,bracket,label"
export INSPECTED_BUCKET="inspectflow-inspected-bucket"
export SNS_TOPIC_ARN="arn:aws:sns:us-east-1:ACCOUNT_ID:inspectflow-quality-control"
python tests/local_invoke.py tests/sample_sqs_event.json
```

## Cost note (Learner Lab — $50 cap)

This stack is pay-per-use and idles at ~$0. Delete the S3 event/objects and the
SNS subscription when done; nothing here runs continuously (no EC2/NAT/ELB).
