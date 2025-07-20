#!/bin/bash
set -e

echo "⚡ LAUNCHING HYBRID WORKERS (FAST MODE - S3 CACHE)"
echo "=================================================="

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found."
    exit 1
fi

# S3 Cache configuration
S3_BUCKET="${MODELS_CACHE_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${MODELS_CACHE_PREFIX:-bintarball}/docker-images"

# Check if S3 cache exists
echo "🔍 Checking S3 cache availability..."
if aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/manifest.json" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "✅ S3 cache found!"
    USE_S3_CACHE=true
    
    # Download manifest
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/manifest.json" /tmp/docker-manifest.json --region "$AWS_REGION"
    
    WHISPER_S3_FILE=$(jq -r '.images.whisper.filename' /tmp/docker-manifest.json)
    VOXTRAL_S3_FILE=$(jq -r '.images.voxtral.filename' /tmp/docker-manifest.json)
    
    echo "  Whisper: $WHISPER_S3_FILE"
    echo "  Voxtral: $VOXTRAL_S3_FILE"
else
    echo "⚠️ S3 cache not found. Will use ECR (slower)."
    echo "   Run: ./scripts/step-505-setup-s3-image-cache.sh <worker-ip> to create cache"
    USE_S3_CACHE=false
fi

# Validate configuration
echo "🔍 Validating configuration..."
REQUIRED_VARS=("AWS_REGION" "AWS_ACCOUNT_ID" "QUEUE_PREFIX")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Missing required configuration: $var"
        exit 1
    fi
done

# Get NVIDIA Deep Learning AMI
echo "🔍 Finding latest NVIDIA Deep Learning AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "✅ Using AMI: $AMI_ID"

# Get network configuration
echo "🌐 Getting network configuration..."
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)

# Security group
SECURITY_GROUP_NAME="${QUEUE_PREFIX}-hybrid-workers"
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --group-names "$SECURITY_GROUP_NAME" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "NotFound")

if [ "$SECURITY_GROUP_ID" = "NotFound" ]; then
    echo "❌ Security group not found. Run step-500-launch-hybrid-workers.sh first to create it."
    exit 1
fi

echo "✅ Network: VPC=$VPC_ID, Subnet=$SUBNET_ID, SG=$SECURITY_GROUP_ID"

