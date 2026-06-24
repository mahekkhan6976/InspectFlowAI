"""
InspectFlowAI - Serverless Widget Inspection Lambda

Event flow (matches the architecture diagram):
    1. A camera on the assembly line uploads a widget image to the SOURCE S3 bucket.
    2. The S3 "ObjectCreated" event is delivered to an SQS queue.
    3. SQS triggers this Lambda (batch of records).
    4. The Lambda calls Amazon Rekognition (DetectLabels) on the image.
    5. The Lambda compares detected objects against the expected widget
       components to decide PASS / FAIL (the automated "inspection").
    6. The original image + a JSON inspection report are written to the
       INSPECTED S3 bucket (kept 3 years via a Glacier lifecycle rule).
    7. An SNS message with the result is published to the Quality Control group.

Failures bubble up so SQS can retry and eventually route the message to the
Dead Letter Queue (DLQ). All steps are logged to CloudWatch for the support team.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Explicit timeouts + retries so a slow dependency can't hang the whole invocation.
_boto_config = Config(
    connect_timeout=5,
    read_timeout=30,
    retries={"max_attempts": 3, "mode": "standard"},
)

s3 = boto3.client("s3", config=_boto_config)
rekognition = boto3.client("rekognition", config=_boto_config)
sns = boto3.client("sns", config=_boto_config)

# --- Configuration (set as Lambda environment variables) --------------------
# Components that MUST be present on a compliant widget.
#   - Comma-separated list of required components.
#   - Each component may list synonyms separated by "|"; the component is
#     satisfied if ANY synonym is detected (handles Rekognition vocabulary, e.g.
#     a motor assembly is labeled "Machine"/"Motor" rather than "Hardware").
#   Example: "hardware|machine|motor,qr code"
EXPECTED_LABELS = [
    [syn.strip().lower() for syn in group.split("|") if syn.strip()]
    for group in os.environ.get("EXPECTED_LABELS", "").split(",")
    if group.strip()
]
# Human-readable form of each requirement group (e.g. "hardware|machine|motor").
EXPECTED_LABELS_DISPLAY = ["|".join(group) for group in EXPECTED_LABELS]
# Minimum Rekognition confidence (%) for a label to count as "detected".
MIN_CONFIDENCE = float(os.environ.get("MIN_CONFIDENCE", "80"))
# Maximum number of labels Rekognition should return.
MAX_LABELS = int(os.environ.get("MAX_LABELS", "20"))
# Destination bucket for archived images + inspection reports.
INSPECTED_BUCKET = os.environ.get("INSPECTED_BUCKET", "")
# Key prefix (folder) under which inspected artifacts are stored.
INSPECTED_PREFIX = os.environ.get("INSPECTED_PREFIX", "inspected")
# SNS topic that notifies the Quality Control group.
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")


def lambda_handler(event, context):
    """Entry point. SQS may deliver several records in one invocation."""
    results = []
    for record in event.get("Records", []):
        try:
            results.extend(_process_sqs_record(record))
        except Exception:
            # Re-raise so SQS retries the batch and eventually uses the DLQ.
            logger.exception("Failed to process SQS record; will be retried / sent to DLQ.")
            raise

    return {"processed": len(results), "results": results}


def _process_sqs_record(record):
    """An SQS record can contain one or more S3 event records in its body."""
    body = json.loads(record["body"])

    # S3 test events / non-S3 messages have no "Records" array; skip them safely.
    s3_records = body.get("Records", [])
    if not s3_records:
        logger.info("SQS message had no S3 records (likely an S3 test event). Skipping.")
        return []

    outcomes = []
    for s3_record in s3_records:
        bucket = s3_record["s3"]["bucket"]["name"]
        key = _unquote_key(s3_record["s3"]["object"]["key"])
        logger.info("Inspecting image s3://%s/%s", bucket, key)
        outcomes.append(_inspect_image(bucket, key))
    return outcomes


def _inspect_image(bucket, key):
    """Run Rekognition, decide compliance, archive results, and notify."""
    detected = _detect_labels(bucket, key)
    detected_names = {label["Name"].lower() for label in detected}

    if EXPECTED_LABELS:
        # A requirement group is satisfied if ANY of its synonyms is detected.
        missing = [
            "|".join(group)
            for group in EXPECTED_LABELS
            if not any(syn in detected_names for syn in group)
        ]
    else:
        # No expectations configured: report what was found, treat as a pass.
        missing = []

    status = "PASS" if not missing else "FAIL"

    report = {
        "source_bucket": bucket,
        "source_key": key,
        "inspection_status": status,
        "inspected_at": datetime.now(timezone.utc).isoformat(),
        "expected_labels": EXPECTED_LABELS_DISPLAY,
        "missing_labels": missing,
        "detected_labels": [
            {"name": l["Name"], "confidence": round(l["Confidence"], 2)}
            for l in detected
        ],
        "min_confidence": MIN_CONFIDENCE,
    }

    logger.info("Inspection result for %s: %s", key, status)

    archived = _archive(bucket, key, report)
    report["archived_image"] = archived["image"]
    report["archived_report"] = archived["report"]

    _notify(report)
    return report


def _detect_labels(bucket, key):
    response = rekognition.detect_labels(
        Image={"S3Object": {"Bucket": bucket, "Name": key}},
        MaxLabels=MAX_LABELS,
        MinConfidence=MIN_CONFIDENCE,
    )
    return response.get("Labels", [])


def _archive(source_bucket, source_key, report):
    """Copy the original image and write the JSON report to the inspected bucket."""
    if not INSPECTED_BUCKET:
        logger.warning("INSPECTED_BUCKET not set; skipping archive step.")
        return {"image": None, "report": None}

    filename = source_key.split("/")[-1]
    status_folder = report["inspection_status"].lower()  # pass / fail
    base = f"{INSPECTED_PREFIX}/{status_folder}/{filename}"

    image_key = base
    report_key = f"{base}.report.json"

    # Copy the original image into the inspected (archive) bucket.
    s3.copy_object(
        Bucket=INSPECTED_BUCKET,
        Key=image_key,
        CopySource={"Bucket": source_bucket, "Key": source_key},
    )

    # Store the analysis results alongside the image.
    s3.put_object(
        Bucket=INSPECTED_BUCKET,
        Key=report_key,
        Body=json.dumps(report, indent=2).encode("utf-8"),
        ContentType="application/json",
    )

    logger.info("Archived image -> s3://%s/%s", INSPECTED_BUCKET, image_key)
    return {"image": image_key, "report": report_key}


def _notify(report):
    """Publish the inspection result to the Quality Control group via SNS."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set; skipping notification.")
        return

    status = report["inspection_status"]
    subject = f"[Widget Inspection] {status}: {report['source_key']}"[:100]

    if status == "PASS":
        summary = "The widget passed automated inspection. All expected components were detected."
    else:
        summary = (
            "The widget FAILED automated inspection. "
            f"Missing components: {', '.join(report['missing_labels'])}."
        )

    message = (
        f"{summary}\n\n"
        f"Source image: s3://{report['source_bucket']}/{report['source_key']}\n"
        f"Inspected at: {report['inspected_at']}\n"
        f"Archived report: s3://{INSPECTED_BUCKET}/{report.get('archived_report')}\n\n"
        f"Full result:\n{json.dumps(report, indent=2)}"
    )

    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        logger.info("Published SNS notification (%s) for %s", status, report["source_key"])
    except ClientError:
        logger.exception("Failed to publish SNS notification.")
        raise


def _unquote_key(key):
    """S3 event keys are URL-encoded (spaces become '+', etc.)."""
    from urllib.parse import unquote_plus

    return unquote_plus(key)
