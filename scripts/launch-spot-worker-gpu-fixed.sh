#!/bin/bash

# launch-spot-worker-gpu-fixed.sh - Launch EC2 Spot Instance for GPU Transcription Worker (Fixed Dependencies)

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

# Create user data script with fixed dependencies
cat > /tmp/user-data-gpu-fixed.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 FIXED GPU WORKER SETUP (Ubuntu 22.04)"
echo "=========================================="
echo "Timestamp: $(date)"

# Update system
echo "📦 Updating system packages..."
apt-get update
apt-get install -y wget curl git ffmpeg python3-pip software-properties-common

# Install NVIDIA drivers first
echo "🎮 Installing NVIDIA drivers..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

# Install CUDA toolkit 11.8 (more compatible)
echo "⚡ Installing CUDA toolkit 11.8..."
wget https://developer.download.nvidia.com/compute/cuda/11.8.0/local_installers/cuda_11.8.0_520.61.05_linux.run
sh cuda_11.8.0_520.61.05_linux.run --silent --toolkit

# Set up CUDA environment
echo 'export PATH=/usr/local/cuda-11.8/bin:$PATH' >> /etc/environment
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64:$LD_LIBRARY_PATH' >> /etc/environment
export PATH=/usr/local/cuda-11.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64:$LD_LIBRARY_PATH

# Install PyTorch with CUDA 11.8 support
echo "🔥 Installing PyTorch with CUDA 11.8..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

# Install other dependencies
echo "📚 Installing transcription dependencies..."
pip3 install boto3 whisperx openai-whisper

# Reboot to ensure drivers are loaded
echo "🔄 Rebooting to ensure NVIDIA drivers are properly loaded..."
cat > /etc/rc.local << 'RCEOF'
#!/bin/bash

# Wait for system to be ready
sleep 30

# Test GPU setup
echo "🧪 Testing GPU setup after reboot..."
export PATH=/usr/local/cuda-11.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64:$LD_LIBRARY_PATH

python3 -c "
import torch
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU count: {torch.cuda.device_count()}')
    print(f'GPU name: {torch.cuda.get_device_name(0)}')
    print('✅ GPU setup successful!')
    GPU_MODE='--use-gpu'
else:
    print('❌ GPU not available, using CPU')
    GPU_MODE='--cpu-only'
" > /var/log/gpu-test.log 2>&1

# Try nvidia-smi
if nvidia-smi > /var/log/nvidia-smi.log 2>&1; then
    echo "✅ NVIDIA GPU detected and working!" >> /var/log/gpu-test.log
    GPU_MODE="--use-gpu"
    echo "🚀 SELECTED MODE: GPU acceleration enabled" >> /var/log/gpu-test.log
else
    echo "❌ NVIDIA GPU not accessible, falling back to CPU" >> /var/log/gpu-test.log
    GPU_MODE="--cpu-only" 
    echo "🚀 SELECTED MODE: CPU-only fallback" >> /var/log/gpu-test.log
fi

# Create working directory
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download transcription worker code
echo "📥 Downloading transcription worker code..." >> /var/log/gpu-test.log
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py >> /var/log/gpu-test.log 2>&1
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py >> /var/log/gpu-test.log 2>&1
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py >> /var/log/gpu-test.log 2>&1

# Start the worker
echo "=========================================="  >> /var/log/gpu-test.log
echo "🚀 STARTING GPU TRANSCRIPTION WORKER" >> /var/log/gpu-test.log
echo "==========================================" >> /var/log/gpu-test.log
echo "Configuration:" >> /var/log/gpu-test.log
echo "  - Queue URL: $QUEUE_URL" >> /var/log/gpu-test.log
echo "  - Metrics Bucket: $METRICS_BUCKET" >> /var/log/gpu-test.log
echo "  - Region: $REGION" >> /var/log/gpu-test.log
echo "  - Model: base" >> /var/log/gpu-test.log
echo "  - GPU Mode: $GPU_MODE" >> /var/log/gpu-test.log
echo "  - Working Directory: $(pwd)" >> /var/log/gpu-test.log
echo "  - Timestamp: $(date)" >> /var/log/gpu-test.log
echo "==========================================" >> /var/log/gpu-test.log

# Start worker in background with logging
nohup python3 transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$METRICS_BUCKET" --region "$REGION" --model base $GPU_MODE > /var/log/transcription-worker.log 2>&1 &

exit 0
RCEOF

chmod +x /etc/rc.local
systemctl enable rc-local

echo "Setup complete. Rebooting now..."
reboot
EOF

# Create the spot instance request
echo "Launching fixed GPU spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID (Standard Ubuntu 22.04)"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-gpu-fixed.sh)

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

echo "Fixed GPU spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for fixed GPU spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Fixed GPU spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-gpu-fixed-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=gpu-fixed

echo "Fixed GPU instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo "You can check the instance status with:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID"

# Cleanup
rm -f /tmp/user-data-gpu-fixed.sh