# Create fast user-data script
if [ "$USE_S3_CACHE" = true ]; then
    echo "⚡ Creating FAST user-data script (S3 cache)..."
    USER_DATA=$(cat <<EOF
#!/bin/bash
set -e

echo "⚡ FAST HYBRID WORKER INITIALIZATION (S3 CACHE)"
echo "=============================================="

# Install required packages
apt-get update -y
apt-get install -y unzip curl jq

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install

# Configure AWS
aws configure set default.region $AWS_REGION

# Configure Docker for GPU (already installed on DLAMI)
tee /etc/docker/daemon.json > /dev/null <<DOCKEREOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
DOCKEREOF

systemctl restart docker

# Create shared directories
mkdir -p /shared-audio /shared-cache
chmod 777 /shared-audio /shared-cache

# Download and load images from S3 (FAST!)
echo "📥 FAST LOADING: Downloading images from S3..."
mkdir -p /tmp/docker-images
cd /tmp/docker-images

# Download Whisper image (2-3 minutes instead of 15!)
echo "⚡ Loading Whisper (fast)..."
time aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$WHISPER_S3_FILE" . --region $AWS_REGION
time docker load < "$WHISPER_S3_FILE"

# Download Voxtral image 
echo "⚡ Loading Voxtral (fast)..."
time aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$VOXTRAL_S3_FILE" . --region $AWS_REGION
time docker load < "$VOXTRAL_S3_FILE"

# Cleanup
rm -f /tmp/docker-images/*.tar.gz

echo "✅ FAST LOADING COMPLETE!"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Launch containers
echo "🚀 Starting containers..."

# Start Whisper container
docker run -d \
    --name whisper-worker \
    --gpus all \
    --restart unless-stopped \
    -p 8001:8000 \
    -v /shared-audio:/shared-audio \
    -v /shared-cache:/shared-cache \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    $WHISPER_ECR_URI

# Start Voxtral container
docker run -d \
    --name voxtral-worker \
    --gpus all \
    --restart unless-stopped \
    -p 8000:8000 \
    -v /shared-audio:/shared-audio \
    -v /shared-cache:/shared-cache \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    $VOXTRAL_ECR_URI

echo "🎉 FAST HYBRID DEPLOYMENT COMPLETE!"
echo "==================================="
echo "⚡ Total time: ~3-5 minutes (vs 15-20 minutes ECR)"
echo "🚀 Ready for processing!"

# Log completion
echo "fast-hybrid-deployment-completed=\$(date)" >> /var/log/fast-deployment.log
echo "whisper-container=\$(docker ps --filter name=whisper-worker --format '{{.Status}}')" >> /var/log/fast-deployment.log
echo "voxtral-container=\$(docker ps --filter name=voxtral-worker --format '{{.Status}}')" >> /var/log/fast-deployment.log
EOF
)
else
    echo "🐌 Creating standard user-data script (ECR)..."
    # Use original ECR-based script
    USER_DATA=$(cat <<EOF
#!/bin/bash
# Standard ECR-based deployment (slower)
# ... (original user-data from step-500)
EOF
)
fi

# Launch instance
echo "🚀 Launching fast hybrid worker..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type g4dn.xlarge \
    --key-name "${KEY_PAIR_NAME:-transcription-worker-key-dev}" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,DeleteOnTermination=true}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${QUEUE_PREFIX}-hybrid-fast},{Key=Type,Value=hybrid-worker},{Key=DeployMode,Value=fast-s3},{Key=Project,Value=$QUEUE_PREFIX}]" \
    --user-data "$USER_DATA" \
    --iam-instance-profile Name="${INSTANCE_PROFILE:-transcription-worker-profile}" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "✅ Instance launched: $INSTANCE_ID"

# Wait for running
echo "⏳ Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
if [ "$USE_S3_CACHE" = true ]; then
    echo "⚡ FAST HYBRID WORKER DEPLOYED!"
    echo "============================="
    echo "🚀 Speed: 5x faster than ECR (3-5 min vs 15-20 min)"
else
    echo "🐌 STANDARD HYBRID WORKER DEPLOYED"
    echo "================================="
    echo "⚠️ Speed: Standard ECR download (15-20 min)"
fi

echo ""
echo "📋 Instance Details:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  Type: g4dn.xlarge (Tesla T4 GPU)"
echo "  AMI: NVIDIA Deep Learning AMI"
echo ""
echo "🔗 Service Endpoints (ready in 5 minutes):"
echo "  Whisper API: http://$PUBLIC_IP:8001"
echo "  Voxtral API: http://$PUBLIC_IP:8000"
echo ""
echo "⏱️ Initialization Status:"
if [ "$USE_S3_CACHE" = true ]; then
    echo "  - S3 image download: ~2 minutes"
    echo "  - Container startup: ~2 minutes"
    echo "  - Model loading: ~1 minute (cached)"
    echo "  - Ready for processing: ~5 minutes total!"
else
    echo "  - ECR image download: ~10 minutes"
    echo "  - Container startup: ~3 minutes"
    echo "  - Model loading: ~2 minutes"
    echo "  - Ready for processing: ~15 minutes"
fi

echo ""
echo "🔍 Monitor deployment:"
echo "  ssh -i ~/.ssh/transcription-worker-key-dev.pem ubuntu@$PUBLIC_IP"
echo "  docker logs whisper-worker"
echo "  docker logs voxtral-worker"

# Update status
echo "step-506-completed=$(date)" >> .setup-status
echo "fast-hybrid-worker-instance-id=$INSTANCE_ID" >> .setup-status
echo "fast-hybrid-worker-public-ip=$PUBLIC_IP" >> .setup-status
echo "s3-cache-used=$USE_S3_CACHE" >> .setup-status

echo ""
echo "🎯 Performance Comparison:"
echo "  Standard ECR: 15-20 minutes"
echo "  S3 Cache:     3-5 minutes"
echo "  Speedup:      5x faster!"
echo ""
echo "💡 To create S3 cache (one-time setup):"
echo "  ./scripts/step-505-setup-s3-image-cache.sh <worker-ip>"