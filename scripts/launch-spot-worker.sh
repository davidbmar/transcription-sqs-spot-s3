#!/bin/bash

# launch-spot-worker.sh - Launch EC2 Spot Instance for Transcription Worker

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
INSTANCE_TYPE=${INSTANCE_TYPE}
AMI_ID=${AMI_ID}
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}  # Use AUDIO_BUCKET from .env
METRICS_BUCKET=${METRICS_BUCKET}  # Use METRICS_BUCKET from .env
SPOT_PRICE=${SPOT_PRICE}

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    echo "Usage: QUEUE_URL=<queue-url> S3_BUCKET=<bucket> ./launch-spot-worker.sh"
    exit 1
fi

# Create user data script
cat > /tmp/user-data.sh << EOF
#!/bin/bash
set -e

# Update system
apt-get update

# Fix Docker containerd conflict
apt-get remove -y containerd.io || true
apt-get install -y docker.io python3-pip awscli git ffmpeg

# Try to install NVIDIA drivers (fallback to CPU-only if it fails)
echo "Attempting to install NVIDIA drivers..."
if apt-get install -y nvidia-driver-525 nvidia-docker2; then
    echo "NVIDIA drivers installed successfully"
    systemctl restart docker
    GPU_MODE="--use-gpu"
else
    echo "NVIDIA driver installation failed, continuing with CPU-only mode"
    # Clean up any partial installations
    apt-get remove -y nvidia-driver-525 nvidia-docker2 nvidia-dkms-525 || true
    apt-get autoremove -y || true
    dpkg --configure -a || true
    GPU_MODE="--cpu-only"
fi

# Install Python packages
pip3 install boto3 torch torchaudio transformers openai-whisper whisperx

# Create working directory
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download the actual transcription worker code from GitHub
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py

# Start the worker with the downloaded code
python3 transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$METRICS_BUCKET" --region "$REGION" --model base \$GPU_MODE
EOF

# Create the spot instance request
echo "Launching spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data.sh)

# Create launch template
LAUNCH_TEMPLATE_NAME="transcription-worker-$(date +%s)"

aws ec2 create-launch-template \
    --region "$REGION" \
    --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
    --launch-template-data "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"KeyName\": \"$KEY_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$USER_DATA\",
        \"IamInstanceProfile\": {
            \"Name\": \"transcription-worker-profile\"
        },
        \"TagSpecifications\": [{
            \"ResourceType\": \"instance\",
            \"Tags\": [
                {\"Key\": \"Name\", \"Value\": \"transcription-worker\"},
                {\"Key\": \"Type\", \"Value\": \"whisper-worker\"},
                {\"Key\": \"Environment\", \"Value\": \"production\"}
            ]
        }]
    }"

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

echo "Spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production

echo "Instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo "You can check the instance status with:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID"

# Cleanup
rm -f /tmp/user-data.sh