#!/bin/bash

# step-120-launch-dlami-ondemand-worker.sh - Launch DLAMI On-Demand Instance (PATH 100: TURNKEY)

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Please run setup scripts first."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Launching DLAMI On-Demand Instance (PATH 100: TURNKEY APPROACH)..."

# Check for CPU-only flag
CPU_FLAG=""
if [ "$1" = "--cpu-only" ]; then
    CPU_FLAG="--cpu-only"
    echo -e "${YELLOW}[INFO]${NC} CPU-only mode requested"
fi

# Check prerequisites
echo -e "${GREEN}[INFO]${NC} Checking prerequisites..."

# Check if all required config values exist
MISSING_CONFIG=0
if [ -z "$QUEUE_URL" ]; then
    echo -e "${RED}[ERROR]${NC} QUEUE_URL not found. Run step-020-create-sqs-resources.sh first."
    MISSING_CONFIG=1
fi

if [ -z "$SECURITY_GROUP_ID" ] || [ -z "$KEY_NAME" ] || [ -z "$SUBNET_ID" ]; then
    echo -e "${RED}[ERROR]${NC} EC2 configuration missing. Run step-025-setup-ec2-configuration.sh first."
    MISSING_CONFIG=1
fi

if [ $MISSING_CONFIG -eq 1 ]; then
    exit 1
fi

# Check if there are already running instances
echo -e "${GREEN}[INFO]${NC} Checking for existing transcription workers..."
EXISTING_INSTANCES=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

if [ -n "$EXISTING_INSTANCES" ]; then
    echo -e "${YELLOW}[WARNING]${NC} Found existing transcription worker instances:"
    echo "$EXISTING_INSTANCES"
    read -p "Do you want to launch another instance? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}[INFO]${NC} Cancelled. Existing instances are still running."
        exit 0
    fi
fi

# Launch the spot instance
echo -e "${GREEN}[INFO]${NC} Launching spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID"
echo "  Max Spot Price: \$$SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  Metrics Bucket: $METRICS_BUCKET"
echo "  Audio Bucket: $AUDIO_BUCKET"
echo "  Region: $AWS_REGION"

# Run the DLAMI launch script with optional CPU flag
./scripts/launch-dlami-ondemand-worker.sh $CPU_FLAG

# Check if launch was successful
if [ $? -eq 0 ]; then
    echo
    echo -e "${GREEN}[INFO]${NC} === DLAMI On-Demand Worker Launch Complete ==="
    echo
    echo "The DLAMI on-demand instance has been launched successfully."
    echo "ADVANTAGES of DLAMI approach:"
    echo "1. ✅ NVIDIA drivers pre-installed (no manual setup)"
    echo "2. ✅ Docker + nvidia-container-toolkit ready"
    echo "3. ✅ No reboot required (immediate startup)"
    echo "4. ✅ AWS-validated GPU environment"
    echo "5. ✅ Ubuntu 22.04 LTS with long-term support"
    echo
    echo "Next steps:"
    echo "1. Monitor setup: Commands shown above (should complete in 2-3 minutes)"
    echo "2. Check queue status: ./scripts/monitor-queue.sh"
    echo "3. Run health check: ./scripts/step-125-check-worker-health.sh"
    echo
    echo "Note: DLAMI workers start faster and more reliably than manual setups."
    echo "To submit jobs: python3 scripts/send_to_queue.py --s3_input_path s3://${AUDIO_BUCKET}/path/to/audio.mp3 --s3_output_path s3://${METRICS_BUCKET}/test-outputs/transcript.json"
    
    # Auto-detect and show next step
    if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
        source "$(dirname "$0")/next-step-helper.sh"
        show_next_step "$0" "$(dirname "$0")"
    fi
else
    echo -e "${RED}[ERROR]${NC} Failed to launch DLAMI on-demand instance. Check the error messages above."
    exit 1
fi