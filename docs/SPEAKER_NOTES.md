# InspectFlowAI — Speaker Script & Q&A (15 minutes)

Word-for-word-ish narration you can read or paraphrase. Times are cumulative.
Pair this with `docs/slides.html` and the live console. Rubric weighting:
demo 70% / explanation 20% / monitoring 10% — so spend most time *showing it run*.

> Before you start: redeploy (`./scripts/deploy.sh`), confirm the SNS email if
> using one, and run `./scripts/check.sh` until it's all green. Have the
> CloudWatch log group and the dashboard open in browser tabs.

---

## 0:00–1:00 — Intro
"Hi, we're [names]. Our project automates Company X's widget quality inspection,
which today is fully manual: a worker photographs a widget, an inspector checks
that every required component is present, emails the result to Quality Control,
and the image is filed for three years of compliance. We rebuilt that as a
fully serverless, event-driven pipeline on AWS — drop an image in S3 and it gets
inspected, archived, and reported automatically, with no servers to manage."

## 1:00–4:00 — Architecture (explanation, 20%)
"Here's the flow." (Show the architecture slide and trace it.)
- "A camera on the assembly line uploads an image to an **S3** source bucket.
  That upload is our event trigger — requirement: event-based from the image."
- "S3 sends the event to an **SQS** queue. SQS decouples ingestion from
  processing and smooths bursts. A **dead-letter queue** catches anything that
  fails repeatedly so the support team can investigate — nothing is lost."
- "SQS triggers a **Lambda** function — our automated inspector. It runs only
  when an image arrives, so we pay nothing at idle."
- "Lambda calls **Amazon Rekognition** to detect the objects in the image, then
  compares them to the components a compliant widget must have."
- "It writes the original image plus a JSON report to an **inspected** S3
  bucket, split into pass and fail folders, with a lifecycle rule that moves
  data to **Glacier** and keeps it exactly **three years** for compliance."
- "It publishes the result to **SNS**, which notifies the Quality Control group."
- "And every step logs to **CloudWatch** for monitoring."
"So every customer requirement maps to a component — fully automated,
serverless, event-driven, image-recognition-based, with notification, archival,
and 3-year retention."

## 4:00–6:00 — How the decision works (explanation)
"The inspection rule is just configuration, not code." (Show the code slide.)
"We set an environment variable `EXPECTED_LABELS`. A widget passes only if
Rekognition detects all required components. We support synonym groups with a
pipe — for example `hardware|machine|motor` — because Rekognition labels a motor
assembly as 'Machine', not 'Hardware'. If any required component is missing, the
widget fails and we record exactly which one. Changing the rule is a one-line
env-var change — no redeploy."

## 6:00–11:00 — Live demo (70% — the heart of it)
"Let's run it." (Terminal + console.)

1. PASS: "I'll upload a compliant widget."
   `./scripts/demo.sh dataset/01-compliant/compliant-pcb.png`
   - Show the CloudWatch log: bucket/key, then `Inspection result: PASS`,
     `Archived -> inspected/pass/`, `Published SNS notification (PASS)`.
   - Show the object now in the `inspected/pass/` folder and open the
     `.report.json` — point out the detected labels and `missing: []`.
   - (If SNS email is set) show the email that just arrived.

2. FAIL: "Now a defective unit — missing its label."
   `./scripts/demo.sh dataset/06-non-widget/volleyball.png`  (or a hardware-only plate)
   - Show `Inspection result: FAIL`, the named missing component, and the
     artifact in `inspected/fail/`.

3. Coverage: "We tested every combination." (Show the dataset matrix slide.)
   "Twelve images: four compliant widgets and a motor gearbox pass; hardware
   without a label, a label without hardware, QR-only, text-only, and non-widget
   controls like an apple and a volleyball all fail — each with the exact reason.
   Five pass, seven fail."

4. (Optional resilience) "If we drop in a corrupt file, Lambda retries and the
   message lands in the DLQ — so bad inputs never block the line."

## 11:00–13:00 — Monitoring (10%)
"For the support team." (Open the CloudWatch dashboard `InspectFlowAI`.)
"One pane: Lambda invocations, errors, and duration; the SQS queue depth; and
the DLQ depth. We also have an alarm, `inspectflow-dlq-not-empty`, that fires
when anything lands in the dead-letter queue — that's how support gets paged if
inspections start failing. And the logs we just saw give a per-image audit trail."

## 13:00–14:00 — Security & QA
"On security: the SQS access policy only allows the S3 service to send messages,
scoped to our bucket; the Lambda runs with a least-privilege role; and data is
encrypted at rest and in transit. For QA before production, we have an automated
test suite — eleven unit tests with AWS mocked — plus this whole stack is
Infrastructure-as-Code, so it deploys identically every time."

## 14:00–15:00 — Wrap-up
"To recap: a fully automated, serverless, event-driven inspection pipeline that
meets every requirement, costs essentially nothing at idle, and is monitored and
tested. If we productionized it, the next step would be Rekognition **Custom
Labels** trained on Company X's actual widgets for component-level precision.
Thanks — happy to take questions."

---

## Anticipated Q&A

**Why SQS between S3 and Lambda instead of S3 → Lambda directly?**
Decoupling and durability: SQS buffers bursts, lets us batch, and gives us a DLQ
for failed inspections. Direct S3→Lambda has no DLQ for the source event and
less control over retries.

**How does the 3-year retention work / is it enforced?**
An S3 lifecycle rule on the inspected bucket: transition to Glacier at 30 days,
expire at 1095 days. It's automatic and applies to both the image and the report.

**What if Rekognition is wrong / what about accuracy?**
Generic `DetectLabels` is a starting point — we even saw it label a gearbox as
'Machine'. For production accuracy you'd train Rekognition **Custom Labels** on
real widget photos. Our synonym-group design is the pragmatic interim fix.

**Why did the gearbox pass but a bare bracket fail?**
The gearbox has both hardware (detected as 'Machine'/'Motor') and a QR label.
The bracket is hardware but has no label, so it fails on the missing `qr code` —
which is exactly the real-world requirement.

**Is it secure / who can trigger it?**
Only the S3 service can put messages on the queue (scoped by the access policy),
the Lambda role is least-privilege, and there are no public endpoints.

**What does it cost?**
Pay-per-use; it idles at ~$0 (no EC2, NAT, or load balancers). Well within the
$50 lab budget.

**Could it scale to a real assembly line?**
Yes — SQS + Lambda scale horizontally automatically; the batch size and Lambda
concurrency are tunable, and the queue absorbs spikes.

**How long does one inspection take?**
A couple of seconds end to end — you saw it in the logs. Lambda timeout is 30s
with generous headroom.
