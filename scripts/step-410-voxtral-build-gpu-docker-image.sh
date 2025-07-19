#!/bin/bash

# step-410-voxtral-build-gpu-docker-image.sh - Build Real Voxtral GPU Docker image

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
echo -e "${BLUE}🐳 Build Real Voxtral GPU Docker Image${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Validate prerequisites
echo -e "${GREEN}[STEP 1]${NC} Validating prerequisites..."

if [ -z "$REAL_VOXTRAL_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} REAL_VOXTRAL_ECR_REPOSITORY_URI not set. Run step-401 first."
    exit 1
fi

if [ ! -f "docker/real-voxtral/Dockerfile" ]; then
    echo -e "${RED}[ERROR]${NC} Real Voxtral Dockerfile not found. Run step-401 first."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker not found. Please install Docker."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker daemon not running. Please start Docker."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Prerequisites validated"

# Check available disk space
echo -e "${GREEN}[STEP 2]${NC} Checking disk space..."
AVAILABLE_SPACE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE_SPACE" -lt 10 ]; then
    echo -e "${YELLOW}[WARNING]${NC} Low disk space: ${AVAILABLE_SPACE}GB available"
    echo "Real Voxtral image build requires ~8-10GB. Consider freeing space."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}[OK]${NC} Sufficient disk space: ${AVAILABLE_SPACE}GB available"
fi

# Display build configuration
echo -e "${GREEN}[STEP 3]${NC} Build configuration..."
echo "Repository URI: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "Repository Name: $REAL_VOXTRAL_ECR_REPO_NAME"
echo "Image Tag: $REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "Model ID: $VOXTRAL_MODEL_ID"
echo "Build Context: docker/real-voxtral/"

# Check for existing images
echo -e "${GREEN}[STEP 4]${NC} Checking for existing images..."
if docker images "$REAL_VOXTRAL_ECR_REPO_NAME" | grep -q "$REAL_VOXTRAL_DOCKER_IMAGE_TAG"; then
    echo -e "${YELLOW}[WARNING]${NC} Existing image found: $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
    echo "This will overwrite the existing image."
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Start build process
echo -e "${GREEN}[STEP 5]${NC} Building Real Voxtral Docker image..."
echo "This may take 10-15 minutes for the initial build..."

BUILD_START_TIME=$(date +%s)

# Build the image with comprehensive logging
echo -e "${BLUE}[BUILD]${NC} Starting Docker build..."
docker build \
    --progress=plain \
    --no-cache \
    -f docker/real-voxtral/Dockerfile \
    -t "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" \
    -t "$REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" \
    docker/real-voxtral/ 2>&1 | tee docker-build.log

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))

echo -e "${GREEN}[OK]${NC} Docker build completed in ${BUILD_DURATION} seconds"

# Verify the built image
echo -e "${GREEN}[STEP 6]${NC} Verifying built image..."

# Check image exists
if ! docker images "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" | grep -q "$REAL_VOXTRAL_DOCKER_IMAGE_TAG"; then
    echo -e "${RED}[ERROR]${NC} Built image not found!"
    exit 1
fi

# Get image size
IMAGE_SIZE=$(docker images "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" --format "table {{.Size}}" | tail -n 1)
echo -e "${GREEN}[OK]${NC} Image built successfully"
echo "Image size: $IMAGE_SIZE"

# Test container startup (quick test)
echo -e "${GREEN}[STEP 7]${NC} Testing container startup..."
echo "Running quick container test (30 second timeout)..."

# Start container in background
CONTAINER_ID=$(docker run -d \
    --name "voxtral-test-$$" \
    --gpus all \
    -p 8000:8000 \
    -p 8080:8080 \
    "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG")

echo "Container ID: $CONTAINER_ID"

# Wait for health check
echo "Waiting for health check (30s timeout)..."
for i in {1..30}; do
    if curl -f -s http://localhost:8080/health >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Health check passed${NC}"
        break
    fi
    echo -n "."
    sleep 1
done

echo

# Get container logs (last 20 lines)
echo -e "${BLUE}[LOGS]${NC} Container startup logs (last 20 lines):"
docker logs "$CONTAINER_ID" | tail -20

# Cleanup test container
echo -e "${GREEN}[CLEANUP]${NC} Stopping test container..."
docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true

# Update status tracking
echo "step-410-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral Docker Build Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[BUILD SUMMARY]${NC}"
echo "Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "Local tag: $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "Image size: $IMAGE_SIZE"
echo "Build time: ${BUILD_DURATION} seconds"
echo "Model: $VOXTRAL_MODEL_ID"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Push image to ECR:"
echo "   ./scripts/step-411-voxtral-push-image-to-ecr.sh"
echo
echo "2. Launch GPU instances:"
echo "   ./scripts/step-420-voxtral-launch-gpu-instances.sh"
echo
echo -e "${YELLOW}[TESTING]${NC}"
echo "To test locally:"
echo "  docker run --gpus all -p 8000:8000 -p 8080:8080 $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "  curl http://localhost:8080/health"