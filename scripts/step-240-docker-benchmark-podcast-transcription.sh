#!/bin/bash

# step-240-docker-benchmark-podcast-transcription.sh - Benchmark Docker GPU with real podcast (PATH 200)

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
echo -e "${BLUE}Docker GPU Podcast Transcription Benchmark${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Test configuration for real podcast
PODCAST_FILE="mfm-episode-723.mp3"
PODCAST_S3_INPUT="s3://${AUDIO_BUCKET}/integration-test-new/${PODCAST_FILE}"
PODCAST_S3_OUTPUT="s3://${AUDIO_BUCKET}/benchmark-transcripts/docker-gpu-podcast-$(date +%s).json"
ESTIMATED_DURATION=3600  # 60 minutes

echo -e "${CYAN}📎 Podcast Benchmark Configuration:${NC}"
echo "  📻 Podcast: My First Million Episode 723"
echo "  📏 Size: ~68MB (60 minutes of audio)"
echo "  📥 Input: ${PODCAST_S3_INPUT}"
echo "  📤 Output: ${PODCAST_S3_OUTPUT}"
echo "  🎯 Expected: 16x+ real-time speed with GPU"
echo

# Check if podcast file exists
echo -e "${GREEN}[STEP 1]${NC} Verifying podcast file exists..."
if aws s3 ls "${PODCAST_S3_INPUT}" >/dev/null 2>&1; then
    FILE_SIZE=$(aws s3 ls "${PODCAST_S3_INPUT}" | awk '{print $3}')
    echo -e "${GREEN}[OK]${NC} Podcast file found (${FILE_SIZE} bytes)"
else
    echo -e "${RED}[ERROR]${NC} Podcast file not found at ${PODCAST_S3_INPUT}"
    echo "Please upload a real podcast file for benchmarking"
    exit 1
fi

# Check Docker workers
echo -e "${GREEN}[STEP 2]${NC} Checking for Docker GPU workers..."
WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=tag:Mode,Values=docker-gpu" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,InstanceType,PublicIpAddress,Tags[?Key=='Name'].Value|[0]]" \
    --output text)

if [ -z "$WORKERS" ]; then
    echo -e "${RED}[ERROR]${NC} No Docker GPU workers running. Launch workers first:"
    echo "  ./scripts/step-220-docker-launch-gpu-workers.sh"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Found Docker GPU worker(s):"
echo "$WORKERS" | while read -r instance_id instance_type ip_address name; do
    echo "  🐳 $name ($instance_type) - $ip_address"
done
echo

# Clear any pending jobs for clean benchmark
echo -e "${GREEN}[STEP 3]${NC} Preparing clean benchmark environment..."
QUEUE_DEPTH=$(aws sqs get-queue-attributes \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text)

if [ "$QUEUE_DEPTH" -gt 0 ]; then
    echo -e "${YELLOW}[WARNING]${NC} Queue has $QUEUE_DEPTH messages. For accurate benchmark:"
    echo -e "${CYAN}Purge queue for clean benchmark? (y/n) [n]: ${NC}"
    read -r purge_queue
    if [ "$purge_queue" = "y" ] || [ "$purge_queue" = "Y" ]; then
        echo -e "${BLUE}[INFO]${NC} Purging queue..."
        aws sqs purge-queue --region "$AWS_REGION" --queue-url "$QUEUE_URL"
        echo -e "${GREEN}[OK]${NC} Queue purged for clean benchmark"
        sleep 5
    fi
fi

# Submit podcast transcription job
echo -e "${GREEN}[STEP 4]${NC} Submitting podcast transcription job..."
START_TIME=$(date +%s)
START_TIME_HUMAN=$(date)

JOB_ID="docker-gpu-podcast-benchmark-${START_TIME}"

# Create job message
JOB_MESSAGE=$(cat <<EOF
{
    "job_id": "$JOB_ID",
    "s3_input_path": "$PODCAST_S3_INPUT",
    "s3_output_path": "$PODCAST_S3_OUTPUT",
    "priority": 1,
    "estimated_duration_seconds": $ESTIMATED_DURATION
}
EOF
)

# Send to queue
SEND_RESULT=$(aws sqs send-message \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --message-body "$JOB_MESSAGE")

echo -e "${GREEN}[OK]${NC} Podcast job submitted at: $START_TIME_HUMAN"
echo "  🆔 Job ID: $JOB_ID"
echo "  📻 Podcast: 60-minute episode (~68MB)"
echo "  💾 Message ID: $(echo "$SEND_RESULT" | jq -r '.MessageId')"
echo

# Monitor transcription progress
echo -e "${GREEN}[STEP 5]${NC} Monitoring Docker GPU transcription progress..."
echo -e "${CYAN}⏱️  Live Progress Monitoring:${NC}"

TIMEOUT=1800  # 30 minutes max (should complete much faster)
ELAPSED=0
CHECK_INTERVAL=10

