#!/bin/bash

# step-135-test-complete-workflow.sh - Test complete DLAMI transcription workflow (PATH 100)

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
    
    # Extract worker IP for health checks
    WORKER_IP=$(echo "$RUNNING_WORKERS" | awk '{print $3}' | head -1)
    
    echo -e "${GREEN}[STEP 6A]${NC} Performing incremental worker health checks..."
    
    # Function to check worker health and return status
    check_worker_health() {
        local check_time=$1
        echo -e "${BLUE}[HEALTH CHECK - ${check_time}]${NC} Checking worker status..."
        
        WORKER_PROCESS=$(ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'ps aux | grep transcription_worker | grep -v grep' 2>/dev/null || echo "NONE")
        
        if [ "$WORKER_PROCESS" = "NONE" ]; then
            echo -e "${RED}[ERROR]${NC} Worker process not running at ${check_time}!"
            
            echo -e "${YELLOW}[DIAGNOSIS]${NC} Retrieving crash logs..."
            ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'tail -20 /var/log/transcription-worker.log' 2>/dev/null || echo "No worker logs found"
            
            echo -e "${YELLOW}[DIAGNOSIS]${NC} Checking setup logs..."
            ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'sudo tail -10 /var/log/dlami-worker-setup.log' 2>/dev/null || echo "No setup logs found"
            
            echo
            echo -e "${RED}[PROBLEM IDENTIFIED]${NC} Worker crashed during initialization!"
            echo -e "${YELLOW}[COMMON CAUSES]${NC}"
            echo "1. cuDNN version mismatch (PyTorch expects v8.x, DLAMI has v9.x)"
            echo "2. GPU memory issues or CUDA driver problems"
            echo "3. Model download or loading failures"
            echo
            echo -e "${BLUE}[SOLUTIONS]${NC}"
            echo "• Check if cuDNN 8.x was properly installed in launch script"
            echo "• Try launching with --cpu-only flag to bypass GPU issues"
            echo "• Review launch script cuDNN installation logic"
            echo "• Consider using Docker deployment path (200-series) for controlled environment"
            echo
            echo -e "${GREEN}[NEXT STEPS]${NC}"
            echo "1. Terminate crashed worker: aws ec2 terminate-instances --region $AWS_REGION --instance-ids <instance-id>"
            echo "2. Fix launch script cuDNN installation"
            echo "3. Re-launch worker: ./scripts/launch-dlami-ondemand-worker.sh"
            echo "4. Re-run this test: ./scripts/step-135-test-complete-workflow.sh"
            
            return 1
        fi
        
        # Check memory usage to verify model loading progress
        MEMORY_USAGE=$(ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP "ps -o pid,pmem,rss,args -p \$(pgrep -f transcription_worker) | tail -1" 2>/dev/null)
        
        if [ -n "$MEMORY_USAGE" ]; then
            RSS_MB=$(echo "$MEMORY_USAGE" | awk '{printf "%.0f", $3/1024}')
            echo -e "${GREEN}[OK]${NC} Worker running with ${RSS_MB}MB memory at ${check_time}"
            
            if [ "$RSS_MB" -gt 1000 ]; then
                echo -e "${GREEN}[OK]${NC} High memory usage - model loaded and ready!"
                return 0
            else
                echo -e "${YELLOW}[INFO]${NC} Low memory usage - model may still be loading..."
                return 2  # Still loading
            fi
        fi
        
        return 2  # Unknown state, continue monitoring
    }
    
    # Check at 30 seconds
    echo -e "${BLUE}[INFO]${NC} Waiting 30 seconds for initial worker startup..."
    sleep 30
    check_worker_health "30 seconds"
    HEALTH_30=$?
    
    if [ $HEALTH_30 -eq 1 ]; then
        exit 1  # Worker crashed
    elif [ $HEALTH_30 -eq 0 ]; then
        echo -e "${GREEN}[FAST STARTUP]${NC} Worker ready in 30 seconds! Proceeding to job processing..."
    else
        # Check at 1 minute
        echo -e "${BLUE}[INFO]${NC} Waiting additional 30 seconds (total: 1 minute)..."
        sleep 30
        check_worker_health "1 minute"
        HEALTH_60=$?
        
        if [ $HEALTH_60 -eq 1 ]; then
            exit 1  # Worker crashed
        elif [ $HEALTH_60 -eq 0 ]; then
            echo -e "${GREEN}[READY]${NC} Worker fully loaded at 1 minute! Proceeding..."
        else
            # Check at 1:30
            echo -e "${BLUE}[INFO]${NC} Waiting additional 30 seconds (total: 1:30)..."
            sleep 30
            check_worker_health "1 minute 30 seconds"
            HEALTH_90=$?
            
            if [ $HEALTH_90 -eq 1 ]; then
                exit 1  # Worker crashed
            elif [ $HEALTH_90 -eq 0 ]; then
                echo -e "${GREEN}[READY]${NC} Worker loaded at 1:30! Proceeding..."
            else
                echo -e "${YELLOW}[WARNING]${NC} Worker still loading after 1:30, but proceeding with test..."
            fi
        fi
    fi
    
    echo -e "${GREEN}[STEP 6B]${NC} Worker health checks completed! Starting job processing monitor..."
    echo -e "${GREEN}[INFO]${NC} Waiting for job processing (max 5 minutes)..."
    
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
        
        # Periodic worker health check during processing
        ELAPSED=$(( $(date +%s) - START_TIME ))
        if [ $((ELAPSED % 60)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
            WORKER_CHECK=$(ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'pgrep -f transcription_worker' 2>/dev/null || echo "DEAD")
            if [ "$WORKER_CHECK" = "DEAD" ]; then
                echo -e "${RED}[ERROR]${NC} Worker process died during job processing!"
                echo -e "${YELLOW}[DIAGNOSIS]${NC} Last 10 lines of worker logs:"
                ssh -i ${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'tail -10 /var/log/transcription-worker.log' 2>/dev/null
                echo -e "${RED}[FAILURE]${NC} Worker crashed - integration test failed"
                exit 1
            fi
        fi
        
        echo -e "${YELLOW}[INFO]${NC} Waiting... Queue depth: $NEW_QUEUE_DEPTH ($(( $TIMEOUT - $(date +%s) + $START_TIME ))s remaining)"
        sleep 10
    done
    
    echo -e "${RED}[ERROR]${NC} Timeout waiting for job completion"
    exit 1
else
    echo -e "${YELLOW}[WARNING]${NC} No workers running. Launch a worker with:"
    echo "  ./scripts/step-120-launch-dlami-ondemand-worker.sh"
    echo
    echo -e "${GREEN}[INFO]${NC} Job queued successfully. Will be processed when worker starts."
fi

# Auto-detect and show next step
if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
    source "$(dirname "$0")/next-step-helper.sh"
    show_next_step "$0" "$(dirname "$0")"
fi
