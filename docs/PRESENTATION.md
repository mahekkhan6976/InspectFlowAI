# InspectFlowAI — 15-Minute Class Presentation Script

Maps directly to the rubric:
- **70%** Demonstration of the functioning solution
- **20%** Explanation of the solution components
- **10%** Demonstration of the monitoring

> This is the outline. For a word-for-word spoken script with timing and a Q&A
> prep section, see `docs/SPEAKER_NOTES.md`.

---

## 0. Intro (1 min)
- Team + problem: Company X manually inspects widget photos. We automated it
  end-to-end with a serverless, event-driven AWS architecture.
- One sentence: "Drop an image in S3 → it gets inspected by Rekognition →
  results archived for 3 years → QC group notified, with zero servers."

## 1. Architecture walkthrough (3 min) — *Explanation: 20%*
Show the diagram and trace the flow component by component:
1. **S3 source bucket** — the assembly-line camera's upload target.
2. **S3 event → SQS** — decouples ingestion from processing; smooths bursts.
3. **SQS + DLQ** — reliable delivery; failed inspections go to the DLQ for
   the support team instead of being lost.
4. **Lambda** — the inspection brain; runs only when an image arrives.
5. **Rekognition DetectLabels** — the automated "inspector".
6. **Inspected S3 bucket + Glacier lifecycle** — compliance storage for 3 years.
7. **SNS** — notifies the Quality Control group of PASS/FAIL.
8. **CloudWatch** — observability for support.

Tie each back to a customer requirement (use the table in the README).

## 2. Live demo — happy path PASS (4 min) — *Demonstration: 70%*
1. Show the empty `inspected/` folder and the SQS queue at 0 messages.
2. Upload `good-widget.jpg` (contains all expected components) to the source bucket.
3. Show SQS "Messages available" briefly spike then return to 0 (Lambda consumed it).
4. Open the Lambda's CloudWatch log stream: point out the logged bucket/key,
   the detected labels, and `Inspection result: PASS`.
5. Show the new object in `inspected/pass/` — both the image and the
   `.report.json` with detected labels + confidence.
6. Show the **email** that arrived to the QC group via SNS.

## 3. Live demo — failure path FAIL (3 min) — *Demonstration: 70%*
1. Upload `bad-widget.jpg` (missing a required component, e.g. no `bracket`).
2. Show CloudWatch log: `Inspection result: FAIL`, missing labels listed.
3. Show the object lands in `inspected/fail/` and the SNS email states which
   component is missing.
4. (Optional) Show the DLQ: upload a corrupt/non-image file and show the message
   retried and routed to the DLQ — proving resilience.

## 4. Monitoring & security (2 min) — *Monitoring: 10%*
- **CloudWatch dashboard `InspectFlowAI`**: open it live — Lambda
  Invocations/Errors/Duration, SQS queue depth, and DLQ depth on one screen.
- **Alarm `inspectflow-dlq-not-empty`**: explain it goes to ALARM when an image
  fails inspection 3x and lands in the DLQ (show it flip after the DLQ demo).
- **CloudWatch Logs**: per-invocation bucket/key + PASS/FAIL trace.
- **Security**: show the SQS access policy (S3 principal restriction) and the
  least-privilege IAM policy intent; mention S3 encryption (SSE-SQS / SSE-S3).

## 5. Wrap-up (1 min)
- Recap requirements satisfied + cost (idles at ~$0, well within the $50 cap).
- Future ideas: Rekognition Custom Labels trained on real widgets, Step
  Functions for multi-stage inspection, CloudFormation/IaC for repeatable deploys.

---

### Pre-demo checklist
- [ ] Source + inspected buckets created
- [ ] SNS subscription **confirmed** (check the email link!)
- [ ] SQS access policy applied + S3 event notification wired
- [ ] Lambda env vars set (`EXPECTED_LABELS`, `INSPECTED_BUCKET`, `SNS_TOPIC_ARN`)
- [ ] Two test images ready (one passing, one failing)
- [ ] CloudWatch log group open in a tab
- [ ] Learner Lab session timer reset (4-hour limit)
