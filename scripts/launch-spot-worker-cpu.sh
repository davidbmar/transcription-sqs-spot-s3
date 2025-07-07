#!/bin/bash

# launch-spot-worker-cpu.sh - Launch EC2 Spot Instance for CPU-Only Transcription Worker

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Configuration from .env file
REGION=${AWS_REGION}
# Use smaller instance type for CPU-only
INSTANCE_TYPE="c5.xlarge"  # CPU-optimized instance
AMI_ID="ami-0efd9a34b86a437e7"  # Standard Ubuntu 22.04 LTS (no GPU drivers)
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}  # Use AUDIO_BUCKET from .env
METRICS_BUCKET=${METRICS_BUCKET}  # Use METRICS_BUCKET from .env
SPOT_PRICE="0.20"  # Lower price for CPU instance

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    echo "Usage: QUEUE_URL=<queue-url> S3_BUCKET=<bucket> ./launch-spot-worker-cpu.sh"
    exit 1
fi

# Create user data script for CPU-only
cat > /tmp/user-data-cpu.sh << EOF
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 CPU WORKER SETUP (Ubuntu 22.04)"
echo "=========================================="
echo "Timestamp: \$(date)"

# Update system packages
echo "📦 Updating system packages..."
apt-get update
apt-get install -y git ffmpeg python3-pip awscli

echo "=========================================="
echo "🔧 CPU-ONLY MODE SELECTED"
echo "=========================================="
GPU_MODE="--cpu-only"
echo "🚀 SELECTED MODE: CPU-only"

# Install Python packages
echo "🐍 Installing Python packages..."
pip3 install boto3 torch torchaudio transformers openai-whisper whisperx

# Create working directory
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download the actual transcription worker code from GitHub
echo "📥 Downloading transcription worker code..."
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py

# Start the worker with the downloaded code
echo "=========================================="
echo "🚀 STARTING CPU TRANSCRIPTION WORKER"
echo "=========================================="
echo "Configuration:"
echo "  - Queue URL: $QUEUE_URL"
echo "  - Metrics Bucket: $METRICS_BUCKET"
echo "  - Region: $REGION"
echo "  - Model: base"
echo "  - GPU Mode: \$GPU_MODE"
echo "  - Working Directory: \$(pwd)"
echo "  - Timestamp: \$(date)"
echo "=========================================="

python3 transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$METRICS_BUCKET" --region "$REGION" --model base \$GPU_MODE
EOF

# Create the spot instance request
echo "Launching CPU-only spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID (Standard Ubuntu)"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-cpu.sh)

# Request spot instance
SPOT_REQUEST=$(aws ec2 request-spot-instances \
    --region "$REGION" \
    --spot-price "$SPOT_PRICE" \
    --instance-count 1 \
    --launch-specification "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"KeyName\": \"$KEY_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$USER_DATA\",
        \"IamInstanceProfile\": {
            \"Name\": \"transcription-worker-profile\"
        }
    }" \
    --query 'SpotInstanceRequests[0].SpotInstanceRequestId' \
    --output text)

echo "CPU spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for CPU spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "CPU spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-cpu-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=cpu-only

echo "CPU instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo "You can check the instance status with:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID"

# Cleanup
rm -f /tmp/user-data-cpu.sh