#!/bin/bash

# step-211-docker-push-image-to-ecr.sh - Push GPU worker image to ECR (PATH 200)

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
echo -e "${BLUE}Push GPU Worker Image to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ -z "$ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} ECR_REPOSITORY_URI not found. Run step-200-docker-setup-ecr-repository.sh first."
    exit 1
fi

# Check if image exists locally
if ! docker images "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" --format "table {{.Repository}}" | grep -q "$ECR_REPO_NAME"; then
    echo -e "${RED}[ERROR]${NC} Docker image not found locally. Run step-210-docker-build-gpu-worker-image.sh first."
    exit 1
fi

echo -e "${GREEN}[STEP 1]${NC} Authenticating with ECR..."

# Login to ECR
echo -e "${GREEN}[INFO]${NC} Logging into ECR repository..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI"
echo -e "${GREEN}[OK]${NC} ECR authentication successful"

echo -e "${GREEN}[STEP 2]${NC} Pushing image to ECR..."
echo "Source: $ECR_REPO_NAME:$DOCKER_IMAGE_TAG"
echo "Destination: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"

PUSH_START_TIME=$(date +%s)

# Push the image
docker push "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"

PUSH_END_TIME=$(date +%s)
PUSH_DURATION=$((PUSH_END_TIME - PUSH_START_TIME))

echo -e "${GREEN}[OK]${NC} Image pushed successfully in ${PUSH_DURATION}s"

echo -e "${GREEN}[STEP 3]${NC} Verifying push..."

# Verify the image exists in ECR
IMAGE_DIGEST=$(aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$ECR_REPO_NAME" \
    --image-ids imageTag="$DOCKER_IMAGE_TAG" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$IMAGE_DIGEST" = "NOT_FOUND" ]; then
    echo -e "${RED}[ERROR]${NC} Failed to verify image in ECR"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Image verified in ECR"
echo "Digest: $IMAGE_DIGEST"

# Get image size in ECR
IMAGE_SIZE_BYTES=$(aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$ECR_REPO_NAME" \
    --image-ids imageTag="$DOCKER_IMAGE_TAG" \
    --query 'imageDetails[0].imageSizeInBytes' \
    --output text)

IMAGE_SIZE_MB=$((IMAGE_SIZE_BYTES / 1024 / 1024))

echo -e "${GREEN}[STEP 4]${NC} ECR repository status..."

# List recent images
echo -e "${GREEN}[INFO]${NC} Recent images in repository:"
aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$ECR_REPO_NAME" \
    --query 'sort_by(imageDetails, &imagePushedAt)[-5:].[imageDigest[0:12], imageTags[0], round(imageSizeInBytes/`1024`/`1024`), imagePushedAt]' \
    --output table

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Image Push Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[ECR DETAILS]${NC}"
echo "Repository: $ECR_REPOSITORY_URI"
echo "Tag: $DOCKER_IMAGE_TAG"
echo "Digest: $IMAGE_DIGEST"
echo "Size: ${IMAGE_SIZE_MB} MB"
echo "Push time: ${PUSH_DURATION}s"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Launch Docker GPU workers:"
echo "   ./scripts/step-220-docker-launch-gpu-workers.sh"
echo
echo "2. Test the deployment:"
echo "   ./scripts/step-235-docker-test-transcription-workflow.sh"
echo
echo -e "${YELLOW}[ECR MANAGEMENT]${NC}"
echo "View in AWS Console:"
echo "  https://console.aws.amazon.com/ecr/repositories/$ECR_REPO_NAME?region=$AWS_REGION"

# Update status tracking
echo "step-211-completed=$(date)" >> .setup-status