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
