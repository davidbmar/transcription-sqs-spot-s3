#!/bin/bash

# step-200-docker-setup-ecr-repository.sh - Setup Docker prerequisites for GPU workers (PATH 200)

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
echo -e "${BLUE}Docker Prerequisites Setup (PATH 200)${NC}"
echo -e "${BLUE}======================================${NC}"
echo

echo -e "${GREEN}[STEP 1]${NC} Creating ECR repository for GPU worker images..."

# Create ECR repository name based on queue prefix
ECR_REPO_NAME="${QUEUE_PREFIX}-gpu-whisper-worker"
echo "Repository name: $ECR_REPO_NAME"

# Check if repository exists
if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} ECR repository already exists: $ECR_REPO_NAME"
else
    echo -e "${GREEN}[INFO]${NC} Creating ECR repository: $ECR_REPO_NAME"
    aws ecr create-repository \
        --region "$AWS_REGION" \
        --repository-name "$ECR_REPO_NAME" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256
    
    echo -e "${GREEN}[OK]${NC} ECR repository created successfully"
fi

# Get repository URI
ECR_REPOSITORY_URI=$(aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$ECR_REPO_NAME" \
    --query 'repositories[0].repositoryUri' \
    --output text)

echo -e "${GREEN}[OK]${NC} ECR Repository URI: $ECR_REPOSITORY_URI"

echo -e "${GREEN}[STEP 2]${NC} Updating configuration with Docker settings..."

# Add Docker-specific configuration to .env
if ! grep -q "ECR_REPOSITORY_URI" "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "# Docker configuration (PATH 200)" >> "$CONFIG_FILE"
    echo "ECR_REPOSITORY_URI=$ECR_REPOSITORY_URI" >> "$CONFIG_FILE"
    echo "ECR_REPO_NAME=$ECR_REPO_NAME" >> "$CONFIG_FILE"
    echo "DOCKER_IMAGE_TAG=latest" >> "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Docker configuration added to .env"
else
    # Update existing values
    sed -i "s|ECR_REPOSITORY_URI=.*|ECR_REPOSITORY_URI=$ECR_REPOSITORY_URI|" "$CONFIG_FILE"
    sed -i "s|ECR_REPO_NAME=.*|ECR_REPO_NAME=$ECR_REPO_NAME|" "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Docker configuration updated in .env"
fi

echo -e "${GREEN}[STEP 3]${NC} Verifying Docker build environment..."

# Check if Docker is installed locally
if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Docker is installed locally"
    docker --version
else
    echo -e "${YELLOW}[WARNING]${NC} Docker not installed locally"
    echo "You can build images on an EC2 instance with Docker, or install Docker locally:"
    echo "  https://docs.docker.com/engine/install/"
fi

# Check AWS CLI configuration
echo -e "${GREEN}[INFO]${NC} Testing AWS CLI access..."
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null
echo -e "${GREEN}[OK]${NC} AWS CLI configured correctly"

echo -e "${GREEN}[STEP 4]${NC} Creating deployment path marker..."
echo "docker-gpu" > .deployment-path
echo -e "${GREEN}[OK]${NC} Deployment path set to: docker-gpu"

echo -e "${GREEN}[STEP 5]${NC} Creating build helper scripts..."

# Create ECR login helper
cat > scripts/ecr-login.sh << 'EOF'
#!/bin/bash
# ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI"
echo "✅ ECR login successful"
EOF

chmod +x scripts/ecr-login.sh

# Create image build helper
cat > scripts/build-gpu-worker.sh << 'EOF'
#!/bin/bash
# GPU Worker Image Build Script
set -e

source .env
echo "🚀 Building GPU worker Docker image..."
echo "Repository: $ECR_REPOSITORY_URI"

cd "$(dirname "$0")/.."

# Build image with GPU worker tag
docker build \
    -f docker/gpu-worker/Dockerfile \
    -t "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" \
    -t "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG" \
    .

echo "✅ Docker image built successfully"
echo "Local tag: $ECR_REPO_NAME:$DOCKER_IMAGE_TAG"
echo "ECR tag: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"
EOF

chmod +x scripts/build-gpu-worker.sh

echo -e "${GREEN}[OK]${NC} Helper scripts created:"
echo "  - scripts/ecr-login.sh (ECR authentication)"
echo "  - scripts/build-gpu-worker.sh (Build Docker image)"

# Update status tracking
echo "step-200-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Docker Prerequisites Setup Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Build the GPU worker image:"
echo "   ./scripts/step-210-docker-build-gpu-worker-image.sh"
echo
echo "2. Push image to ECR:"
echo "   ./scripts/step-211-docker-push-image-to-ecr.sh" 
echo
echo "3. Launch Docker GPU workers:"
echo "   ./scripts/step-220-docker-launch-gpu-workers.sh"
echo
echo -e "${YELLOW}[CONFIGURATION]${NC}"
echo "ECR Repository: $ECR_REPOSITORY_URI"
echo "Image Tag: latest"
echo "Deployment Path: docker-gpu"