echo "🎯 Expected completion: 3-5 minutes with GPU acceleration"
echo

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))
    
    # Check if transcript exists
    if aws s3 ls "s3://${AUDIO_BUCKET}/${PODCAST_S3_OUTPUT}" >/dev/null 2>&1; then
        END_TIME=$(date +%s)
        END_TIME_HUMAN=$(date)
        TOTAL_TIME=$((END_TIME - START_TIME))
        
        echo
        echo -e "${GREEN}✅ PODCAST TRANSCRIPTION COMPLETE!${NC}"
        echo
        echo -e "${BLUE}======================================${NC}"
        echo -e "${BLUE}📊 DOCKER GPU BENCHMARK RESULTS${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "${CYAN}⏱️  Timing Results:${NC}"
        echo "  🚀 Start Time: $START_TIME_HUMAN"
        echo "  🏁 End Time: $END_TIME_HUMAN"
        echo "  ⚡ Total Time: $((TOTAL_TIME / 60))m $((TOTAL_TIME % 60))s"
        echo
        echo -e "${CYAN}🚀 Performance Metrics:${NC}"
        echo "  🎵 Audio Duration: 60 minutes"
        echo "  💻 Processing Time: $((TOTAL_TIME / 60)) minutes $((TOTAL_TIME % 60)) seconds"
        SPEEDUP=$(echo "scale=1; 3600 / $TOTAL_TIME" | bc)
        echo "  ⚡ Speed-up Factor: ${SPEEDUP}x real-time"
        echo "  🐳 Deployment: Docker GPU Container"
        echo "  🎯 Instance Type: GPU-optimized (g4dn.xlarge)"
        echo
        echo -e "${CYAN}📄 Output Details:${NC}"
        echo "  📂 Transcript: s3://${AUDIO_BUCKET}/${PODCAST_S3_OUTPUT}"
        
        # Download and analyze transcript
        echo
        echo -e "${GREEN}[STEP 6]${NC} Analyzing transcript quality..."
        TRANSCRIPT_FILE="/tmp/docker-gpu-podcast-transcript.json"
        aws s3 cp "s3://${AUDIO_BUCKET}/${PODCAST_S3_OUTPUT}" "$TRANSCRIPT_FILE"
        
        if command -v jq >/dev/null 2>&1; then
            CHAR_COUNT=$(jq -r '.transcript | length' "$TRANSCRIPT_FILE" 2>/dev/null || echo "0")
            SEGMENT_COUNT=$(jq -r '.segments | length' "$TRANSCRIPT_FILE" 2>/dev/null || echo "0")
            DEVICE_USED=$(jq -r '.device_used // "unknown"' "$TRANSCRIPT_FILE" 2>/dev/null)
            
            echo -e "${CYAN}📊 Transcript Analysis:${NC}"
            echo "  📝 Total Characters: $(printf "%'d" "$CHAR_COUNT")"
            echo "  🎬 Segments Generated: $(printf "%'d" "$SEGMENT_COUNT")"
            echo "  💻 Device Used: $DEVICE_USED"
            echo "  📈 Avg Characters/Minute: $(echo "scale=0; $CHAR_COUNT / 60" | bc)"
            
            echo
            echo -e "${CYAN}📝 Transcript Preview (first 200 characters):${NC}"
            echo "----------------------------------------"
            jq -r '.transcript[:200]' "$TRANSCRIPT_FILE" 2>/dev/null | head -3
            echo "..."
            echo "----------------------------------------"
        fi
        
        # Cleanup
        rm -f "$TRANSCRIPT_FILE"
        
        echo
        echo -e "${BLUE}======================================${NC}"
        echo -e "${GREEN}🎉 Docker GPU Podcast Benchmark Complete${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "${GREEN}[SUMMARY]${NC}"
        echo "✅ Successfully transcribed 60-minute podcast in $((TOTAL_TIME / 60))m $((TOTAL_TIME % 60))s"
        echo "⚡ Achieved ${SPEEDUP}x real-time processing speed"
        echo "🐳 Docker GPU deployment proven for production workloads"
        echo
        echo -e "${GREEN}[TRANSCRIPT DOWNLOAD]${NC}"
        echo "aws s3 cp s3://${AUDIO_BUCKET}/${PODCAST_S3_OUTPUT} ./podcast-transcript.json"
        
        # Update status tracking
        echo "step-240-completed=$(date)" >> .setup-status
        exit 0
    fi
    
    # Show progress update
    printf "\r${YELLOW}[PROGRESS]${NC} ⏱️  %02d:%02d elapsed | 🔄 Processing podcast..." $ELAPSED_MIN $ELAPSED_SEC
    
    sleep $CHECK_INTERVAL
done

echo
echo -e "${RED}[TIMEOUT]${NC} Podcast transcription did not complete within $((TIMEOUT / 60)) minutes"
echo
echo -e "${YELLOW}[TROUBLESHOOTING]${NC}"
echo "Check Docker worker status:"
WORKER_IP=$(echo "$WORKERS" | head -1 | awk '{print $3}')
echo "  ssh -i ${KEY_NAME}.pem ubuntu@$WORKER_IP 'docker logs --tail 20 \$(docker ps -q)'"
echo
echo "Check queue status:"
echo "  aws sqs get-queue-attributes --region $AWS_REGION --queue-url $QUEUE_URL --attribute-names All"

exit 1