"""
Local invocation helper for the inspection Lambda.

Usage:
    # Make sure your AWS credentials are exported (e.g. from the Learner Lab),
    # the source/inspected buckets exist, and an image has been uploaded.
    export EXPECTED_LABELS="screw,bracket,label"
    export INSPECTED_BUCKET="inspectflow-inspected-bucket"
    export SNS_TOPIC_ARN="arn:aws:sns:us-east-1:ACCOUNT_ID:inspectflow-quality-control"

    python tests/local_invoke.py tests/sample_sqs_event.json

This calls the real AWS APIs (Rekognition/S3/SNS) just like Lambda would, so it
is great for a live demo or QA test before promoting to production.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lambda"))

from inspection_function import lambda_handler  # noqa: E402


def main():
    event_path = sys.argv[1] if len(sys.argv) > 1 else "tests/sample_sqs_event.json"
    with open(event_path, "r", encoding="utf-8") as fh:
        event = json.load(fh)

    result = lambda_handler(event, None)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
