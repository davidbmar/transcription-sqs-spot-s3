#!/bin/bash

# Fix worker IAM policy to include ad-tra-* bucket pattern

set -e

# Load configuration
source .env

echo "🔧 Fixing Worker IAM Policy to include ad-tra-* buckets..."

# Create updated policy document
cat > /tmp/updated-worker-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Access",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::transcription-metrics-*/*",
        "arn:aws:s3:::aud-trsn-metrics-*/*",
        "arn:aws:s3:::ad-tra-*/*",
        "arn:aws:s3:::dbm-aud-tr-*/*",
        "arn:aws:s3:::dbm-cf-2-web/*",
        "arn:aws:s3:::audio-transcription-*/*",
        "arn:aws:s3:::transcription-metrics-*",
        "arn:aws:s3:::aud-trsn-metrics-*",
        "arn:aws:s3:::ad-tra-*",
        "arn:aws:s3:::dbm-aud-tr-*",
        "arn:aws:s3:::dbm-cf-2-web",
        "arn:aws:s3:::audio-transcription-*"
      ]
    },
    {
      "Sid": "SQSAccess",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ],
      "Resource": [
        "arn:aws:sqs:*:${AWS_ACCOUNT_ID}:aud-trsn-*",
        "arn:aws:sqs:*:${AWS_ACCOUNT_ID}:ad-tra-*",
        "arn:aws:sqs:*:${AWS_ACCOUNT_ID}:dbm-aud-tr-*",
        "arn:aws:sqs:*:${AWS_ACCOUNT_ID}:transcription-*",
        "arn:aws:sqs:*:${AWS_ACCOUNT_ID}:audio-transcription-*"
      ]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:${AWS_ACCOUNT_ID}:*"
    },
    {
      "Sid": "EC2Metadata",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Create new policy version
echo "📝 Creating new policy version..."
NEW_VERSION=$(aws iam create-policy-version \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionWorkerPolicy" \
    --policy-document file:///tmp/updated-worker-policy.json \
    --set-as-default \
    --query 'PolicyVersion.VersionId' \
    --output text)

echo "✅ Policy updated to version: $NEW_VERSION"
echo "✅ Workers now have access to ad-tra-* buckets"

# Cleanup
rm -f /tmp/updated-worker-policy.json

echo ""
echo "🚀 Next steps:"
echo "1. The running worker needs to be restarted to get new permissions"
echo "2. Or wait ~5 minutes for IAM changes to propagate and retry"
echo "3. Run: ./scripts/step-125-check-worker-health.sh"