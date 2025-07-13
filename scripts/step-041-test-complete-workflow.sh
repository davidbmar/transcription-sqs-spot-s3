#!/bin/bash

# step-041-test-complete-workflow.sh - Test the complete transcription workflow

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Complete Workflow Integration Test${NC}"
echo -e "${BLUE}======================================${NC}"
echo

TEST_AUDIO_FILE="test-integration-audio.mp3"
TEST_S3_INPUT="s3://${AUDIO_BUCKET}/integration-test/${TEST_AUDIO_FILE}"
TEST_S3_OUTPUT="s3://${AUDIO_BUCKET}/integration-test/transcript-$(date +%s).json"

# Cleanup function
cleanup() {
    echo -e "${YELLOW}[INFO]${NC} Cleaning up test files..."
    rm -f "$TEST_AUDIO_FILE"
    aws s3 rm "$TEST_S3_INPUT" 2>/dev/null || true
    aws s3 rm "$TEST_S3_OUTPUT" 2>/dev/null || true
}

trap cleanup EXIT

echo -e "${GREEN}[STEP 1]${NC} Creating test audio file..."
# Create a simple test audio file using sox or ffmpeg if available
if command -v sox >/dev/null 2>&1; then
    sox -n -r 44100 -c 2 "$TEST_AUDIO_FILE" synth 5 sine 440
elif command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ac 2 -ar 44100 "$TEST_AUDIO_FILE" -y
else
    echo -e "${YELLOW}[WARNING]${NC} Neither sox nor ffmpeg found, downloading test file..."
    wget -q -O "$TEST_AUDIO_FILE" "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3" || {
        echo -e "${RED}[ERROR]${NC} Could not create or download test audio"
        exit 1
    }
fi

echo -e "${GREEN}[STEP 2]${NC} Uploading test audio to S3..."
aws s3 cp "$TEST_AUDIO_FILE" "$TEST_S3_INPUT"

echo -e "${GREEN}[STEP 3]${NC} Sending transcription job to queue..."
JOB_OUTPUT=$(python3 scripts/send_to_queue.py \
    --s3_input_path "$TEST_S3_INPUT" \
    --s3_output_path "$TEST_S3_OUTPUT" \
    --estimated_duration_seconds 30 \
    --queue_url "$QUEUE_URL")

if [ $? -eq 0 ]; then
    JOB_ID=$(echo "$JOB_OUTPUT" | grep "Job ID:" | cut -d' ' -f3)
    echo -e "${GREEN}[OK]${NC} Job submitted successfully (ID: $JOB_ID)"
else
    echo -e "${RED}[ERROR]${NC} Failed to submit job"
    exit 1
fi

echo -e "${GREEN}[STEP 4]${NC} Checking queue status..."
QUEUE_DEPTH=$(aws sqs get-queue-attributes \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text)

echo -e "${GREEN}[OK]${NC} Queue has $QUEUE_DEPTH messages"

echo -e "${GREEN}[STEP 5]${NC} Checking for running workers..."
RUNNING_WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]" \
    --output text)

if [ -n "$RUNNING_WORKERS" ]; then
    echo -e "${GREEN}[OK]${NC} Found running workers:"
    echo "$RUNNING_WORKERS"
    
    echo -e "${GREEN}[STEP 6]${NC} Waiting for job processing (max 5 minutes)..."
    
    # Wait for the job to be processed
    TIMEOUT=300  # 5 minutes
    START_TIME=$(date +%s)
    
    while [ $(($(date +%s) - START_TIME)) -lt $TIMEOUT ]; do
        # Check if transcript exists
        if aws s3 ls "$TEST_S3_OUTPUT" >/dev/null 2>&1; then
            echo -e "${GREEN}[OK]${NC} Transcript created successfully!"
            echo -e "${GREEN}[INFO]${NC} Transcript location: $TEST_S3_OUTPUT"
            
            # Download and show transcript
            echo -e "${GREEN}[STEP 7]${NC} Downloading transcript..."
            aws s3 cp "$TEST_S3_OUTPUT" /tmp/test-transcript.json
            
            echo -e "${GREEN}[INFO]${NC} Transcript content:"
            jq . /tmp/test-transcript.json || cat /tmp/test-transcript.json
            
            echo
            echo -e "${GREEN}✓ Integration test PASSED${NC}"
            echo -e "${GREEN}✓ Complete workflow working correctly${NC}"
            exit 0
        fi
        
        # Check queue depth
        NEW_QUEUE_DEPTH=$(aws sqs get-queue-attributes \
            --region "$AWS_REGION" \
            --queue-url "$QUEUE_URL" \
            --attribute-names ApproximateNumberOfMessages \
            --query 'Attributes.ApproximateNumberOfMessages' \
            --output text)
        
        echo -e "${YELLOW}[INFO]${NC} Waiting... Queue depth: $NEW_QUEUE_DEPTH ($(( $TIMEOUT - $(date +%s) + $START_TIME ))s remaining)"
        sleep 10
    done
    
    echo -e "${RED}[ERROR]${NC} Timeout waiting for job completion"
    exit 1
else
    echo -e "${YELLOW}[WARNING]${NC} No workers running. Launch a worker with:"
    echo "  ./scripts/step-030-launch-spot-worker.sh"
    echo
    echo -e "${GREEN}[INFO]${NC} Job queued successfully. Will be processed when worker starts."
fi
