#!/bin/bash

# launch-dlami-ondemand-worker.sh - Launch DLAMI On-Demand Instance (PATH 100: TURNKEY)
# Based on deep_research_nvidia.txt recommendations for maximum reliability

set -e

# Parse command line arguments
CPU_ONLY_FLAG=""
if [ "$1" = "--cpu-only" ]; then
    CPU_ONLY_FLAG="--cpu-only"
    echo "🖥️ CPU-only mode requested (DLAMI still has NVIDIA drivers available)"
fi

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# DLAMI Configuration
REGION=${AWS_REGION}
INSTANCE_TYPE=${INSTANCE_TYPE}
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}
METRICS_BUCKET=${METRICS_BUCKET}

# Get latest DLAMI AMI ID programmatically (as per research recommendations)
echo "🔍 Getting latest DLAMI AMI ID for Ubuntu 22.04..."
DLAMI_AMI_ID=$(aws ssm get-parameter \
    --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
    --region "$REGION" \
    --query "Parameter.Value" \
    --output text)

if [ -z "$DLAMI_AMI_ID" ]; then
    echo "❌ Failed to get DLAMI AMI ID. Check AWS permissions and region."
    exit 1
fi

echo "✅ Using DLAMI AMI: $DLAMI_AMI_ID"

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    exit 1
fi

echo "🚀 LAUNCHING DLAMI ON-DEMAND WORKER (TURNKEY CONFIGURATION)"
echo "Instance Type: $INSTANCE_TYPE"
echo "DLAMI AMI: $DLAMI_AMI_ID (Ubuntu 22.04 with pre-installed NVIDIA drivers)"

# Create simplified user data script for DLAMI (no driver installation needed!)
cat > /tmp/user-data-dlami-turnkey.sh << EOF
#!/bin/bash
set -e

# Enhanced logging function
log_step() {
    local timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
    echo "[\$timestamp] \$1" | tee -a /var/log/dlami-worker-setup.log
}

# Create comprehensive log file
touch /var/log/dlami-worker-setup.log
chmod 644 /var/log/dlami-worker-setup.log

log_step "=========================================="
log_step "🚀 STARTING DLAMI TURNKEY WORKER SETUP"
log_step "=========================================="
log_step "Instance ID: \$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
log_step "Instance Type: \$(curl -s http://169.254.169.254/latest/meta-data/instance-type)"
log_step "Public IP: \$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
log_step "DLAMI Version: \$(cat /opt/dlami/info/dlami-release-notes.txt | head -1 2>/dev/null || echo 'Version info not found')"
log_step "Timestamp: \$(date)"

# PHASE 1: Verify DLAMI environment (should already be ready!)
log_step "🔍 PHASE 1: Verifying DLAMI pre-installed environment"

# Check NVIDIA drivers (should already be installed)
if nvidia-smi > /var/log/nvidia-smi-dlami.log 2>&1; then
    log_step "✅ NVIDIA drivers working perfectly (pre-installed in DLAMI)"
    GPU_MODE=""
else
    log_step "⚠️ GPU not accessible, falling back to CPU mode"
    GPU_MODE="--cpu-only"
fi

# Check Docker and nvidia-container-toolkit (should already be installed)
if command -v docker &> /dev/null && command -v nvidia-ctk &> /dev/null; then
    log_step "✅ Docker and NVIDIA Container Toolkit ready (pre-installed in DLAMI)"
else
    log_step "⚠️ Installing missing container components..."
    apt-get update
    if ! command -v docker &> /dev/null; then
        apt-get install -y docker.io
    fi
    systemctl start docker
    systemctl enable docker
fi

# Check if CPU-only mode was requested from command line
if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    log_step "🖥️ CPU-only mode forced by command line flag"
    GPU_MODE="--cpu-only"
    log_step "🚀 SELECTED MODE: CPU-only (forced)"
else
    log_step "🚀 SELECTED MODE: GPU acceleration enabled (DLAMI)"
fi

# PHASE 2: Python Dependencies (minimal since DLAMI has most packages)
log_step "🐍 PHASE 2: Installing transcription-specific dependencies"

# Install ffmpeg for audio format support (WebM, etc.)
log_step "📦 Installing ffmpeg for audio format support..."
apt-get update && apt-get install -y ffmpeg
log_step "✅ FFmpeg installed"

# Fix cuDNN library paths for PyTorch/WhisperX compatibility
log_step "🔧 Creating cuDNN library symlinks for GPU acceleration..."

# Find where cuDNN actually exists (could be in any CUDA version)
CUDNN_SOURCE=""
for cuda_dir in /usr/local/cuda-*/lib; do
    if [ -f "\$cuda_dir/libcudnn_ops_infer.so.8" ]; then
        CUDNN_SOURCE="\$cuda_dir"
        break
    fi
done

# Get the active CUDA version
ACTIVE_CUDA=\$(readlink -f /usr/local/cuda)
ACTIVE_CUDA_LIB="\$ACTIVE_CUDA/lib"

