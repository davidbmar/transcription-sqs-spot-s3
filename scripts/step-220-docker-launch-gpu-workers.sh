#!/bin/bash

# step-220-docker-launch-gpu-workers.sh - Launch on-demand GPU instance with Docker worker (PATH 200)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Launch Docker GPU Worker (PATH 200)${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ -z "$ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} ECR configuration missing. Run step-200-docker-setup-ecr-repository.sh first."
    exit 1
fi

# Verify EC2 configuration
if [ -z "$SECURITY_GROUP_ID" ] || [ -z "$KEY_NAME" ] || [ -z "$SUBNET_ID" ]; then
    echo -e "${RED}[ERROR]${NC} EC2 configuration missing. Run step-202-docker-setup-ec2-network-and-security.sh first."
    exit 1
fi

# Verify image exists in ECR
echo -e "${GREEN}[STEP 1]${NC} Verifying Docker image in ECR..."
if ! aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$ECR_REPO_NAME" \
    --image-ids imageTag="$DOCKER_IMAGE_TAG" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker image not found in ECR. Run step-210 and step-211 first."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Docker image verified in ECR"
echo "Image: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"

# Get latest GPU-optimized Ubuntu AMI (use DLAMI for Docker compatibility)
echo -e "${GREEN}[STEP 2]${NC} Getting latest GPU-optimized Ubuntu AMI..."
GPU_AMI_ID=$(aws ssm get-parameter \
    --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text)

if [ -z "$GPU_AMI_ID" ]; then
    echo -e "${RED}[ERROR]${NC} GPU DLAMI not found"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Using AMI: $GPU_AMI_ID"

echo -e "${GREEN}[STEP 3]${NC} Creating user data script..."

# Create user data for Docker GPU worker
cat > /tmp/docker-gpu-worker-userdata.sh << EOF
#!/bin/bash
set -e

# Enhanced logging
log_step() {
    local timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
    echo "[\$timestamp] \$1" | tee -a /var/log/docker-worker-setup.log
}

log_step "===========================================" 
log_step "🐳 STARTING DOCKER GPU WORKER SETUP"
log_step "==========================================="
log_step "Instance ID: \$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
log_step "Instance Type: \$(curl -s http://169.254.169.254/latest/meta-data/instance-type)"
log_step "Public IP: \$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"

# PHASE 1: Install Docker and NVIDIA Container Toolkit
log_step "🔧 PHASE 1: Installing Docker and NVIDIA Container Toolkit"

# Update package index
apt-get update

# Install Docker
if ! command -v docker &> /dev/null; then
    log_step "📦 Installing Docker..."
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    log_step "✅ Docker installed and started"
else
    log_step "✅ Docker already installed"
fi

# Install NVIDIA Container Toolkit
log_step "📦 Installing NVIDIA Container Toolkit..."
distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/\$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
apt-get update

# Install with automatic yes and force configuration file replacement
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confnew" nvidia-docker2
systemctl restart docker
log_step "✅ NVIDIA Container Toolkit installed"

# Test Docker with GPU
log_step "🧪 Testing Docker GPU access..."
if docker run --rm --gpus all nvidia/cuda:11.8.0-runtime-ubuntu20.04 nvidia-smi >/dev/null 2>&1; then
    log_step "✅ Docker GPU access confirmed"
else
    log_step "⚠️ Docker GPU test failed, but continuing..."
fi

# PHASE 2: AWS CLI and ECR Authentication  
log_step "🔧 PHASE 2: Setting up AWS CLI and ECR authentication"

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    log_step "📦 Installing AWS CLI..."
    apt-get install -y awscli
fi

# Configure AWS region
export AWS_DEFAULT_REGION="$AWS_REGION"

# ECR Login
log_step "🔐 Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI"
log_step "✅ ECR authentication successful"

# PHASE 3: Pull and Start Container
log_step "🚀 PHASE 3: Starting GPU transcription worker container"

