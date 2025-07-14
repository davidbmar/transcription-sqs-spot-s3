#!/bin/bash

# step-020-create-sqs-resources.sh - Create SQS queue and related resources for transcription system

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Use configuration values (no more hardcoded defaults)
QUEUE_NAME="${QUEUE_NAME}"
DLQ_NAME="${DLQ_NAME}"
REGION="${AWS_REGION}"
METRICS_BUCKET="${METRICS_BUCKET}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if resource exists
check_queue_exists() {
    local queue_name=$1
    aws sqs get-queue-url --queue-name "$queue_name" --region "$REGION" 2>/dev/null
}

print_status "Starting SQS resource creation..."
print_status "Configuration:"
print_status "  Region: $REGION"
print_status "  Queue Name: $QUEUE_NAME"
print_status "  DLQ Name: $DLQ_NAME"
print_status "  Metrics Bucket: $METRICS_BUCKET"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_status "AWS Account ID: $ACCOUNT_ID"

# Step 1: Create Dead Letter Queue (DLQ)
print_status "Creating Dead Letter Queue..."
if check_queue_exists "$DLQ_NAME"; then
    print_warning "DLQ '$DLQ_NAME' already exists, skipping creation"
    DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$REGION" --query 'QueueUrl' --output text)
else
    DLQ_URL=$(aws sqs create-queue \
        --queue-name "$DLQ_NAME" \
        --region "$REGION" \
        --attributes '{
            "MessageRetentionPeriod": "1209600",
            "ReceiveMessageWaitTimeSeconds": "20"
        }' \
        --query 'QueueUrl' \
        --output text)
    print_status "DLQ created: $DLQ_URL"
fi

# Get DLQ ARN
DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query 'Attributes.QueueArn' \
    --output text)

# Step 2: Create Main Queue with DLQ redrive policy
print_status "Creating Main Queue with DLQ redrive policy..."
if check_queue_exists "$QUEUE_NAME"; then
    print_warning "Queue '$QUEUE_NAME' already exists, skipping creation"
    QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" --query 'QueueUrl' --output text)
else
    QUEUE_URL=$(aws sqs create-queue \
        --queue-name "$QUEUE_NAME" \
        --region "$REGION" \
        --attributes "{
            \"MessageRetentionPeriod\": \"1209600\",
            \"VisibilityTimeout\": \"1800\",
            \"ReceiveMessageWaitTimeSeconds\": \"20\",
            \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":3}\"
        }" \
        --query 'QueueUrl' \
        --output text)
    print_status "Main queue created: $QUEUE_URL"
fi

# Get Queue ARN
QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query 'Attributes.QueueArn' \
    --output text)

# Step 3: Create metrics S3 bucket
print_status "Creating metrics S3 bucket..."
if aws s3 ls "s3://$METRICS_BUCKET" 2>/dev/null; then
    print_warning "Bucket '$METRICS_BUCKET' already exists, skipping creation"
else
    if [ "$REGION" == "us-east-1" ]; then
        aws s3 mb "s3://$METRICS_BUCKET"
    else
        aws s3 mb "s3://$METRICS_BUCKET" --region "$REGION"
    fi
    print_status "Metrics bucket created: s3://$METRICS_BUCKET"
    
    # Enable versioning on the bucket
    aws s3api put-bucket-versioning \
        --bucket "$METRICS_BUCKET" \
        --versioning-configuration Status=Enabled
    print_status "Versioning enabled on metrics bucket"
fi

# Step 4: Initialize queue metrics file
print_status "Initializing queue metrics file..."
cat > /tmp/queue-stats.json << EOF
{
  "total_minutes_pending": 0.0,
  "job_count": 0,
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "queue_arn": "$QUEUE_ARN",
  "initialized_by": "step-020-create-sqs-resources.sh"
}
EOF

aws s3 cp /tmp/queue-stats.json "s3://$METRICS_BUCKET/queue-stats.json"
rm /tmp/queue-stats.json
print_status "Queue metrics file initialized"

# Step 5: Create queue access policy (optional - for cross-account access)
print_status "Creating queue access policy..."
cat > /tmp/queue-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOwnerFullAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$ACCOUNT_ID:root"
      },
      "Action": "sqs:*",
      "Resource": "$QUEUE_ARN"
    }
  ]
}
EOF

# Create attributes file with proper format
cat > /tmp/queue-policy-attributes.json << EOF
{
  "Policy": "$(cat /tmp/queue-policy.json | jq -c . | sed 's/"/\\"/g')"
}
EOF

