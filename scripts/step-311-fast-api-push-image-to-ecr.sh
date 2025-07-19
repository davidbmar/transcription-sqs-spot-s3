#!/bin/bash

# step-311-fast-api-push-image-to-ecr.sh - Push Fast API GPU image to ECR

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
echo -e "${BLUE}🎤 Push Fast API Image to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ -z "$FAST_API_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} FAST_API_ECR_REPOSITORY_URI not found. Run step-301-fast-api-setup-ecr-repository.sh first."
    exit 1
fi

# Check if image exists locally
if ! docker images "$FAST_API_ECR_REPO_NAME:$FAST_API_DOCKER_IMAGE_TAG" --format "table {{.Repository}}" | grep -q "$FAST_API_ECR_REPO_NAME"; then
    echo -e "${RED}[ERROR]${NC} Fast API Docker image not found locally. Run step-310-fast-api-build-gpu-docker-image.sh first."
    exit 1
fi

echo -e "${GREEN}[STEP 1]${NC} Authenticating with ECR..."

# Login to ECR
echo -e "${GREEN}[INFO]${NC} Logging into ECR repository..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$FAST_API_ECR_REPOSITORY_URI"
echo -e "${GREEN}[OK]${NC} ECR authentication successful"

echo -e "${GREEN}[STEP 2]${NC} Pushing Fast API image to ECR..."
echo "Repository: $FAST_API_ECR_REPOSITORY_URI"
echo "Tag: $FAST_API_DOCKER_IMAGE_TAG"

# Get image size before push
IMAGE_SIZE=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep "$FAST_API_ECR_REPO_NAME" | awk '{print $2}')
echo -e "${YELLOW}[INFO]${NC} Image size: $IMAGE_SIZE"

# Push the image
echo -e "${YELLOW}[INFO]${NC} Pushing image (this may take several minutes for a ~10GB image)..."
docker push "$FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG"

echo -e "${GREEN}[OK]${NC} Image pushed successfully to ECR"

# Verify the push
echo -e "${GREEN}[STEP 3]${NC} Verifying image in ECR..."
aws ecr describe-images \
    --repository-name "$FAST_API_ECR_REPO_NAME" \
    --region "$AWS_REGION" \
    --query 'imageDetails[0].[imageSizeInBytes, imagePushedAt]' \
    --output text

# Update status tracking
echo "step-311-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API Image Pushed to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Launch GPU instances with Fast API:"
echo "   ./scripts/step-320-fast-api-launch-gpu-instances.sh"
echo
echo "2. Test Fast API transcription:"
echo "   ./scripts/step-330-fast-api-test-voice-transcription.sh"
echo
echo -e "${YELLOW}[IMAGE INFO]${NC}"
echo "ECR URI: $FAST_API_ECR_REPOSITORY_URI:$FAST_API_DOCKER_IMAGE_TAG"
echo "Size: $IMAGE_SIZE"