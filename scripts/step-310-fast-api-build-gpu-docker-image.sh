#!/bin/bash

# step-310-fast-api-build-gpu-docker-image.sh - Build Fast API GPU Docker image

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
echo -e "${BLUE}🎤 Build Fast API GPU Docker Image${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ -z "$FAST_API_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} FAST_API_ECR_REPOSITORY_URI not found. Run step-301-fast-api-setup-ecr-repository.sh first."
    exit 1
fi

echo -e "${GREEN}[STEP 1]${NC} Checking Docker environment..."

# Check Docker installation
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARNING]${NC} Docker is not installed"
    echo "Please install Docker first: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check Docker daemon
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker daemon is not running"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Docker is installed and running"
docker --version

echo -e "${GREEN}[STEP 2]${NC} Logging into ECR..."
./scripts/fast-api-ecr-login.sh

echo -e "${GREEN}[STEP 3]${NC} Building Fast API Docker image..."
echo "Repository: $FAST_API_ECR_REPOSITORY_URI"
echo "Tag: $FAST_API_DOCKER_IMAGE_TAG"

# Build the image
cd "$(dirname "$0")/.."

echo -e "${YELLOW}[INFO]${NC} Building Docker image..."
docker build \
    -f docker/fast-api/Dockerfile \
    -t "$FAST_API_ECR_REPO_NAME:$FAST_API_DOCKER_IMAGE_TAG" \
    -t "$FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG" \
    --platform linux/amd64 \
    docker/fast-api/

echo -e "${GREEN}[OK]${NC} Docker image built successfully"

echo -e "${GREEN}[STEP 4]${NC} Verifying image..."
docker images | grep -E "$FAST_API_ECR_REPO_NAME|fast-api"

# Get image size
IMAGE_SIZE=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep "$FAST_API_ECR_REPO_NAME" | awk '{print $2}')
echo -e "${GREEN}[INFO]${NC} Image size: $IMAGE_SIZE"

# Update status tracking
echo "step-310-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API Docker Image Built${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Push image to ECR:"
echo "   ./scripts/step-311-fast-api-push-image-to-ecr.sh"
echo
echo "2. Launch GPU instances with Fast API:"
echo "   ./scripts/step-320-fast-api-launch-gpu-instances.sh"
echo
echo -e "${YELLOW}[IMAGE INFO]${NC}"
echo "Local tag: $FAST_API_ECR_REPO_NAME:$FAST_API_DOCKER_IMAGE_TAG"
echo "ECR tag: $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG"
echo "Size: $IMAGE_SIZE"