# Apply the policy
aws sqs set-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attributes file:///tmp/queue-policy-attributes.json \
    --region "$REGION"
rm /tmp/queue-policy.json /tmp/queue-policy-attributes.json
print_status "Queue access policy applied"

# Step 6: Update main configuration file with queue URLs
print_status "Updating main configuration file with queue URLs..."

# Update the main config file with the actual queue URLs
if [ -f "$CONFIG_FILE" ]; then
    # Use sed to update the QUEUE_URL and DLQ_URL lines
    sed -i "s|^export QUEUE_URL=.*|export QUEUE_URL=\"$QUEUE_URL\"|" "$CONFIG_FILE"
    sed -i "s|^export DLQ_URL=.*|export DLQ_URL=\"$DLQ_URL\"|" "$CONFIG_FILE"
    sed -i "s|^export QUEUE_ARN=.*|export QUEUE_ARN=\"$QUEUE_ARN\"|" "$CONFIG_FILE"
    sed -i "s|^export DLQ_ARN=.*|export DLQ_ARN=\"$DLQ_ARN\"|" "$CONFIG_FILE"
    print_status "Updated $CONFIG_FILE with queue URLs"
fi

# All configuration is now in the main .env file

# Step 7: Test the queue
print_status "Testing queue access..."

# Send a test message
TEST_MESSAGE=$(cat << EOF
{
  "job_id": "test-$(date +%s)",
  "s3_input_path": "s3://test-bucket/test-audio.mp3",
  "s3_output_path": "s3://test-bucket/test-transcript.json",
  "estimated_duration_seconds": 60,
  "priority": 1,
  "retry_count": 0,
  "submitted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

MESSAGE_ID=$(aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$TEST_MESSAGE" \
    --region "$REGION" \
    --query 'MessageId' \
    --output text)

if [ -n "$MESSAGE_ID" ]; then
    print_status "Test message sent successfully. Message ID: $MESSAGE_ID"
    
    # Delete the test message
    RECEIPT_HANDLE=$(aws sqs receive-message \
        --queue-url "$QUEUE_URL" \
        --region "$REGION" \
        --max-number-of-messages 1 \
        --query 'Messages[0].ReceiptHandle' \
        --output text)
    
    if [ "$RECEIPT_HANDLE" != "None" ] && [ -n "$RECEIPT_HANDLE" ]; then
        aws sqs delete-message \
            --queue-url "$QUEUE_URL" \
            --receipt-handle "$RECEIPT_HANDLE" \
            --region "$REGION"
        print_status "Test message deleted successfully"
    fi
else
    print_error "Failed to send test message"
fi

# Print summary
echo ""
print_status "=== SQS Resources Created Successfully ==="
echo ""
echo "Queue URL: $QUEUE_URL"
echo "DLQ URL: $DLQ_URL"
echo "Metrics Bucket: s3://$METRICS_BUCKET"
echo ""
echo "To use these resources, source the configuration file:"
echo "  source .env"
echo ""
echo "To send a message to the queue:"
echo "  python3 scripts/send_to_queue.py \\"
echo "    --queue_url \"$QUEUE_URL\" \\"
echo "    --s3_input_path \"s3://your-bucket/audio.mp3\" \\"
echo "    --s3_output_path \"s3://your-bucket/transcript.json\" \\"
echo "    --estimated_duration_seconds 60"
echo ""
echo "To check queue metrics:"
echo "  aws s3 cp s3://$METRICS_BUCKET/queue-stats.json -"
echo ""

# Save a summary file
cat > queue-resources-summary.txt << EOF
SQS Resources Created on $(date)
================================

Queue Name: $QUEUE_NAME
Queue URL: $QUEUE_URL
Queue ARN: $QUEUE_ARN

DLQ Name: $DLQ_NAME
DLQ URL: $DLQ_URL
DLQ ARN: $DLQ_ARN

Metrics Bucket: s3://$METRICS_BUCKET
Region: $REGION
Account ID: $ACCOUNT_ID

Configuration File: queue-config.env
EOF

print_status "Summary saved to queue-resources-summary.txt"

# Update setup status
echo "step-020-completed=$(date)" >> .setup-status

# Suggest next step
echo ""
print_status "=== Next Step ==="
echo ""
echo "Run the validation script to verify SQS resources:"
echo "  ./scripts/step-021-validate-sqs-resources.sh"
echo ""