# Pull the latest image
log_step "📥 Pulling Docker image: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"
docker pull "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"
log_step "✅ Docker image pulled successfully"

# Start the container with GPU support
log_step "🚀 Starting transcription worker container..."
docker run -d \
    --name whisper-gpu-worker \
    --gpus all \
    --restart unless-stopped \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    -v /var/log:/var/log \
    "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG" \
    --queue-url "$QUEUE_URL" \
    --s3-bucket "$AUDIO_BUCKET" \
    --region "$AWS_REGION" \
    --model large-v3 \
    --idle-timeout 60

# Wait for container to start
sleep 10

# Check container status
if docker ps | grep -q whisper-gpu-worker; then
    log_step "✅ Container started successfully"
    docker logs whisper-gpu-worker --tail 10
else
    log_step "❌ Container failed to start"
    docker logs whisper-gpu-worker --tail 20
    exit 1
fi

log_step "🎉 Docker GPU worker setup complete!"
log_step "==========================================="
log_step "✅ DOCKER GPU WORKER READY"
log_step "==========================================="
EOF

# Replace configuration placeholders
sed -i "s|\$AWS_REGION|$AWS_REGION|g" /tmp/docker-gpu-worker-userdata.sh
sed -i "s|\$ECR_REPOSITORY_URI|$ECR_REPOSITORY_URI|g" /tmp/docker-gpu-worker-userdata.sh
sed -i "s|\$DOCKER_IMAGE_TAG|$DOCKER_IMAGE_TAG|g" /tmp/docker-gpu-worker-userdata.sh
sed -i "s|\$QUEUE_URL|$QUEUE_URL|g" /tmp/docker-gpu-worker-userdata.sh
sed -i "s|\$AUDIO_BUCKET|$AUDIO_BUCKET|g" /tmp/docker-gpu-worker-userdata.sh
sed -i "s|\$METRICS_BUCKET|$METRICS_BUCKET|g" /tmp/docker-gpu-worker-userdata.sh

echo -e "${GREEN}[OK]${NC} User data script created"

echo -e "${GREEN}[STEP 4]${NC} Launching GPU instance with Docker worker..."

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/docker-gpu-worker-userdata.sh)

# Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$GPU_AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$USER_DATA" \
    --iam-instance-profile Name=transcription-worker-profile \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Type,Value=whisper-worker},{Key=Environment,Value=production},{Key=Mode,Value=docker-gpu},{Key=Path,Value=200}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo -e "${GREEN}[OK]${NC} Instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo -e "${GREEN}[STEP 5]${NC} Waiting for instance to be running..."
aws ec2 wait instance-running \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID"

# Generate unique worker name
WORKER_NAME="docker-gpu-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"

# Tag the instance
aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value="$WORKER_NAME"

# Get instance IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

# Cleanup
rm -f /tmp/docker-gpu-worker-userdata.sh

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Docker GPU Worker Launched${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[INSTANCE DETAILS]${NC}"
echo "Instance ID: $INSTANCE_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Public IP: $INSTANCE_IP"
echo "Worker Name: $WORKER_NAME"
echo "AMI: $GPU_AMI_ID"
echo
echo -e "${GREEN}[MONITORING]${NC}"
echo "Setup logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'sudo tail -f /var/log/docker-worker-setup.log'"
echo
echo "Container logs:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'docker logs -f whisper-gpu-worker'"
echo
echo "Container status:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'docker ps'"
echo
echo "GPU status:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@${INSTANCE_IP} 'docker exec whisper-gpu-worker nvidia-smi'"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Monitor container startup (wait ~5 minutes for model loading)"
echo "2. Test the deployment: ./scripts/step-235-docker-test-transcription-workflow.sh"
echo "3. Health check: ./scripts/step-225-docker-monitor-worker-health.sh"

# Update status tracking
echo "step-220-completed=$(date)" >> .setup-status