#!/bin/bash

# launch-on-demand-worker.sh - Launch EC2 On-Demand Instance for GPU Transcription Worker
# RELIABLE ON-DEMAND SOLUTION - No interruption risk

set -e

# Parse command line arguments
CPU_ONLY_FLAG=""
if [ "$1" = "--cpu-only" ]; then
    CPU_ONLY_FLAG="--cpu-only"
    echo "🖥️ CPU-only mode requested"
fi

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
# Use CPU instance for CPU-only mode, GPU instance otherwise
if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    INSTANCE_TYPE="c5.xlarge"  # 4 vCPU, 8GB RAM, optimized for compute
    SPOT_PRICE="0.20"  # Much cheaper than GPU
else
    INSTANCE_TYPE=${INSTANCE_TYPE}
    SPOT_PRICE=${SPOT_PRICE}
fi
AMI_ID="ami-0efd9a34b86a437e7"  # PROVEN: Standard Ubuntu 22.04 LTS
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}
METRICS_BUCKET=${METRICS_BUCKET}

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    exit 1
fi

if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    echo "🚀 LAUNCHING CPU-ONLY WORKER (OPTIMIZED CONFIGURATION)"
    echo "Instance Type: $INSTANCE_TYPE (CPU optimized)"
else
    echo "🚀 LAUNCHING GPU WORKER (PROVEN WORKING CONFIGURATION)"
    echo "Instance Type: $INSTANCE_TYPE (GPU enabled)"
fi
echo "Using Standard Ubuntu AMI: $AMI_ID"

# Create user data script with PROVEN WORKING GPU SETUP
cat > /tmp/user-data-gpu-proven.sh << EOF
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 PROVEN GPU WORKER SETUP"
echo "=========================================="
echo "Timestamp: \$(date)"

# Update system (Ubuntu 22.04 proven working)
echo "📦 Installing system packages..."
apt-get update
apt-get install -y wget curl git ffmpeg python3-pip awscli

# Check if CPU-only mode was requested
CPU_ONLY_FLAG="$CPU_ONLY_FLAG"  # Pass from outer script
if [ "\$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    echo "🖥️ CPU-only mode requested - skipping NVIDIA driver installation"
    GPU_MODE="--cpu-only"
else
    # NVIDIA drivers auto-install with Ubuntu drivers (PROVEN WORKING)
    echo "🎮 Installing NVIDIA drivers (Ubuntu repo - proven stable)..."
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
    
    echo "⏳ Waiting for NVIDIA drivers to initialize..."
    sleep 30
fi

# Install PyTorch based on mode
echo "🔥 Installing PyTorch..."
pip3 install --upgrade pip
if [ "$GPU_MODE" = "--cpu-only" ]; then
    echo "📦 Installing CPU-only PyTorch (smaller and faster)"
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
else
    echo "🎮 Installing PyTorch with CUDA 12.1 support"
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
fi

# Install transcription dependencies (PROVEN WORKING)
echo "📚 Installing transcription dependencies..."
pip3 install boto3 openai-whisper
pip3 install git+https://github.com/m-bain/whisperx.git

# Test setup based on mode
echo "🧪 Testing setup..."
if [ "$GPU_MODE" = "--cpu-only" ]; then
    echo "🖥️ CPU-only mode - skipping GPU tests" | tee -a /var/log/gpu-test.log
    python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CPU threads: {torch.get_num_threads()}')
print('✅ CPU mode ready!')
" >> /var/log/gpu-test.log 2>&1
else
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
fi

# Check if CPU-only mode was requested from command line
if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    echo "🖥️ CPU-only mode forced by command line flag" | tee -a /var/log/gpu-test.log
    GPU_MODE="--cpu-only"
    echo "🚀 SELECTED MODE: CPU-only (forced)" | tee -a /var/log/gpu-test.log
else
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
fi

# Create working directory (PROVEN WORKING SETUP)
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download transcription worker code from S3
echo "📥 Downloading transcription worker code from S3..." | tee -a /var/log/gpu-test.log
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcription_worker.py . --region $REGION || echo "Failed to download from S3"
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/queue_metrics.py . --region $REGION || echo "Failed to download from S3"
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcriber.py . --region $REGION || echo "Failed to download from S3"
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcriber_gpu_optimized.py . --region $REGION || echo "Failed to download from S3"
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/progress_logger.py . --region $REGION || echo "Failed to download from S3"

# Start the worker (PROVEN WORKING COMMAND)
echo "=========================================="  | tee -a /var/log/gpu-test.log
echo "🚀 STARTING GPU TRANSCRIPTION WORKER" | tee -a /var/log/gpu-test.log
echo "==========================================" | tee -a /var/log/gpu-test.log
echo "Configuration:" | tee -a /var/log/gpu-test.log
echo "  - Queue URL: $QUEUE_URL" | tee -a /var/log/gpu-test.log
echo "  - Metrics Bucket: $METRICS_BUCKET" | tee -a /var/log/gpu-test.log
echo "  - Region: $REGION" | tee -a /var/log/gpu-test.log
echo "  - Model: large-v3" | tee -a /var/log/gpu-test.log
echo "  - Batch Size: 64 (GPU optimized)" | tee -a /var/log/gpu-test.log
echo "  - GPU Mode: \$GPU_MODE" | tee -a /var/log/gpu-test.log
echo "  - Working Directory: \$(pwd)" | tee -a /var/log/gpu-test.log
echo "  - Timestamp: \$(date)" | tee -a /var/log/gpu-test.log
echo "==========================================" | tee -a /var/log/gpu-test.log

# Start enhanced worker with progress logging
# AUTO-SHUTDOWN: Worker will shutdown after 60 minutes of no queue activity
nohup python3 transcription_worker.py \
    --queue-url "$QUEUE_URL" \
    --s3-bucket "$METRICS_BUCKET" \
    --region "$REGION" \
    --model large-v3 \
    --idle-timeout 60 \
    \$GPU_MODE > /var/log/transcription-worker.log 2>&1 &

echo "🎉 Enhanced GPU Transcription Worker with S3 progress logging started!" | tee -a /var/log/gpu-test.log
echo "📊 Real-time progress will be available in S3: s3://$METRICS_BUCKET/progress/" | tee -a /var/log/gpu-test.log
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

# Launch on-demand instance
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$USER_DATA" \
    --iam-instance-profile Name=transcription-worker-profile \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Type,Value=whisper-worker},{Key=Environment,Value=production},{Key=Mode,Value=on-demand}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "On-demand instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for on-demand instance to be running..."
aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

echo "On-demand instance ready: $INSTANCE_ID"

# Generate unique worker name with timestamp
WORKER_NAME="tr-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"
if [ "$GPU_MODE" = "--cpu-only" ]; then
    WORKER_NAME="tr-cpu-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"
else
    WORKER_NAME="tr-gpu-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"
fi

# Tag the instance with unique name
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=$WORKER_NAME \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=gpu-proven

echo "🎉 Instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"

# Get the instance IP
echo ""
echo "Getting instance IP..."
INSTANCE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance IP: $INSTANCE_IP"
echo ""
echo "==================== READY-TO-USE COMMANDS ===================="
echo ""
echo "📋 Monitor setup progress:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'sudo tail -f /var/log/cloud-init-output.log'"
echo ""
echo "📋 Check worker logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'tail -f /var/log/transcription-worker.log'"
echo ""
echo "📋 SSH into instance:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP}"
echo ""
echo "📋 Check queue status:"
echo "  ./scripts/monitor-queue.sh"
echo ""
echo "=============================================================="

# Cleanup
rm -f /tmp/user-data-gpu-proven.sh