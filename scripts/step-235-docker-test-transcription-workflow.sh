#!/bin/bash

# step-235-docker-test-transcription-workflow.sh - Test Docker GPU transcription workflow (PATH 200)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
echo -e "${BLUE}Test Docker GPU Transcription Workflow${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Check if test audio file exists
TEST_AUDIO="test-integration-audio.mp3"
if [ ! -f "$TEST_AUDIO" ]; then
    echo -e "${RED}[ERROR]${NC} Test audio file '$TEST_AUDIO' not found"
    echo "Place a test MP3 file in the current directory"
    exit 1
fi

echo -e "${GREEN}[STEP 1]${NC} Uploading test audio to S3..."

# Generate unique test filename
TEST_FILENAME="docker-gpu-test-$(date +%m%d-%H%M%S).mp3"
S3_INPUT_PATH="input/$TEST_FILENAME"

# Upload test file
aws s3 cp "$TEST_AUDIO" "s3://$AUDIO_BUCKET/$S3_INPUT_PATH"
echo -e "${GREEN}[OK]${NC} Test audio uploaded: s3://$AUDIO_BUCKET/$S3_INPUT_PATH"

echo -e "${GREEN}[STEP 2]${NC} Sending transcription job to SQS..."

# Generate job
JOB_ID="docker-gpu-test-$(date +%s)"
S3_OUTPUT_PATH="output/$JOB_ID-transcript.json"

# Create job message
JOB_MESSAGE=$(cat <<EOF
{
    "job_id": "$JOB_ID",
    "s3_input_path": "$S3_INPUT_PATH",
    "s3_output_path": "$S3_OUTPUT_PATH",
    "priority": 1
}
EOF
)

# Send to queue
aws sqs send-message \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --message-body "$JOB_MESSAGE"

echo -e "${GREEN}[OK]${NC} Job sent to queue: $JOB_ID"
echo "Input: s3://$AUDIO_BUCKET/$S3_INPUT_PATH"
echo "Output: s3://$AUDIO_BUCKET/$S3_OUTPUT_PATH"

echo -e "${GREEN}[STEP 3]${NC} Monitoring job processing..."

# Wait for processing
echo "Waiting for Docker GPU worker to process the job (timeout: 300 seconds)..."
TIMEOUT=300
ELAPSED=0
SLEEP_INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check if output file exists
    if aws s3 ls "s3://$AUDIO_BUCKET/$S3_OUTPUT_PATH" >/dev/null 2>&1; then
        echo -e "${GREEN}[SUCCESS]${NC} Transcription completed!"
        break
    fi
    
    echo "Waiting... ($ELAPSED/$TIMEOUT seconds)"
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${RED}[TIMEOUT]${NC} Job did not complete within $TIMEOUT seconds"
    
    # Check queue for failed messages
    echo -e "${YELLOW}[INFO]${NC} Checking queue status..."
    QUEUE_ATTRS=$(aws sqs get-queue-attributes \
        --region "$AWS_REGION" \
        --queue-url "$QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible)
    echo "$QUEUE_ATTRS"
    
    exit 1
fi

echo -e "${GREEN}[STEP 4]${NC} Downloading and verifying transcript..."

# Download transcript
TRANSCRIPT_FILE="/tmp/docker-gpu-transcript-$JOB_ID.json"
aws s3 cp "s3://$AUDIO_BUCKET/$S3_OUTPUT_PATH" "$TRANSCRIPT_FILE"

echo -e "${GREEN}[OK]${NC} Transcript downloaded: $TRANSCRIPT_FILE"

# Display transcript content
echo -e "${CYAN}[TRANSCRIPT CONTENT]${NC}"
echo "----------------------------------------"
if command -v jq >/dev/null 2>&1; then
    cat "$TRANSCRIPT_FILE" | jq -r '.transcript // .text // "No transcript found"'
else
    cat "$TRANSCRIPT_FILE"
fi
echo "----------------------------------------"

echo -e "${GREEN}[STEP 5]${NC} Performance metrics..."

# Check if metrics were uploaded
METRICS_FILE="metrics/$JOB_ID-metrics.json"
if aws s3 ls "s3://$METRICS_BUCKET/$METRICS_FILE" >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Metrics file found"
    
    # Download and display metrics
    METRICS_LOCAL="/tmp/docker-gpu-metrics-$JOB_ID.json"
    aws s3 cp "s3://$METRICS_BUCKET/$METRICS_FILE" "$METRICS_LOCAL"
    
    if command -v jq >/dev/null 2>&1; then
        echo -e "${CYAN}[METRICS]${NC}"
        echo "Processing time: $(cat "$METRICS_LOCAL" | jq -r '.processing_time_seconds // "N/A"') seconds"
        echo "Device used: $(cat "$METRICS_LOCAL" | jq -r '.device_used // "N/A"')"
        echo "Model: $(cat "$METRICS_LOCAL" | jq -r '.model_name // "N/A"')"
        echo "Audio duration: $(cat "$METRICS_LOCAL" | jq -r '.audio_duration_seconds // "N/A"') seconds"
    fi
    
    rm -f "$METRICS_LOCAL"
else
    echo -e "${YELLOW}[WARNING]${NC} No metrics file found"
fi

# Cleanup
rm -f "$TRANSCRIPT_FILE"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Docker GPU Workflow Test Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[SUMMARY]${NC}"
echo "Job ID: $JOB_ID"
echo "Processing: Successful"
echo "Device: GPU (Docker Container)"
echo "Deployment: Path 200 (Docker GPU)"
echo
echo -e "${GREEN}[CLEANUP]${NC}"
echo "Test files will remain in S3 for review:"
echo "  Input: s3://$AUDIO_BUCKET/$S3_INPUT_PATH"
echo "  Output: s3://$AUDIO_BUCKET/$S3_OUTPUT_PATH"

# Update status tracking
echo "step-235-completed=$(date)" >> .setup-status