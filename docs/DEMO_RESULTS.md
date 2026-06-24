# InspectFlowAI — Live Demo Results (evidence / backup)

Captured from a real run against the deployed stack in AWS account
`425652524844`, region `us-east-1`. Keep this as a backup in case the live
network/demo misbehaves during the presentation.

Configuration at run time:
- `EXPECTED_LABELS = hardware|machine|motor, qr code`  (`|` = synonyms)
- `MIN_CONFIDENCE = 80`

A compliant widget must be recognizable **hardware** (Rekognition may call a
mechanical assembly `Machine`/`Motor`) and carry a **scannable QR/label**. See
`dataset/README.md` for the full 12-image matrix across every component
combination (5 PASS / 7 FAIL).

## Case 1 — Compliant widget → PASS

![good widget](good-widget.png)

Rekognition detected `Hardware` (99.99%), `QR Code` (91.56%), `Text` (80.16%),
plus Electronics / Computer / Business Card / Paper.

```json
{
  "source_key": "demo-good-030239.png",
  "inspection_status": "PASS",
  "expected_labels": ["hardware", "qr code", "text"],
  "missing_labels": [],
  "min_confidence": 75.0
}
```

Archived to `s3://inspectflow-inspected-425652524844/inspected/pass/`.

## Case 2 — Non-compliant widget → FAIL

![bad widget](bad-widget.png)

Missing the bracket, the label, and most screws. Rekognition detected only





















`Aluminium`, `Mailbox`, `Ball/Volleyball` — none of the required components.

```json
{
  "source_key": "demo-bad-030239.png",
  "inspection_status": "FAIL",
  "expected_labels": ["hardware", "qr code", "text"],
  "missing_labels": ["hardware", "qr code", "text"],
  "min_confidence": 75.0
}
```

Archived to `s3://inspectflow-inspected-425652524844/inspected/fail/`.

## CloudWatch log trace (both cases)

```
[INFO] Inspection result for demo-good-030239.png: PASS
[INFO] Archived image -> s3://.../inspected/pass/demo-good-030239.png
[INFO] Published SNS notification (PASS) for demo-good-030239.png
[INFO] Inspection result for demo-bad-030239.png: FAIL
[INFO] Archived image -> s3://.../inspected/fail/demo-bad-030239.png
[INFO] Published SNS notification (FAIL) for demo-bad-030239.png
```

This proves the full event flow end to end: S3 upload → SQS → Lambda →
Rekognition → pass/fail archive → SNS notification, with CloudWatch monitoring.
