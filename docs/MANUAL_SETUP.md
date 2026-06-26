# Manual setup in the AWS console

`template.yaml` creates everything with one command (see the README). This page
builds the same pipeline by hand, which is useful for understanding each piece,
or for an account where CloudFormation is not an option.

> In the AWS Academy Learner Lab you cannot create IAM roles: attach the
> existing **LabRole** to the Lambda. `infrastructure/lambda-execution-policy.json`
> documents the least-privilege policy to use in a regular account.

1. **S3 buckets** — create a source bucket (for example
   `inspectflow-source-<account>`) and an inspected bucket
   (`inspectflow-inspected-<account>`). Bucket names must be globally unique.
2. **SNS** — create a Standard topic `inspectflow-quality-control` and subscribe
   the quality-control email address; confirm the subscription from the email.
3. **SQS** — create Standard queues `inspectflow-queue` and `inspectflow-dlq`.
   On the main queue set the DLQ as the dead-letter target with
   `maxReceiveCount = 3`, and set the visibility timeout to at least 6× the
   Lambda timeout (180 s for a 30 s Lambda).
4. **SQS access policy** — on `inspectflow-queue`, paste
   `infrastructure/sqs-access-policy.json` (replace `ACCOUNT_ID` and the
   bucket/queue names). The principal must be the S3 service
   (`s3.amazonaws.com`), scoped by `aws:SourceArn` to the source bucket;
   without it S3 silently fails to deliver events.
5. **S3 → SQS event** — on the source bucket, add an event notification for
   *All object create events* with the queue as the destination.
6. **Lambda** — create a Python 3.12 function, paste
   `lambda/inspection_function.py`, set the environment variables from the
   README's *Configuration* table, attach the execution role, and add the SQS
   queue as a trigger (batch size 10).
7. **Lifecycle rule** — on the inspected bucket, add the rule from
   `infrastructure/s3-lifecycle-3yr-retention.json` (Glacier after 30 days,
   expire after 1095 days, prefix `inspected/`).
8. **Monitoring** — create a CloudWatch alarm on the DLQ's
   `ApproximateNumberOfMessagesVisible ≥ 1` with the SNS topic as its action,
   and optionally a dashboard with Lambda invocations / errors / duration and
   the two queue depths.

## Verify

Upload an image to the source bucket and watch:

- the queue receive, then drain, the message;
- the Lambda's CloudWatch log print the key and `Inspection result: PASS` or
  `FAIL`;
- `inspected/pass/` or `inspected/fail/` fill with the image and its
  `.report.json`;
- the quality-control email arrive.

`scripts/check.sh` automates these checks against a deployed stack.
