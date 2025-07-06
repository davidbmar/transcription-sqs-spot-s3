#!/bin/bash

# step-030-launch-spot-worker.sh - Launch EC2 Spot Instance with Transcription Worker

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

echo -e "${GREEN}[INFO]${NC} Launching Spot Instance for Transcription Worker..."

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

# Run the launch script
./scripts/launch-spot-worker.sh

# Check if launch was successful
if [ $? -eq 0 ]; then
    echo
    echo -e "${GREEN}[INFO]${NC} === Spot Worker Launch Initiated ==="
    echo
    echo "The spot instance request has been submitted."
    echo "The instance will:"
    echo "1. Install necessary dependencies (NVIDIA drivers, Docker, Python packages)"
    echo "2. Download and start the transcription worker"
    echo "3. Begin monitoring the SQS queue for jobs"
    echo
    echo "To check instance status:"
    echo "  aws ec2 describe-instances --region $AWS_REGION --filters \"Name=tag:Type,Values=whisper-worker\" \"Name=instance-state-name,Values=pending,running\""
    echo
    echo "To view worker logs (once instance is running):"
    echo "  ssh -i ${KEY_NAME}.pem ubuntu@<instance-ip> 'sudo journalctl -u cloud-final -f'"
    echo
    echo "Next step: Send audio files to the queue using:"
    echo "  python3 scripts/send_to_queue.py --s3_input_path s3://bucket/audio.mp3 --s3_output_path s3://bucket/transcript.json"
else
    echo -e "${RED}[ERROR]${NC} Failed to launch spot instance. Check the error messages above."
    exit 1
fi