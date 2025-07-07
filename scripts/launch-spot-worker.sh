#!/bin/bash

# launch-spot-worker.sh - Launch EC2 Spot Instance for GPU Transcription Worker
# PROVEN WORKING GPU SOLUTION - Tested and Verified

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Configuration from .env file - FORCE STANDARD UBUNTU AMI (PROVEN WORKING)
REGION=${AWS_REGION}
INSTANCE_TYPE=${INSTANCE_TYPE}
AMI_ID="ami-0efd9a34b86a437e7"  # PROVEN: Standard Ubuntu 22.04 LTS
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

echo "🚀 LAUNCHING GPU WORKER (PROVEN WORKING CONFIGURATION)"
echo "Using Standard Ubuntu AMI: $AMI_ID"
echo "GPU Mode: Enabled (no --cpu-only flag)"

# Create user data script with PROVEN WORKING GPU SETUP
cat > /tmp/user-data-gpu-proven.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 PROVEN GPU WORKER SETUP"
echo "=========================================="
echo "Timestamp: $(date)"

# Update system (Ubuntu 22.04 proven working)
echo "📦 Installing system packages..."
apt-get update
apt-get install -y wget curl git ffmpeg python3-pip awscli

# NVIDIA drivers auto-install with Ubuntu drivers (PROVEN WORKING)
echo "🎮 Installing NVIDIA drivers (Ubuntu repo - proven stable)..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

echo "⏳ Waiting for NVIDIA drivers to initialize..."
sleep 30

# Install PyTorch with CUDA 12.1 (PROVEN WORKING VERSION)
echo "🔥 Installing PyTorch 2.5.1+cu121 (proven working)..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install transcription dependencies (PROVEN WORKING)
echo "📚 Installing transcription dependencies..."
pip3 install boto3 openai-whisper
pip3 install git+https://github.com/m-bain/whisperx.git

# Test GPU setup (PROVEN WORKING TEST)
echo "🧪 Testing GPU setup..."
python3 -c "
import torch
import whisperx
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA version: {torch.version.cuda}')
    print(f'GPU count: {torch.cuda.device_count()}')
    print(f'GPU name: {torch.cuda.get_device_name(0)}')
    print('✅ GPU test PASSED')
    # Test WhisperX GPU loading
    model = whisperx.load_model('base', 'cuda', compute_type='float16')
    print('✅ WhisperX GPU model loaded successfully')
    print('🚀 GPU transcription ready!')
else:
    print('❌ GPU test FAILED - falling back to CPU')
" > /var/log/gpu-test.log 2>&1

# Check nvidia-smi (PROVEN WORKING CHECK)
if nvidia-smi > /var/log/nvidia-smi.log 2>&1; then
    echo "✅ NVIDIA GPU detected and working!" | tee -a /var/log/gpu-test.log
    GPU_MODE=""  # NO --cpu-only flag = GPU mode
    echo "🚀 SELECTED MODE: GPU acceleration enabled" | tee -a /var/log/gpu-test.log
else
    echo "❌ NVIDIA GPU not accessible, falling back to CPU" | tee -a /var/log/gpu-test.log
    GPU_MODE="--cpu-only"
    echo "🚀 SELECTED MODE: CPU-only fallback" | tee -a /var/log/gpu-test.log
fi

# Create working directory (PROVEN WORKING SETUP)
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download transcription worker code (PROVEN WORKING)
echo "📥 Downloading transcription worker code..." | tee -a /var/log/gpu-test.log
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py

# Start the worker (PROVEN WORKING COMMAND)
echo "=========================================="  | tee -a /var/log/gpu-test.log
echo "🚀 STARTING GPU TRANSCRIPTION WORKER" | tee -a /var/log/gpu-test.log
echo "==========================================" | tee -a /var/log/gpu-test.log
echo "Configuration:" | tee -a /var/log/gpu-test.log
echo "  - Queue URL: $QUEUE_URL" | tee -a /var/log/gpu-test.log
echo "  - Metrics Bucket: $METRICS_BUCKET" | tee -a /var/log/gpu-test.log
echo "  - Region: $REGION" | tee -a /var/log/gpu-test.log
echo "  - Model: base" | tee -a /var/log/gpu-test.log
echo "  - GPU Mode: $GPU_MODE" | tee -a /var/log/gpu-test.log
echo "  - Working Directory: $(pwd)" | tee -a /var/log/gpu-test.log
echo "  - Timestamp: $(date)" | tee -a /var/log/gpu-test.log
echo "==========================================" | tee -a /var/log/gpu-test.log

# Start worker with proven working arguments
# AUTO-SHUTDOWN: Worker will shutdown after 60 minutes of no queue activity
nohup python3 transcription_worker.py \
    --queue-url "$QUEUE_URL" \
    --s3-bucket "$METRICS_BUCKET" \
    --region "$REGION" \
    --model base \
    --idle-timeout 60 \
    $GPU_MODE > /var/log/transcription-worker.log 2>&1 &

echo "🎉 GPU Transcription Worker started successfully!" | tee -a /var/log/gpu-test.log
EOF

# Create the spot instance request (PROVEN WORKING CONFIGURATION)
echo "Launching proven GPU spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID (Standard Ubuntu 22.04 - proven)"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-gpu-proven.sh)

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

echo "GPU spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for GPU spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "GPU spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-gpu-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=gpu-proven

echo "🎉 GPU instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo ""
echo "To check GPU setup logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@<instance-ip> 'cat /var/log/gpu-test.log'"
echo ""
echo "To check worker logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@<instance-ip> 'tail -f /var/log/transcription-worker.log'"
echo ""
echo "To check instance IP:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"

# Cleanup
rm -f /tmp/user-data-gpu-proven.sh