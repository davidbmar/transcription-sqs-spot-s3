#!/bin/bash

# step-401-voxtral-setup-ecr-repository.sh - Setup ECR repository for Real Voxtral GPU containers

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
echo -e "${BLUE}🎯 Real Voxtral ECR Repository Setup${NC}"
echo -e "${BLUE}======================================${NC}"
echo

echo -e "${GREEN}[STEP 1]${NC} Creating ECR repository for Real Voxtral GPU images..."

# Create ECR repository name for Real Voxtral
REAL_VOXTRAL_ECR_REPO_NAME="${QUEUE_PREFIX}-real-voxtral-gpu"
echo "Repository name: $REAL_VOXTRAL_ECR_REPO_NAME"

# Check if repository exists
if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REAL_VOXTRAL_ECR_REPO_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} ECR repository already exists: $REAL_VOXTRAL_ECR_REPO_NAME"
else
    echo -e "${GREEN}[INFO]${NC} Creating ECR repository: $REAL_VOXTRAL_ECR_REPO_NAME"
    aws ecr create-repository \
        --region "$AWS_REGION" \
        --repository-name "$REAL_VOXTRAL_ECR_REPO_NAME" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256
    
    echo -e "${GREEN}[OK]${NC} ECR repository created successfully"
fi

# Get repository URI
REAL_VOXTRAL_ECR_REPOSITORY_URI=$(aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$REAL_VOXTRAL_ECR_REPO_NAME" \
    --query 'repositories[0].repositoryUri' \
    --output text)

echo -e "${GREEN}[OK]${NC} Real Voxtral ECR Repository URI: $REAL_VOXTRAL_ECR_REPOSITORY_URI"

echo -e "${GREEN}[STEP 2]${NC} Updating configuration with Real Voxtral Docker settings..."

# Add Real Voxtral-specific configuration to .env
if ! grep -q "REAL_VOXTRAL_ECR_REPOSITORY_URI" "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "# Real Voxtral Docker configuration (400 series)" >> "$CONFIG_FILE"
    echo "REAL_VOXTRAL_ECR_REPOSITORY_URI=$REAL_VOXTRAL_ECR_REPOSITORY_URI" >> "$CONFIG_FILE"
    echo "REAL_VOXTRAL_ECR_REPO_NAME=$REAL_VOXTRAL_ECR_REPO_NAME" >> "$CONFIG_FILE"
    echo "REAL_VOXTRAL_DOCKER_IMAGE_TAG=latest" >> "$CONFIG_FILE"
    echo "VOXTRAL_MODEL_ID=mistralai/Voxtral-Mini-3B-2507" >> "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Real Voxtral configuration added to .env"
else
    # Update existing values
    sed -i "s|REAL_VOXTRAL_ECR_REPOSITORY_URI=.*|REAL_VOXTRAL_ECR_REPOSITORY_URI=$REAL_VOXTRAL_ECR_REPOSITORY_URI|" "$CONFIG_FILE"
    sed -i "s|REAL_VOXTRAL_ECR_REPO_NAME=.*|REAL_VOXTRAL_ECR_REPO_NAME=$REAL_VOXTRAL_ECR_REPO_NAME|" "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Real Voxtral configuration updated in .env"
fi

echo -e "${GREEN}[STEP 3]${NC} Creating Real Voxtral directory structure..."

# Create Real Voxtral Docker directory
mkdir -p docker/real-voxtral/{scripts,models}
echo -e "${GREEN}[OK]${NC} Created docker/real-voxtral directory structure"

echo -e "${GREEN}[STEP 4]${NC} Creating Real Voxtral helper scripts..."

# Create Real Voxtral ECR login helper
cat > scripts/real-voxtral-ecr-login.sh << 'EOF'
#!/bin/bash
# Real Voxtral ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR for Real Voxtral..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "✅ Real Voxtral ECR login successful"
EOF

chmod +x scripts/real-voxtral-ecr-login.sh

# Create Real Voxtral image build helper
cat > scripts/build-real-voxtral-gpu.sh << 'EOF'
#!/bin/bash
# Real Voxtral GPU Image Build Script
set -e

source .env
echo "🚀 Building Real Voxtral GPU Docker image..."
echo "Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"

cd "$(dirname "$0")/.."

# Build image with Real Voxtral GPU tag
docker build \
    -f docker/real-voxtral/Dockerfile \
    -t "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" \
    -t "$REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" \
    docker/real-voxtral/

echo "✅ Real Voxtral Docker image built successfully"
echo "Local tag: $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "ECR tag: $REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
EOF

chmod +x scripts/build-real-voxtral-gpu.sh

echo -e "${GREEN}[OK]${NC} Helper scripts created:"
echo "  - scripts/real-voxtral-ecr-login.sh (ECR authentication)"
echo "  - scripts/build-real-voxtral-gpu.sh (Build Real Voxtral image)"

# Update status tracking
echo "step-401-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral ECR Repository Setup Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Validate ECR configuration:"
echo "   ./scripts/step-402-voxtral-validate-ecr-configuration.sh"
echo
echo "2. Build the Real Voxtral GPU image:"
echo "   ./scripts/step-410-voxtral-build-gpu-docker-image.sh"
echo
echo -e "${YELLOW}[CONFIGURATION]${NC}"
echo "ECR Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "Model: mistralai/Voxtral-Mini-3B-2507"
echo "Image Tag: latest"
echo "Directory: docker/real-voxtral/"