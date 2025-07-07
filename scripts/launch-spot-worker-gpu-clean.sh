#!/bin/bash

# launch-spot-worker-gpu-clean.sh - Launch EC2 Spot Instance for GPU Transcription Worker (Clean Dependencies)

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
# Use standard Ubuntu AMI instead of Deep Learning AMI
AMI_ID="ami-0efd9a34b86a437e7"  # Standard Ubuntu 22.04 LTS
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}
METRICS_BUCKET=${METRICS_BUCKET}
SPOT_PRICE=${SPOT_PRICE}

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    exit 1
fi

# Create user data script for clean GPU setup
cat > /tmp/user-data-gpu-clean.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 CLEAN GPU WORKER SETUP (Ubuntu 22.04)"
echo "=========================================="
echo "Timestamp: $(date)"

# Update system
echo "📦 Updating system packages..."
apt-get update
apt-get install -y wget curl git ffmpeg software-properties-common

# Install Python 3.10 and pip
echo "🐍 Installing Python 3.10..."
apt-get install -y python3.10 python3.10-pip python3.10-venv
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.10 1

# Install NVIDIA drivers
echo "🎮 Installing NVIDIA drivers..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

# Install CUDA toolkit
echo "⚡ Installing CUDA toolkit..."
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb
dpkg -i cuda-keyring_1.0-1_all.deb
apt-get update
apt-get -y install cuda-toolkit-12-2

# Set up CUDA environment
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /etc/environment
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/environment
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH

# Install PyTorch with CUDA support (latest stable)
echo "🔥 Installing PyTorch with CUDA..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install other dependencies
echo "📚 Installing additional dependencies..."
pip3 install boto3 whisperx openai-whisper

# Test GPU setup
echo "🧪 Testing GPU setup..."
python3 -c "
import torch
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU count: {torch.cuda.device_count()}')
    print(f'GPU name: {torch.cuda.get_device_name(0)}')
    print('✅ GPU setup successful!')
else:
    print('❌ GPU not available')
"

# Wait for drivers to fully load
echo "⏳ Waiting for NVIDIA drivers to stabilize..."
sleep 30

# Try nvidia-smi
if nvidia-smi; then
    echo "✅ NVIDIA GPU detected and working!"
    GPU_MODE="--use-gpu"
    echo "🚀 SELECTED MODE: GPU acceleration enabled"
else
    echo "❌ NVIDIA GPU not accessible, falling back to CPU"
    GPU_MODE="--cpu-only" 
    echo "🚀 SELECTED MODE: CPU-only fallback"
fi

# Create working directory
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download transcription worker code
echo "📥 Downloading transcription worker code..."
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py

# Start the worker
echo "=========================================="
echo "🚀 STARTING GPU TRANSCRIPTION WORKER"
echo "=========================================="
echo "Configuration:"
echo "  - Queue URL: $QUEUE_URL"
echo "  - Metrics Bucket: $METRICS_BUCKET"
echo "  - Region: $REGION"
echo "  - Model: base"
echo "  - GPU Mode: $GPU_MODE"
echo "  - Working Directory: $(pwd)"
echo "  - Timestamp: $(date)"
echo "=========================================="

python3 transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$METRICS_BUCKET" --region "$REGION" --model base $GPU_MODE
EOF

# Create the spot instance request
echo "Launching clean GPU spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID (Standard Ubuntu 22.04)"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-gpu-clean.sh)

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

echo "Clean GPU spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for clean GPU spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Clean GPU spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-gpu-clean-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=gpu-clean

echo "Clean GPU instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo "You can check the instance status with:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID"

# Cleanup
rm -f /tmp/user-data-gpu-clean.sh