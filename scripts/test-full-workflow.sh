#!/bin/bash

# test-full-workflow.sh - Complete end-to-end test of the transcription system
# This script tests the entire workflow from setup to cleanup

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_AUDIO_URL="https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"
TEST_AUDIO_FILE="test-audio.mp3"
TEST_DURATION=60  # seconds

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Audio Transcription System - Full Test${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Function to cleanup on exit
cleanup() {
    echo
    echo -e "${YELLOW}[INFO]${NC} Cleaning up test resources..."
    
    # Remove test audio file
    rm -f "$TEST_AUDIO_FILE"
    
    # Remove test files from S3 if they exist
    if [ -f ".env" ]; then
        source .env
        aws s3 rm "s3://${AUDIO_BUCKET}/test/${TEST_AUDIO_FILE}" 2>/dev/null || true
        aws s3 rm "s3://${AUDIO_BUCKET}/test/${TEST_AUDIO_FILE%.mp3}-transcript.json" 2>/dev/null || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# Step 1: Check if configuration exists
echo -e "${GREEN}[STEP 1]${NC} Checking configuration..."
if [ ! -f ".env" ]; then
    echo -e "${RED}[ERROR]${NC} Configuration file .env not found!"
    echo "Please run the setup scripts first:"
    echo "  1. ./scripts/step-000-setup-configuration.sh"
    echo "  2. ./scripts/step-010-setup-iam-permissions.sh"
    echo "  3. ./scripts/step-020-create-sqs-resources.sh"
    echo "  4. ./scripts/step-025-setup-ec2-configuration.sh"
    exit 1
fi

# Load configuration
source .env

# Step 2: Verify all required variables are set
echo -e "${GREEN}[STEP 2]${NC} Verifying configuration..."
MISSING_VARS=0
for VAR in AWS_REGION QUEUE_URL AUDIO_BUCKET METRICS_BUCKET SECURITY_GROUP_ID KEY_NAME SUBNET_ID; do
    if [ -z "${!VAR}" ]; then
        echo -e "${RED}[ERROR]${NC} Missing required variable: $VAR"
        MISSING_VARS=1
    fi
done

if [ $MISSING_VARS -eq 1 ]; then
    echo -e "${RED}[ERROR]${NC} Please complete all setup steps before running tests."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Configuration verified"

# Step 3: Test AWS connectivity
echo -e "${GREEN}[STEP 3]${NC} Testing AWS connectivity..."
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Failed to connect to AWS. Check your credentials."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} AWS connectivity confirmed"

# Step 4: Verify SQS queue exists
echo -e "${GREEN}[STEP 4]${NC} Verifying SQS queue..."
QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names All 2>/dev/null)

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Cannot access SQS queue at $QUEUE_URL"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} SQS queue accessible"

# Step 5: Verify S3 buckets exist
echo -e "${GREEN}[STEP 5]${NC} Verifying S3 buckets..."
for BUCKET in "$AUDIO_BUCKET" "$METRICS_BUCKET"; do
    aws s3 ls "s3://$BUCKET" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Cannot access S3 bucket: $BUCKET"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Bucket $BUCKET accessible"
done

# Step 6: Download test audio file
echo -e "${GREEN}[STEP 6]${NC} Downloading test audio file..."
wget -q -O "$TEST_AUDIO_FILE" "$TEST_AUDIO_URL"
if [ ! -f "$TEST_AUDIO_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} Failed to download test audio file"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Test audio downloaded ($(du -h "$TEST_AUDIO_FILE" | cut -f1))"

# Step 7: Upload test audio to S3
echo -e "${GREEN}[STEP 7]${NC} Uploading test audio to S3..."
TEST_S3_INPUT="s3://${AUDIO_BUCKET}/test/${TEST_AUDIO_FILE}"
TEST_S3_OUTPUT="s3://${AUDIO_BUCKET}/test/${TEST_AUDIO_FILE%.mp3}-transcript.json"

aws s3 cp "$TEST_AUDIO_FILE" "$TEST_S3_INPUT"
if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Failed to upload test audio to S3"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Test audio uploaded to $TEST_S3_INPUT"

# Step 8: Send test job to queue
echo -e "${GREEN}[STEP 8]${NC} Sending test job to queue..."
JOB_OUTPUT=$(python3 scripts/send_to_queue.py \
    --s3_input_path "$TEST_S3_INPUT" \
    --s3_output_path "$TEST_S3_OUTPUT" \
    --estimated_duration_seconds "$TEST_DURATION" \
    --queue_url "$QUEUE_URL")

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Failed to send job to queue"
    exit 1
fi

JOB_ID=$(echo "$JOB_OUTPUT" | grep "Job ID:" | cut -d' ' -f3)
echo -e "${GREEN}[OK]${NC} Job sent successfully (ID: $JOB_ID)"

# Step 9: Check queue depth
echo -e "${GREEN}[STEP 9]${NC} Checking queue status..."
QUEUE_DEPTH=$(aws sqs get-queue-attributes \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text)

echo -e "${GREEN}[OK]${NC} Queue has $QUEUE_DEPTH messages"

# Step 10: Check for running workers
echo -e "${GREEN}[STEP 10]${NC} Checking for running workers..."
RUNNING_WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]" \
    --output text)

if [ -z "$RUNNING_WORKERS" ]; then
    echo -e "${YELLOW}[WARNING]${NC} No workers running. You need to launch a worker to process jobs:"
    echo "  ./scripts/step-030-launch-spot-worker.sh"
else
    echo -e "${GREEN}[OK]${NC} Found running workers:"
    echo "$RUNNING_WORKERS"
fi

# Step 11: Summary
echo
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo "✓ Configuration loaded successfully"
echo "✓ AWS connectivity verified"
echo "✓ SQS queue accessible"
echo "✓ S3 buckets accessible"
echo "✓ Test audio uploaded to S3"
echo "✓ Job submitted to queue"
echo
echo "Queue Status: $QUEUE_DEPTH messages waiting"
if [ -z "$RUNNING_WORKERS" ]; then
    echo "Worker Status: No workers running ⚠️"
    echo
    echo "To process the job, launch a worker:"
    echo "  ./scripts/step-030-launch-spot-worker.sh"
else
    echo "Worker Status: Workers running ✓"
    echo
    echo "The job will be processed automatically."
    echo "Check the output at: $TEST_S3_OUTPUT"
fi
echo
echo "To monitor progress:"
echo "  watch -n 5 'aws sqs get-queue-attributes --region $AWS_REGION --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages'"
echo
echo "To check for the transcript:"
echo "  aws s3 ls $TEST_S3_OUTPUT"
echo "  aws s3 cp $TEST_S3_OUTPUT - | jq ."