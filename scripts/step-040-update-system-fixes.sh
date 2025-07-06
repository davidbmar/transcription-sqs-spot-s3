#!/bin/bash

# step-040-update-system-fixes.sh - Apply fixes discovered during testing

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Applying system fixes and updates..."
echo -e "${GREEN}[INFO]${NC} AWS Region: $AWS_REGION"

# Fix 1: Update IAM worker policy to include access to metrics bucket pattern
echo -e "${GREEN}[STEP 1]${NC} Updating IAM worker policy for metrics bucket access..."

# Get current policy version
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionWorkerPolicy"

# Check if policy exists
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} Updating existing worker policy..."
    
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
        "arn:aws:s3:::${AUDIO_BUCKET}/*",
        "arn:aws:s3:::audio-transcription-*/*",
        "arn:aws:s3:::transcription-metrics-*",
        "arn:aws:s3:::aud-trsn-metrics-*",
        "arn:aws:s3:::${AUDIO_BUCKET}",
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
        "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:aud-trsn-*",
        "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:transcription-*"
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
      "Resource": "*"
    }
  ]
}
EOF

    # Create new policy version
    NEW_VERSION=$(aws iam create-policy-version \
        --policy-arn "$POLICY_ARN" \
        --policy-document file:///tmp/updated-worker-policy.json \
        --set-as-default \
        --query 'PolicyVersion.VersionId' \
        --output text)
    
    echo -e "${GREEN}[OK]${NC} Policy updated to version: $NEW_VERSION"
    
    # Clean up temp file
    rm -f /tmp/updated-worker-policy.json
else
    echo -e "${YELLOW}[WARNING]${NC} Worker policy not found, skipping update"
fi

# Fix 2: Update launch script user data to use proper .env variables
echo -e "${GREEN}[STEP 2]${NC} Fixing launch script user data..."

# Check if launch script exists
if [ -f "scripts/launch-spot-worker.sh" ]; then
    # Create backup
    cp scripts/launch-spot-worker.sh scripts/launch-spot-worker.sh.backup
    
    # Update the user data to use METRICS_BUCKET variable correctly
    sed -i 's/--s3-bucket "$S3_BUCKET"/--s3-bucket "$METRICS_BUCKET"/' scripts/launch-spot-worker.sh
    
    echo -e "${GREEN}[OK]${NC} Launch script updated to use METRICS_BUCKET"
else
    echo -e "${YELLOW}[WARNING]${NC} Launch script not found, skipping update"
fi

# Fix 3: Create a test script to validate the complete workflow
echo -e "${GREEN}[STEP 3]${NC} Creating comprehensive test script..."

cat > scripts/step-041-test-complete-workflow.sh << 'EOF'
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
EOF

chmod +x scripts/step-041-test-complete-workflow.sh
echo -e "${GREEN}[OK]${NC} Test script created: scripts/step-041-test-complete-workflow.sh"

# Fix 4: Ensure ffmpeg is installed on worker instances
echo -e "${GREEN}[STEP 4]${NC} Adding ffmpeg installation to worker setup..."

# Update the launch script to include ffmpeg installation
if [ -f "scripts/launch-spot-worker.sh" ]; then
    # Check if ffmpeg installation is already in the script
    if ! grep -q "apt-get install.*ffmpeg" scripts/launch-spot-worker.sh; then
        echo -e "${YELLOW}[INFO]${NC} Adding ffmpeg installation to worker launch script..."
        
        # Create a backup if not already exists
        if [ ! -f "scripts/launch-spot-worker.sh.backup" ]; then
            cp scripts/launch-spot-worker.sh scripts/launch-spot-worker.sh.backup
        fi
        
        # Insert ffmpeg installation after the apt-get update line
        sed -i '/apt-get update/a\\n# Install ffmpeg for webm audio support\necho "Installing ffmpeg for audio format support..."\napt-get install -y ffmpeg\necho "FFmpeg installation completed"' scripts/launch-spot-worker.sh
        
        echo -e "${GREEN}[OK]${NC} Added ffmpeg installation to worker launch script"
    else
        echo -e "${YELLOW}[INFO]${NC} FFmpeg installation already present in launch script"
    fi
else
    echo -e "${YELLOW}[WARNING]${NC} Launch script not found, creating ffmpeg verification script..."
    
    # Create a standalone script to install ffmpeg on existing workers
    cat > scripts/install-ffmpeg-on-workers.sh << 'EOF'
#!/bin/bash

# Install ffmpeg on existing worker instances

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Installing ffmpeg on all running worker instances..."

# Get running worker instances
WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,PublicIpAddress]" \
    --output text)

if [ -z "$WORKERS" ]; then
    echo -e "${YELLOW}[WARNING]${NC} No running worker instances found"
    exit 0
fi

# Install ffmpeg on each worker
echo "$WORKERS" | while IFS=$'\t' read -r instance_id public_ip; do
    if [ -n "$public_ip" ] && [ "$public_ip" != "None" ]; then
        echo -e "${GREEN}[INFO]${NC} Installing ffmpeg on instance $instance_id ($public_ip)..."
        
        ssh -i transcription-worker-key-dev.pem -o StrictHostKeyChecking=no ubuntu@"$public_ip" \
            "sudo apt-get update && sudo apt-get install -y ffmpeg && ffmpeg -version | head -1" \
            || echo -e "${RED}[ERROR]${NC} Failed to install ffmpeg on $instance_id"
    else
        echo -e "${YELLOW}[WARNING]${NC} No public IP for instance $instance_id"
    fi
done

echo -e "${GREEN}[OK]${NC} FFmpeg installation completed on all workers"
EOF
    
    chmod +x scripts/install-ffmpeg-on-workers.sh
    echo -e "${GREEN}[OK]${NC} Created ffmpeg installation script: scripts/install-ffmpeg-on-workers.sh"
fi

# Fix 5: Update setup status
echo -e "${GREEN}[STEP 5]${NC} Updating setup status..."
echo "STEP_040_COMPLETE=$(date)" >> .setup-status

echo
echo -e "${GREEN}[INFO]${NC} === System Fixes Applied Successfully ==="
echo
echo "Applied fixes:"
echo "1. Updated IAM worker policy for metrics bucket access"
echo "2. Fixed launch script to use correct environment variables"
echo "3. Created comprehensive integration test script"
echo "4. Added ffmpeg installation for webm audio support"
echo
echo "To test the complete workflow:"
echo "  ./scripts/step-041-test-complete-workflow.sh"
echo
echo "To re-run IAM permissions with fixes:"
echo "  ./scripts/step-010-setup-iam-permissions.sh"
echo