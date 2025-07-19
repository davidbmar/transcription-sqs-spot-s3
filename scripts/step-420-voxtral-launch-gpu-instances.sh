#!/bin/bash

# step-420-voxtral-launch-gpu-instances.sh - Launch GPU instances for Real Voxtral

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🚀 Launch Real Voxtral GPU Instances${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Default values
INSTANCE_COUNT=${1:-1}
INSTANCE_TYPE=${INSTANCE_TYPE:-"g4dn.xlarge"}

# Validate prerequisites
echo -e "${GREEN}[STEP 1]${NC} Validating prerequisites..."

if [ -z "$REAL_VOXTRAL_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} REAL_VOXTRAL_ECR_REPOSITORY_URI not set. Run step-401 first."
    exit 1
fi

# Check if ECR image exists
if ! aws ecr describe-images --region "$AWS_REGION" --repository-name "$REAL_VOXTRAL_ECR_REPO_NAME" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Real Voxtral image not found in ECR. Run step-410 and step-411 first."
    exit 1
fi

# Check instance profile exists
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Instance profile not found: $INSTANCE_PROFILE"
    echo "Run IAM setup scripts first."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Prerequisites validated"

# Show launch configuration
echo -e "${GREEN}[STEP 2]${NC} Launch configuration..."
echo "Instance type: $INSTANCE_TYPE"
echo "Instance count: $INSTANCE_COUNT"
echo "ECR image: $REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "Security group: $SECURITY_GROUP_ID"
echo "Subnet: $SUBNET_ID"
echo "Key pair: $KEY_NAME"
echo "Instance profile: $INSTANCE_PROFILE"

# Check current instances
echo -e "${GREEN}[STEP 3]${NC} Checking existing Real Voxtral instances..."
EXISTING_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running,pending" \
    --region "$AWS_REGION" \
    --query 'length(Reservations[*].Instances[*])')

echo "Current Real Voxtral instances: $EXISTING_INSTANCES"

if [ "$EXISTING_INSTANCES" -gt 0 ]; then
    echo -e "${YELLOW}[WARNING]${NC} Real Voxtral instances already running."
    aws ec2 describe-instances \
        --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running,pending" \
        --region "$AWS_REGION" \
        --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,InstanceType]' \
        --output table
    
    read -p "Continue with launch? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create user data script for Real Voxtral
echo -e "${GREEN}[STEP 4]${NC} Creating user data script..."

cat > /tmp/voxtral-user-data.sh << EOF
#!/bin/bash

# Real Voxtral GPU Worker Startup Script
set -e

exec > >(tee /var/log/voxtral-startup.log) 2>&1
echo "🚀 Starting Real Voxtral GPU worker setup at \$(date)"

# Update system
echo "📦 Updating system packages..."
apt-get update -y

# Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker ubuntu
    systemctl enable docker
    systemctl start docker
fi

# Install NVIDIA Container Toolkit for GPU support
echo "🔧 Installing NVIDIA Container Toolkit..."
distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID) \\
    && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \\
    && curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | \\
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -y
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Install AWS CLI
echo "☁️ Installing AWS CLI..."
apt-get install -y awscli

# Configure AWS credentials from instance profile
echo "🔐 Configuring AWS credentials..."
export AWS_DEFAULT_REGION="${AWS_REGION}"

# ECR login
echo "🔐 Logging into ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${REAL_VOXTRAL_ECR_REPOSITORY_URI}

# Pull Real Voxtral image
echo "📥 Pulling Real Voxtral Docker image..."
docker pull ${REAL_VOXTRAL_ECR_REPOSITORY_URI}:${REAL_VOXTRAL_DOCKER_IMAGE_TAG}

# Run Real Voxtral container
echo "🚀 Starting Real Voxtral container..."
docker run -d \\
    --name real-voxtral-worker \\
    --restart unless-stopped \\
    --gpus all \\
    -p 8000:8000 \\
    -p 8080:8080 \\
    -e AWS_REGION="${AWS_REGION}" \\
    -e AWS_DEFAULT_REGION="${AWS_REGION}" \\
    ${REAL_VOXTRAL_ECR_REPOSITORY_URI}:${REAL_VOXTRAL_DOCKER_IMAGE_TAG}

# Wait for container to be healthy
echo "🏥 Waiting for container health check..."
for i in {1..60}; do
    if curl -f http://localhost:8080/health >/dev/null 2>&1; then
        echo "✅ Real Voxtral container is healthy!"
        break
    fi
    echo "Waiting for health check... (\$i/60)"
    sleep 10
done

# Show container status
echo "📊 Container status:"
docker ps
docker logs real-voxtral-worker | tail -20

echo "🎉 Real Voxtral GPU worker setup complete at \$(date)"
echo "🔗 API available at: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8000"
echo "🏥 Health check: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080/health"
EOF

echo -e "${GREEN}[OK]${NC} User data script created"

# Launch instances
echo -e "${GREEN}[STEP 5]${NC} Launching Real Voxtral GPU instances..."

LAUNCH_RESPONSE=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count "$INSTANCE_COUNT" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile Name="$INSTANCE_PROFILE" \
    --user-data file:///tmp/voxtral-user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${QUEUE_PREFIX}-real-voxtral-worker},{Key=Type,Value=real-voxtral-worker},{Key=Environment,Value=${ENVIRONMENT}},{Key=Model,Value=voxtral}]" \
    --region "$AWS_REGION" \
    --output json)

# Extract instance IDs
INSTANCE_IDS=$(echo "$LAUNCH_RESPONSE" | jq -r '.Instances[].InstanceId' | tr '\n' ' ')
echo -e "${GREEN}[OK]${NC} Launched instances: $INSTANCE_IDS"

# Wait for instances to be running
echo -e "${GREEN}[STEP 6]${NC} Waiting for instances to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_IDS --region "$AWS_REGION"
echo -e "${GREEN}[OK]${NC} Instances are running"

# Get instance details
echo -e "${GREEN}[STEP 7]${NC} Instance details..."
aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,PrivateIpAddress,InstanceType]' \
    --output table

# Get public IPs for easy access
PUBLIC_IPS=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].PublicIpAddress' \
    --output text | tr '\t' ' ')

# Clean up temp file
rm -f /tmp/voxtral-user-data.sh

# Update status tracking
echo "step-420-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral GPU Launch Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[INSTANCE SUMMARY]${NC}"
echo "Instance IDs: $INSTANCE_IDS"
echo "Public IPs: $PUBLIC_IPS"
echo "Instance type: $INSTANCE_TYPE"
echo "Model: $VOXTRAL_MODEL_ID"
echo
echo -e "${GREEN}[API ENDPOINTS]${NC}"
for ip in $PUBLIC_IPS; do
    echo "API: http://$ip:8000"
    echo "Health: http://$ip:8080/health"
    echo "SSH: ssh -i $KEY_NAME.pem ubuntu@$ip"
    echo
done
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Wait 5-10 minutes for containers to fully start"
echo "2. Check worker health:"
echo "   ./scripts/step-426-voxtral-check-gpu-health.sh"
echo
echo "3. Test Real Voxtral transcription:"
echo "   ./scripts/step-430-voxtral-test-transcription.sh"
echo
echo -e "${YELLOW}[MONITORING]${NC}"
echo "Monitor startup logs:"
for ip in $PUBLIC_IPS; do
    echo "  ssh -i $KEY_NAME.pem ubuntu@$ip 'sudo tail -f /var/log/voxtral-startup.log'"
done