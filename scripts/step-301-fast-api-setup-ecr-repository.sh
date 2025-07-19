#!/bin/bash

# step-301-fast-api-setup-ecr-repository.sh - Setup ECR repository for Fast API GPU containers

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
echo -e "${BLUE}🎤 Fast API ECR Repository Setup${NC}"
echo -e "${BLUE}======================================${NC}"
echo

echo -e "${GREEN}[STEP 1]${NC} Creating ECR repository for Fast API GPU images..."

# Create ECR repository name for Fast API
FAST_API_ECR_REPO_NAME="${QUEUE_PREFIX}-fast-api-gpu"
echo "Repository name: $FAST_API_ECR_REPO_NAME"

# Check if repository exists
if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$FAST_API_ECR_REPO_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} ECR repository already exists: $FAST_API_ECR_REPO_NAME"
else
    echo -e "${GREEN}[INFO]${NC} Creating ECR repository: $FAST_API_ECR_REPO_NAME"
    aws ecr create-repository \
        --region "$AWS_REGION" \
        --repository-name "$FAST_API_ECR_REPO_NAME" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256
    
    echo -e "${GREEN}[OK]${NC} ECR repository created successfully"
fi

# Get repository URI
FAST_API_ECR_REPOSITORY_URI=$(aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$FAST_API_ECR_REPO_NAME" \
    --query 'repositories[0].repositoryUri' \
    --output text)

echo -e "${GREEN}[OK]${NC} Fast API ECR Repository URI: $FAST_API_ECR_REPOSITORY_URI"

echo -e "${GREEN}[STEP 2]${NC} Updating configuration with Fast API Docker settings..."

# Add Fast API-specific configuration to .env
if ! grep -q "FAST_API_ECR_REPOSITORY_URI" "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "# Fast API Docker configuration (300 series)" >> "$CONFIG_FILE"
    echo "FAST_API_ECR_REPOSITORY_URI=$FAST_API_ECR_REPOSITORY_URI" >> "$CONFIG_FILE"
    echo "FAST_API_ECR_REPO_NAME=$FAST_API_ECR_REPO_NAME" >> "$CONFIG_FILE"
    echo "FAST_API_DOCKER_IMAGE_TAG=latest" >> "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Fast API configuration added to .env"
else
    # Update existing values
    sed -i "s|FAST_API_ECR_REPOSITORY_URI=.*|FAST_API_ECR_REPOSITORY_URI=$FAST_API_ECR_REPOSITORY_URI|" "$CONFIG_FILE"
    sed -i "s|FAST_API_ECR_REPO_NAME=.*|FAST_API_ECR_REPO_NAME=$FAST_API_ECR_REPO_NAME|" "$CONFIG_FILE"
    echo -e "${GREEN}[OK]${NC} Fast API configuration updated in .env"
fi

echo -e "${GREEN}[STEP 3]${NC} Creating Fast API directory structure..."

# Create Fast API Docker directory
mkdir -p docker/fast-api/{scripts,models}
echo -e "${GREEN}[OK]${NC} Created docker/fast-api directory structure"

echo -e "${GREEN}[STEP 4]${NC} Creating Fast API helper scripts..."

# Create Fast API ECR login helper
cat > scripts/fast-api-ecr-login.sh << 'EOF'
#!/bin/bash
# Fast API ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR for Fast API..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$FAST_API_ECR_REPOSITORY_URI"
echo "✅ Fast API ECR login successful"
EOF

chmod +x scripts/fast-api-ecr-login.sh

# Create Fast API image build helper
cat > scripts/build-fast-api-gpu.sh << 'EOF'
#!/bin/bash
# Fast API GPU Image Build Script
set -e

source .env
echo "🚀 Building Fast API GPU Docker image..."
echo "Repository: $FAST_API_ECR_REPOSITORY_URI"

cd "$(dirname "$0")/.."

# Build image with Fast API GPU tag
docker build \
    -f docker/fast-api/Dockerfile \
    -t "$FAST_API_ECR_REPO_NAME:$FAST_API_DOCKER_IMAGE_TAG" \
    -t "$FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG" \
    docker/fast-api/

echo "✅ Fast API Docker image built successfully"
echo "Local tag: $FAST_API_ECR_REPO_NAME:$FAST_API_DOCKER_IMAGE_TAG"
echo "ECR tag: $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG"
EOF

chmod +x scripts/build-fast-api-gpu.sh

echo -e "${GREEN}[OK]${NC} Helper scripts created:"
echo "  - scripts/fast-api-ecr-login.sh (ECR authentication)"
echo "  - scripts/build-fast-api-gpu.sh (Build Fast API image)"

# Update status tracking
echo "step-301-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API ECR Repository Setup Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Validate ECR configuration:"
echo "   ./scripts/step-302-fast-api-validate-ecr-configuration.sh"
echo
echo "2. Build the Fast API GPU image:"
echo "   ./scripts/step-310-fast-api-build-gpu-docker-image.sh"
echo
echo -e "${YELLOW}[CONFIGURATION]${NC}"
echo "ECR Repository: $FAST_API_ECR_REPOSITORY_URI"
echo "Image Tag: latest"
echo "Directory: docker/fast-api/"