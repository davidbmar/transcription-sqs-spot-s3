#!/bin/bash

# step-313-fast-api-push-s3-image.sh - Push S3-enhanced Fast API image to ECR

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
echo -e "${BLUE}📤 Push S3-Enhanced Fast API to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Login to ECR
echo -e "${GREEN}[STEP 1]${NC} Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $FAST_API_ECR_REPOSITORY_URI

# Verify images exist locally
echo -e "${GREEN}[STEP 2]${NC} Verifying local images..."
if ! docker images | grep -q "$FAST_API_ECR_REPOSITORY_URI.*s3-enhanced"; then
    echo -e "${RED}[ERROR]${NC} S3-enhanced image not found locally"
    echo "Run ./scripts/step-312-fast-api-build-s3-enhanced-image.sh first"
    exit 1
fi

# Push images
echo -e "${GREEN}[STEP 3]${NC} Pushing images to ECR..."

echo -e "${YELLOW}[INFO]${NC} Pushing s3-enhanced tag..."
docker push $FAST_API_ECR_REPOSITORY_URI:s3-enhanced

echo -e "${YELLOW}[INFO]${NC} Pushing latest-s3 tag..."
docker push $FAST_API_ECR_REPOSITORY_URI:latest-s3

# Verify push succeeded
echo -e "${GREEN}[STEP 4]${NC} Verifying images in ECR..."
aws ecr describe-images \
    --repository-name "$FAST_API_ECR_REPO_NAME" \
    --region "$AWS_REGION" \
    --query 'imageDetails[?contains(imageTags, `s3-enhanced`) || contains(imageTags, `latest-s3`)].[imageTags[0],imagePushedAt,imageSizeInBytes]' \
    --output table

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ S3-Enhanced Images Pushed to ECR${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[AVAILABLE TAGS]${NC}"
echo "• s3-enhanced - Main S3-enabled version"
echo "• latest-s3 - Alias for s3-enhanced"
echo "• fixed - Previous NumPy fix (no S3)"
echo "• latest - Original version"
echo
echo -e "${GREEN}[DEPLOYMENT OPTIONS]${NC}"
echo "1. Deploy new instance with S3 support:"
echo "   ./scripts/step-300-fast-api-smart-deploy.sh --tag=s3-enhanced"
echo
echo "2. Update existing instance (manual):"
echo "   ssh into instance and pull new image"
echo
echo -e "${GREEN}[S3 API USAGE - 3 Endpoints Available]${NC}"
echo ""
echo "1. S3 to S3 transcription (s3:// URIs):"
echo 'curl -X POST http://your-api:8000/transcribe-s3 \'
echo '  -H "Content-Type: application/json" \'
echo '  -d '"'"'{"s3_input_path": "s3://bucket/audio.mp3",
       "s3_output_path": "s3://bucket/transcript.json",
       "return_text": false}'"'"
echo ""
echo "2. URL transcription (http/https URLs):"
echo 'curl -X POST http://your-api:8000/transcribe-url \'
echo '  -H "Content-Type: application/json" \'
echo '  -d '"'"'{"audio_url": "https://example.com/audio.mp3"}'"'"
echo ""
echo "3. File upload (original functionality):"
echo 'curl -X POST -F '"'"'file=@audio.mp3'"'"' http://your-api:8000/transcribe'