#!/bin/bash

# step-140-benchmark-podcast-transcription.sh - Benchmark real podcast transcription (PATH 100)

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
echo -e "${BLUE}Podcast Transcription Benchmark Test${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Test configuration
PODCAST_FILE="mfm-episode-723.mp3"
PODCAST_S3_PATH="s3://${AUDIO_BUCKET}/integration-test-new/${PODCAST_FILE}"
OUTPUT_S3_PATH="s3://${AUDIO_BUCKET}/benchmark-transcripts/${PODCAST_FILE%.mp3}-$(date +%s).json"
ESTIMATED_DURATION=3600  # 1 hour podcast

echo -e "${CYAN}📎 Test Configuration:${NC}"
echo "  Podcast: ${PODCAST_FILE}"
echo "  Size: ~68MB"
echo "  Estimated Duration: 60 minutes"
echo "  S3 Input: ${PODCAST_S3_PATH}"
echo "  S3 Output: ${OUTPUT_S3_PATH}"
echo

# Check if worker is running
echo -e "${GREEN}[STEP 1]${NC} Checking for running workers..."
WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,InstanceType,PublicIpAddress]" \
    --output text)

if [ -z "$WORKERS" ]; then
    echo -e "${RED}[ERROR]${NC} No workers running. Launch a worker first:"
    echo "  ./scripts/step-120-launch-dlami-ondemand-worker.sh"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Found worker(s):"
echo "$WORKERS"
echo

# Get worker details for monitoring
WORKER_IP=$(echo "$WORKERS" | head -1 | awk '{print $3}')
INSTANCE_TYPE=$(echo "$WORKERS" | head -1 | awk '{print $2}')

echo -e "${GREEN}[STEP 2]${NC} Clearing queue of any pending jobs..."
QUEUE_DEPTH=$(aws sqs get-queue-attributes \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text)

if [ "$QUEUE_DEPTH" -gt 0 ]; then
    echo -e "${YELLOW}[WARNING]${NC} Queue has $QUEUE_DEPTH messages. Consider purging for clean benchmark."
fi

# Submit job and record start time
echo -e "${GREEN}[STEP 3]${NC} Submitting podcast transcription job..."
START_TIME=$(date +%s)
START_TIME_HUMAN=$(date)

JOB_OUTPUT=$(python3 scripts/send_to_queue.py \
    --s3_input_path "$PODCAST_S3_PATH" \
    --s3_output_path "$OUTPUT_S3_PATH" \
    --estimated_duration_seconds "$ESTIMATED_DURATION" \
    --queue_url "$QUEUE_URL")

JOB_ID=$(echo "$JOB_OUTPUT" | grep "Job ID:" | cut -d' ' -f3)
echo -e "${GREEN}[OK]${NC} Job submitted at: $START_TIME_HUMAN"
echo "  Job ID: $JOB_ID"
echo

# Monitor progress
echo -e "${GREEN}[STEP 4]${NC} Monitoring transcription progress..."
echo -e "${CYAN}⏱️  Live Progress Updates:${NC}"

# Function to check worker logs
check_worker_progress() {
    ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$WORKER_IP" \
        'tail -10 /var/log/transcription-worker.log | grep -E "(Progress|Step|Complete|ERROR|transcribing)"' 2>/dev/null || true
}

# Monitor loop
TIMEOUT=7200  # 2 hours max
ELAPSED=0
CHECK_INTERVAL=30
LAST_PROGRESS=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))
    
    # Check if transcript exists
    if aws s3 ls "$OUTPUT_S3_PATH" >/dev/null 2>&1; then
        END_TIME=$(date +%s)
        END_TIME_HUMAN=$(date)
        TOTAL_TIME=$((END_TIME - START_TIME))
        
        echo
        echo -e "${GREEN}✅ TRANSCRIPTION COMPLETE!${NC}"
        echo
        echo -e "${BLUE}======================================${NC}"
        echo -e "${BLUE}📊 BENCHMARK RESULTS${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "${CYAN}⏱️  Timing:${NC}"
        echo "  Start Time: $START_TIME_HUMAN"
        echo "  End Time: $END_TIME_HUMAN"
        echo "  Total Time: $((TOTAL_TIME / 60))m $((TOTAL_TIME % 60))s"
        echo
        echo -e "${CYAN}🚀 Performance:${NC}"
        echo "  Audio Duration: 60 minutes (estimated)"
        echo "  Processing Time: $((TOTAL_TIME / 60)) minutes"
        echo "  Speed-up Factor: $(echo "scale=2; 3600 / $TOTAL_TIME" | bc)x real-time"
        echo "  Instance Type: $INSTANCE_TYPE"
        echo
        echo -e "${CYAN}📄 Output:${NC}"
        echo "  Transcript Location: $OUTPUT_S3_PATH"
        
        # Download and show sample
        echo
        echo -e "${GREEN}[STEP 5]${NC} Downloading transcript sample..."
        aws s3 cp "$OUTPUT_S3_PATH" /tmp/benchmark-transcript.json
        
        echo -e "${CYAN}📝 Transcript Preview:${NC}"
        jq -r '.text[:500]' /tmp/benchmark-transcript.json 2>/dev/null || \
            jq -r '.segments[0:3]' /tmp/benchmark-transcript.json 2>/dev/null || \
            head -5 /tmp/benchmark-transcript.json
        
        # Cleanup
        rm -f /tmp/benchmark-transcript.json
        
        echo
        echo -e "${BLUE}======================================${NC}"
        echo -e "${GREEN}🎉 Benchmark test completed successfully!${NC}"
        
        # Auto-detect and show next step
        if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
            source "$(dirname "$0")/next-step-helper.sh"
            show_next_step "$0" "$(dirname "$0")"
        fi
        
        exit 0
    fi
    
    # Show progress update
    printf "\r${YELLOW}[PROGRESS]${NC} Elapsed: %02d:%02d | Queue: " $ELAPSED_MIN $ELAPSED_SEC
    aws sqs get-queue-attributes \
        --region "$AWS_REGION" \
        --queue-url "$QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
        --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' \
        --output text | tr '\t' '/'
    
    # Check worker progress every minute
    if [ $((ELAPSED % 60)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        echo
        PROGRESS=$(check_worker_progress)
        if [ -n "$PROGRESS" ] && [ "$PROGRESS" != "$LAST_PROGRESS" ]; then
            echo -e "${CYAN}Worker Update:${NC}"
            echo "$PROGRESS"
            LAST_PROGRESS="$PROGRESS"
        fi
    fi
    
    sleep $CHECK_INTERVAL
done

echo
echo -e "${RED}[ERROR]${NC} Timeout waiting for transcription to complete"
echo "Check worker logs: ssh -i ${KEY_NAME}.pem ubuntu@$WORKER_IP 'tail -50 /var/log/transcription-worker.log'"
exit 1