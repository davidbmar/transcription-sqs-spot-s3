#!/bin/bash

# step-320-fast-api-launch-gpu-instances.sh - Launch GPU instance with Fast API container

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
echo -e "${BLUE}🎤 Launch Fast API GPU Instance${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ -z "$FAST_API_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} Fast API ECR configuration missing. Run step-301-fast-api-setup-ecr-repository.sh first."
    exit 1
fi

# Verify EC2 configuration
if [ -z "$SECURITY_GROUP_ID" ] || [ -z "$KEY_NAME" ] || [ -z "$SUBNET_ID" ]; then
    echo -e "${RED}[ERROR]${NC} EC2 configuration missing. Run step-202-docker-setup-ec2-network-and-security.sh first."
    exit 1
fi

# Verify image exists in ECR
echo -e "${GREEN}[STEP 1]${NC} Verifying Fast API image in ECR..."
if ! aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$FAST_API_ECR_REPO_NAME" \
    --image-ids imageTag="$FAST_API_DOCKER_IMAGE_TAG" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Fast API image not found in ECR. Run step-310 and step-311 first."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Fast API image verified in ECR"
echo "Image: $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG"

# Get latest GPU-optimized Ubuntu AMI
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

# Add security group rule for Fast API API (port 8000)
echo -e "${GREEN}[STEP 3]${NC} Checking security group rules..."
if ! aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`8000\`]" \
    --output text | grep -q "8000"; then
    
    echo -e "${YELLOW}[INFO]${NC} Adding port 8000 to security group for Fast API API..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 8000 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" || true
fi

echo -e "${GREEN}[STEP 4]${NC} Creating user data script..."

# Create user data for Fast API GPU worker
cat > /tmp/fast-api-gpu-userdata.sh << EOF
#!/bin/bash
set -e

# Enhanced logging
log_step() {
    local timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
    echo "[\$timestamp] \$1" | tee -a /var/log/fast-api-setup.log
}

log_step "===========================================" 
log_step "🎤 STARTING FAST_API GPU SETUP"
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
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu
    log_step "✅ Docker installed successfully"
fi

# Install NVIDIA Container Toolkit
log_step "📦 Installing NVIDIA Container Toolkit..."
distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/\$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
apt-get update
apt-get install -y nvidia-container-toolkit
systemctl restart docker
log_step "✅ NVIDIA Container Toolkit installed"

# Test GPU access
log_step "🔍 Testing GPU access..."
docker run --rm --gpus all nvidia/cuda:11.8.0-base nvidia-smi | tee -a /var/log/fast-api-setup.log || log_step "⚠️ GPU test failed, continuing..."

# PHASE 2: Login to ECR and pull Fast API image
log_step "🔧 PHASE 2: Pulling Fast API Docker image"

# Configure AWS CLI
log_step "🔐 Configuring AWS CLI..."
aws configure set region $AWS_REGION

# Login to ECR
log_step "🔐 Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $FAST_API_ECR_REPOSITORY_URI

# Pull the Fast API image
log_step "📥 Pulling Fast API image..."
docker pull $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG

# PHASE 3: Run Fast API container
log_step "🔧 PHASE 3: Starting Fast API container"

# Stop any existing container
docker stop fast-api-gpu 2>/dev/null || true
docker rm fast-api-gpu 2>/dev/null || true

# Run Fast API container with GPU support
log_step "🚀 Starting Fast API container..."
docker run -d \\
    --name fast-api-gpu \\
    --gpus all \\
    --restart unless-stopped \\
    -p 8000:8000 \\
    -e AWS_REGION=$AWS_REGION \\
    -e DEVICE=cuda \\
    -v /var/log/fast-api:/app/logs \\
    $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG

# Wait for container to start
sleep 10

# Check container status
if docker ps | grep -q fast-api-gpu; then
    log_step "✅ Fast API container running successfully"
    log_step "📋 Container logs:"
    docker logs fast-api-gpu | tail -20 | tee -a /var/log/fast-api-setup.log
else
    log_step "❌ Fast API container failed to start"
    docker logs fast-api-gpu 2>&1 | tee -a /var/log/fast-api-setup.log
fi

# Test API endpoint
log_step "🔍 Testing Fast API API endpoint..."
sleep 5
curl -f http://localhost:8000/health || log_step "⚠️ API health check failed"

log_step "===========================================" 
log_step "✅ FAST_API SETUP COMPLETE"
log_step "API available at http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8000"
log_step "==========================================="
EOF

# Base64 encode the user data
USER_DATA=$(base64 -w 0 /tmp/fast-api-gpu-userdata.sh)

echo -e "${GREEN}[STEP 5]${NC} Launching GPU instance..."

# Launch instance with IAM instance profile
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$GPU_AMI_ID" \
    --instance-type "${INSTANCE_TYPE:-g4dn.xlarge}" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile Name="$INSTANCE_PROFILE" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=fast-api-gpu-worker},{Key=Type,Value=fast-api-worker},{Key=Project,Value=$QUEUE_PREFIX}]" \
    --metadata-options "HttpTokens=optional,HttpPutResponseHopLimit=2" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo -e "${GREEN}[OK]${NC} Instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo -e "${YELLOW}[INFO]${NC} Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get instance details
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' \
    --output text)

PUBLIC_IP=$(echo "$INSTANCE_INFO" | awk '{print $1}')
PRIVATE_IP=$(echo "$INSTANCE_INFO" | awk '{print $2}')

# Update status tracking
echo "step-320-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API GPU Instance Launched${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[INSTANCE DETAILS]${NC}"
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Private IP: $PRIVATE_IP"
echo "Instance Type: ${INSTANCE_TYPE:-g4dn.xlarge}"
echo
echo -e "${GREEN}[ACCESS]${NC}"
echo "SSH: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP"
echo "API: http://$PUBLIC_IP:8000"
echo "Health: http://$PUBLIC_IP:8000/health (shows s3_enabled status)"
echo "S3 API: http://$PUBLIC_IP:8000/transcribe-s3"
echo "URL API: http://$PUBLIC_IP:8000/transcribe-url"  
echo "Docs: http://$PUBLIC_IP:8000/docs"
echo
echo -e "${GREEN}[MONITORING]${NC}"
echo "View setup logs:"
echo "  ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'sudo tail -f /var/log/fast-api-setup.log'"
echo
echo "View container logs:"
echo "  ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'docker logs -f fast-api-gpu'"
echo
echo -e "${YELLOW}[NOTE]${NC} Wait 3-5 minutes for setup to complete"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Check instance health:"
echo "   ./scripts/step-326-fast-api-check-gpu-health.sh"
echo
echo "2. Test voice transcription:"
echo "   ./scripts/step-330-fast-api-test-transcription.sh"
echo
echo -e "${GREEN}[QUICK USAGE EXAMPLES]${NC}"
echo "S3 to S3 transcription:"
echo "  curl -X POST http://$PUBLIC_IP:8000/transcribe-s3 \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"s3_input_path\": \"s3://bucket/audio.mp3\", \"s3_output_path\": \"s3://bucket/transcript.json\"}'"
echo
echo "File upload:"
echo "  curl -X POST -F 'file=@audio.mp3' http://$PUBLIC_IP:8000/transcribe"