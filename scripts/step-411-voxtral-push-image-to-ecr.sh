#!/bin/bash

# step-411-voxtral-push-image-to-ecr.sh - Push Real Voxtral image to ECR

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
echo -e "${BLUE}📤 Push Real Voxtral Image to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Validate prerequisites
echo -e "${GREEN}[STEP 1]${NC} Validating prerequisites..."

if [ -z "$REAL_VOXTRAL_ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} REAL_VOXTRAL_ECR_REPOSITORY_URI not set. Run step-401 first."
    exit 1
fi

# Check if image exists locally
if ! docker images "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" | grep -q "$REAL_VOXTRAL_DOCKER_IMAGE_TAG"; then
    echo -e "${RED}[ERROR]${NC} Local image not found: $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
    echo "Run step-410-voxtral-build-gpu-docker-image.sh first."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Prerequisites validated"

# Show image information
echo -e "${GREEN}[STEP 2]${NC} Image information..."
docker images "$REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

# ECR login
echo -e "${GREEN}[STEP 3]${NC} Logging into ECR..."
echo "Region: $AWS_REGION"
echo "Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo -e "${GREEN}[OK]${NC} ECR login successful"

# Check repository exists
echo -e "${GREEN}[STEP 4]${NC} Verifying ECR repository..."
if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REAL_VOXTRAL_ECR_REPO_NAME" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} ECR repository not found: $REAL_VOXTRAL_ECR_REPO_NAME"
    echo "Run step-401-voxtral-setup-ecr-repository.sh first."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} ECR repository verified"

# Push image
echo -e "${GREEN}[STEP 5]${NC} Pushing image to ECR..."
echo "This may take several minutes depending on image size and network speed..."

PUSH_START_TIME=$(date +%s)

# Push with progress indication
echo -e "${BLUE}[PUSH]${NC} Pushing $REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
docker push "$REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"

PUSH_END_TIME=$(date +%s)
PUSH_DURATION=$((PUSH_END_TIME - PUSH_START_TIME))

echo -e "${GREEN}[OK]${NC} Image pushed successfully in ${PUSH_DURATION} seconds"

# Verify push
echo -e "${GREEN}[STEP 6]${NC} Verifying pushed image..."
ECR_IMAGES=$(aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$REAL_VOXTRAL_ECR_REPO_NAME" \
    --query 'imageDetails[?imageDigest!=null]' \
    --output json)

if [ "$ECR_IMAGES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No images found in ECR repository"
    exit 1
fi

# Get image details
IMAGE_COUNT=$(echo "$ECR_IMAGES" | jq length)
LATEST_IMAGE=$(echo "$ECR_IMAGES" | jq -r '.[0] | "\(.imagePushedAt) - \(.imageSizeInBytes/1024/1024 | floor)MB"')

echo -e "${GREEN}[OK]${NC} Image verified in ECR"
echo "Images in repository: $IMAGE_COUNT"
echo "Latest image: $LATEST_IMAGE"

# Show repository URI for easy access
echo -e "${GREEN}[STEP 7]${NC} Repository information..."
echo "ECR Repository URI: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "Full image reference: $REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"

# Update status tracking
echo "step-411-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral ECR Push Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[PUSH SUMMARY]${NC}"
echo "Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "Tag: $REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "Push time: ${PUSH_DURATION} seconds"
echo "Images in ECR: $IMAGE_COUNT"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Launch GPU instances with Real Voxtral:"
echo "   ./scripts/step-420-voxtral-launch-gpu-instances.sh"
echo
echo "2. Test the deployment:"
echo "   ./scripts/step-430-voxtral-test-transcription.sh"
echo
echo -e "${YELLOW}[CLEANUP]${NC}"
echo "To free local disk space (optional):"
echo "  docker rmi $REAL_VOXTRAL_ECR_REPO_NAME:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"
echo "  docker rmi $REAL_VOXTRAL_ECR_REPOSITORY_URI:$REAL_VOXTRAL_DOCKER_IMAGE_TAG"