if [ -n "\$CUDNN_SOURCE" ]; then
    log_step "Found cuDNN in: \$CUDNN_SOURCE"
    log_step "Active CUDA lib: \$ACTIVE_CUDA_LIB"
    
    # Create symlinks in both the active CUDA lib and /usr/local/lib
    ln -sf \$CUDNN_SOURCE/libcudnn_ops_infer.so.8 \$ACTIVE_CUDA_LIB/libcudnn_ops_infer.so.8
    ln -sf \$CUDNN_SOURCE/libcudnn_ops_train.so.8 \$ACTIVE_CUDA_LIB/libcudnn_ops_train.so.8
    ln -sf \$CUDNN_SOURCE/libcudnn_ops_infer.so.8 /usr/local/lib/libcudnn_ops_infer.so.8
    ln -sf \$CUDNN_SOURCE/libcudnn_ops_train.so.8 /usr/local/lib/libcudnn_ops_train.so.8
    
    log_step "✅ cuDNN symlinks created for active CUDA version"
else
    log_step "⚠️ cuDNN libraries not found in any CUDA version"
fi

pip3 install --upgrade pip boto3 openai-whisper
pip3 install git+https://github.com/m-bain/whisperx.git
log_step "✅ Dependencies installed"

# PHASE 3: Worker Code Download
log_step "📥 PHASE 3: Downloading worker code"
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcription_worker.py . --region $REGION
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/queue_metrics.py . --region $REGION
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcriber.py . --region $REGION
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/transcriber_gpu_optimized.py . --region $REGION
aws s3 cp s3://$METRICS_BUCKET/worker-code/latest/progress_logger.py . --region $REGION

log_step "✅ Worker code downloaded"

# PHASE 4: Worker Startup (immediate - no reboot needed!)
log_step "🚀 PHASE 4: Starting worker (immediate startup - DLAMI advantage!)"
nohup python3 transcription_worker.py \
    --queue-url "$QUEUE_URL" \
    --s3-bucket "$AUDIO_BUCKET" \
    --region "$REGION" \
    --model large-v3 \
    --idle-timeout 60 \
    \$GPU_MODE > /var/log/transcription-worker.log 2>&1 &

log_step "🎉 DLAMI worker started - setup complete!"
log_step "=========================================="
log_step "✅ DLAMI TURNKEY SETUP SUCCESSFUL"
log_step "=========================================="
EOF

# Replace configuration placeholders
sed -i "s|\$QUEUE_URL|$QUEUE_URL|g" /tmp/user-data-dlami-turnkey.sh
sed -i "s|\$METRICS_BUCKET|$METRICS_BUCKET|g" /tmp/user-data-dlami-turnkey.sh
sed -i "s|\$AUDIO_BUCKET|$AUDIO_BUCKET|g" /tmp/user-data-dlami-turnkey.sh
sed -i "s|\$REGION|$REGION|g" /tmp/user-data-dlami-turnkey.sh
sed -i "s|\$CPU_ONLY_FLAG|$CPU_ONLY_FLAG|g" /tmp/user-data-dlami-turnkey.sh

echo "📄 DLAMI user data script created and configured"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-dlami-turnkey.sh)

# Launch on-demand instance with DLAMI
echo "🚀 Launching on-demand instance with DLAMI..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  DLAMI AMI: $DLAMI_AMI_ID"
echo "  Region: $REGION"
echo "  Queue URL: $QUEUE_URL"
echo "  Metrics Bucket: $METRICS_BUCKET"

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$DLAMI_AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$USER_DATA" \
    --iam-instance-profile Name=transcription-worker-profile \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Type,Value=whisper-worker},{Key=Environment,Value=production},{Key=Mode,Value=dlami-ondemand},{Key=Path,Value=100-turnkey}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "✅ DLAMI on-demand instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo "⏳ Waiting for instance to be running..."
aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

echo "✅ DLAMI instance ready: $INSTANCE_ID"

# Generate unique worker name with timestamp
WORKER_NAME="dlami-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"

# Tag the instance with unique name
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value="$WORKER_NAME" \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production \
           Key=Mode,Value=dlami-ondemand

echo "🏷️ Instance tagged as: $WORKER_NAME"

# Get the instance IP
echo "🔍 Getting instance IP..."
INSTANCE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "🌐 Instance IP: $INSTANCE_IP"

echo ""
echo "==================== DLAMI WORKER READY ===================="
echo ""
echo "📋 Monitor setup progress (should be very fast with DLAMI):"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'sudo tail -f /var/log/cloud-init-output.log'"
echo ""
echo "📋 Check DLAMI-specific setup logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'sudo tail -f /var/log/dlami-worker-setup.log'"
echo ""
echo "📋 Check worker logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'tail -f /var/log/transcription-worker.log'"
echo ""
echo "📋 Verify DLAMI GPU environment:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'nvidia-smi'"
echo ""
echo "📋 SSH into instance:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP}"
echo ""
echo "=============================================================="

# Cleanup
rm -f /tmp/user-data-dlami-turnkey.sh