#!/bin/bash
# launch-docker-worker.sh - Launch transcription worker using Docker

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

# Configuration
REGION=${AWS_REGION}
# Use CPU instance for CPU-only mode, GPU instance otherwise
if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    INSTANCE_TYPE="c5.xlarge"  # 4 vCPU, 8GB RAM, optimized for compute
    SPOT_PRICE="0.20"  # Much cheaper than GPU
else
    INSTANCE_TYPE=${INSTANCE_TYPE}
    SPOT_PRICE=${SPOT_PRICE}
fi
AMI_ID="ami-0efd9a34b86a437e7"  # Standard Ubuntu 22.04 LTS
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
METRICS_BUCKET=${METRICS_BUCKET}

# Docker image configuration
DOCKER_IMAGE="transcription-worker:latest"
DOCKER_REGISTRY="your-account.dkr.ecr.${REGION}.amazonaws.com"

if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    echo "🚀 LAUNCHING CPU-ONLY DOCKER WORKER"
    echo "Instance Type: $INSTANCE_TYPE (CPU optimized)"
else
    echo "🚀 LAUNCHING GPU DOCKER WORKER"
    echo "Instance Type: $INSTANCE_TYPE (GPU enabled)"
fi
echo "Using Docker Image: $DOCKER_IMAGE"

# Create user data script for Docker worker
cat > /tmp/user-data-docker.sh << EOF
#!/bin/bash
set -e

echo "🐳 DOCKER TRANSCRIPTION WORKER SETUP"
echo "======================================"

# Install Docker
echo "📦 Installing Docker..."
apt-get update
apt-get install -y docker.io awscli

# Install NVIDIA Docker runtime for GPU instances
if [ "$CPU_ONLY_FLAG" != "--cpu-only" ]; then
    echo "🎮 Installing NVIDIA Docker runtime..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu22.04/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-docker2
    systemctl restart docker
fi

# Login to ECR (if using ECR)
echo "🔐 Logging into Docker registry..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $DOCKER_REGISTRY || echo "ECR login failed, using public image"

# Pull the transcription worker image
echo "📥 Pulling Docker image..."
docker pull $DOCKER_REGISTRY/$DOCKER_IMAGE || docker pull $DOCKER_IMAGE || {
    echo "❌ Failed to pull Docker image. Building locally..."
    # Fallback: build image locally (would need source code)
    exit 1
}

# Start the transcription worker container
echo "🚀 Starting transcription worker container..."
DEVICE_MODE="auto"
if [ "$CPU_ONLY_FLAG" = "--cpu-only" ]; then
    DEVICE_MODE="cpu"
    DOCKER_RUN_ARGS=""
else
    DEVICE_MODE="auto"
    DOCKER_RUN_ARGS="--gpus all"
fi

docker run -d \
    --name transcription-worker \
    --restart unless-stopped \
    \$DOCKER_RUN_ARGS \
    -e AWS_DEFAULT_REGION=$REGION \
    -v /tmp:/app/temp \
    $DOCKER_REGISTRY/$DOCKER_IMAGE \
    worker "$QUEUE_URL" "$METRICS_BUCKET" "$REGION" "large-v3" "\$DEVICE_MODE" "60"

echo "✅ Docker transcription worker started successfully!"
echo "📊 Container status:"
docker ps | grep transcription-worker

echo "📋 Container logs:"
docker logs transcription-worker | tail -10

# Create health check script
cat > /usr/local/bin/worker-health.sh << 'HEALTH_EOF'
#!/bin/bash
echo "🏥 Docker Worker Health Check"
echo "Container Status: \$(docker ps --filter name=transcription-worker --format 'table {{.Status}}')"
echo "Container Logs (last 5 lines):"
docker logs transcription-worker | tail -5
HEALTH_EOF
chmod +x /usr/local/bin/worker-health.sh

echo "🎉 Docker worker setup complete!"
echo "Run '/usr/local/bin/worker-health.sh' to check worker status"
EOF

# Launch the spot instance
USER_DATA=$(base64 -w 0 < /tmp/user-data-docker.sh)

echo "Launching Docker-based worker..."
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

echo "Docker worker spot request: $SPOT_REQUEST"

# Wait for spot request fulfillment
aws ec2 wait spot-instance-request-fulfilled --region "$REGION" --spot-instance-request-ids "$SPOT_REQUEST"
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests --region "$REGION" --spot-instance-request-ids "$SPOT_REQUEST" --query 'SpotInstanceRequests[0].InstanceId' --output text)

# Tag the instance
aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags Key=Name,Value=docker-transcription-worker Key=Type,Value=docker-worker

echo "🐳 Docker worker launched: $INSTANCE_ID"

# Get the instance IP
echo ""
echo "Getting instance IP..."
INSTANCE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance IP: $INSTANCE_IP"

echo ""
echo "==================== READY-TO-USE COMMANDS ===================="
echo ""
echo "📋 Check Docker setup:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'docker ps'"
echo ""
echo "📋 Check worker logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'docker logs transcription-worker'"
echo ""
echo "📋 Worker health check:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} '/usr/local/bin/worker-health.sh'"
echo ""
echo "📋 SSH into instance:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP}"
echo ""
echo "📋 Check queue status:"
echo "  ./scripts/monitor-queue.sh"
echo ""
echo "=============================================================="

# Cleanup
rm -f /tmp/user-data-docker.sh