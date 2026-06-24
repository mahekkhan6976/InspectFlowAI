"""
Unit tests for the inspection Lambda.

AWS calls (Rekognition / S3 / SNS) are mocked, so these run anywhere with no
AWS account and no network. This is the automated QA gate the assignment asks
for ("QA test as required before moving the application into production").

Run:
    python -m unittest discover -s tests -v
"""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lambda"))

import inspection_function as fn  # noqa: E402


def make_sqs_event(bucket="src-bucket", key="widget-001.jpg"):
    s3_event = {
        "Records": [
            {"s3": {"bucket": {"name": bucket}, "object": {"key": key}}}
        ]
    }
    return {"Records": [{"body": json.dumps(s3_event)}]}


def rekognition_response(*names, confidence=95.0):
    return {"Labels": [{"Name": n, "Confidence": confidence} for n in names]}


class InspectionTestCase(unittest.TestCase):
    def setUp(self):
        # Deterministic config for every test. EXPECTED_LABELS is a list of
        # synonym groups; here each group has a single label.
        fn.EXPECTED_LABELS = [["screw"], ["bracket"], ["label"]]
        fn.EXPECTED_LABELS_DISPLAY = ["screw", "bracket", "label"]
        fn.MIN_CONFIDENCE = 80.0
        fn.MAX_LABELS = 20
        fn.INSPECTED_BUCKET = "inspected-bucket"
        fn.INSPECTED_PREFIX = "inspected"
        fn.SNS_TOPIC_ARN = "arn:aws:sns:us-east-1:123456789012:qc"

        # Replace the module-level AWS clients with mocks.
        fn.s3 = MagicMock(name="s3")
        fn.rekognition = MagicMock(name="rekognition")
        fn.sns = MagicMock(name="sns")

    def test_pass_when_all_expected_labels_present(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Screw", "Bracket", "Label", "Metal"
        )

        out = fn.lambda_handler(make_sqs_event(), None)

        report = out["results"][0]
        self.assertEqual(report["inspection_status"], "PASS")
        self.assertEqual(report["missing_labels"], [])
        # Archived under inspected/pass/
        copy_kwargs = fn.s3.copy_object.call_args.kwargs
        self.assertTrue(copy_kwargs["Key"].startswith("inspected/pass/"))
        # SNS notified once.
        fn.sns.publish.assert_called_once()

    def test_fail_when_a_label_is_missing(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Screw", "Label"  # bracket missing
        )

        out = fn.lambda_handler(make_sqs_event(), None)

        report = out["results"][0]
        self.assertEqual(report["inspection_status"], "FAIL")
        self.assertIn("bracket", report["missing_labels"])
        copy_kwargs = fn.s3.copy_object.call_args.kwargs
        self.assertTrue(copy_kwargs["Key"].startswith("inspected/fail/"))
        # SNS message should mention the missing component.
        publish_kwargs = fn.sns.publish.call_args.kwargs
        self.assertIn("bracket", publish_kwargs["Message"])

    def test_case_insensitive_matching(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "SCREW", "bracket", "LaBeL"
        )
        out = fn.lambda_handler(make_sqs_event(), None)
        self.assertEqual(out["results"][0]["inspection_status"], "PASS")

    def test_report_written_with_json_content_type(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Screw", "Bracket", "Label"
        )
        fn.lambda_handler(make_sqs_event(), None)
        put_kwargs = fn.s3.put_object.call_args.kwargs
        self.assertEqual(put_kwargs["ContentType"], "application/json")
        self.assertTrue(put_kwargs["Key"].endswith(".report.json"))
        # Body should be valid JSON.
        json.loads(put_kwargs["Body"].decode("utf-8"))

    def test_url_encoded_key_is_decoded(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Screw", "Bracket", "Label"
        )
        fn.lambda_handler(make_sqs_event(key="my+widget%282%29.jpg"), None)
        # Rekognition should be called with the decoded key.
        rek_kwargs = fn.rekognition.detect_labels.call_args.kwargs
        self.assertEqual(rek_kwargs["Image"]["S3Object"]["Name"], "my widget(2).jpg")

    def test_s3_test_event_is_skipped(self):
        # S3 sends a {"Event":"s3:TestEvent"} message with no "Records".
        event = {"Records": [{"body": json.dumps({"Event": "s3:TestEvent"})}]}
        out = fn.lambda_handler(event, None)
        self.assertEqual(out["processed"], 0)
        fn.rekognition.detect_labels.assert_not_called()

    def test_synonym_group_passes_on_any_match(self):
        # A motor assembly is labeled "Machine"/"Motor", not "Hardware".
        fn.EXPECTED_LABELS = [["hardware", "machine", "motor"], ["qr code"]]
        fn.EXPECTED_LABELS_DISPLAY = ["hardware|machine|motor", "qr code"]
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Machine", "Motor", "QR Code"
        )
        out = fn.lambda_handler(make_sqs_event(), None)
        self.assertEqual(out["results"][0]["inspection_status"], "PASS")

    def test_synonym_group_fails_when_none_match(self):
        fn.EXPECTED_LABELS = [["hardware", "machine", "motor"], ["qr code"]]
        fn.EXPECTED_LABELS_DISPLAY = ["hardware|machine|motor", "qr code"]
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Apple", "Fruit"
        )
        out = fn.lambda_handler(make_sqs_event(), None)
        report = out["results"][0]
        self.assertEqual(report["inspection_status"], "FAIL")
        self.assertIn("hardware|machine|motor", report["missing_labels"])
        self.assertIn("qr code", report["missing_labels"])

    def test_no_expected_labels_defaults_to_pass(self):
        fn.EXPECTED_LABELS = []
        fn.rekognition.detect_labels.return_value = rekognition_response("Anything")
        out = fn.lambda_handler(make_sqs_event(), None)
        self.assertEqual(out["results"][0]["inspection_status"], "PASS")

    def test_failure_propagates_for_dlq_retry(self):
        # If Rekognition errors, the handler must raise so SQS retries -> DLQ.
        fn.rekognition.detect_labels.side_effect = RuntimeError("boom")
        with self.assertRaises(RuntimeError):
            fn.lambda_handler(make_sqs_event(), None)

    def test_batch_of_multiple_records(self):
        fn.rekognition.detect_labels.return_value = rekognition_response(
            "Screw", "Bracket", "Label"
        )
        event = {
            "Records": [
                {"body": json.dumps({"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": "a.jpg"}}}]})},
                {"body": json.dumps({"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": "c.jpg"}}}]})},
            ]
        }
        out = fn.lambda_handler(event, None)
        self.assertEqual(out["processed"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
