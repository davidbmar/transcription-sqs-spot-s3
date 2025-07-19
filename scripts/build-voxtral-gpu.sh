#!/bin/bash
# Voxtral GPU Image Build Script
set -e

source .env
echo "🚀 Building Voxtral GPU Docker image..."
echo "Repository: $VOXTRAL_ECR_REPOSITORY_URI"

cd "$(dirname "$0")/.."

# Build image with Voxtral GPU tag
docker build \
    -f docker/voxtral/Dockerfile \
    -t "$VOXTRAL_ECR_REPO_NAME:$VOXTRAL_DOCKER_IMAGE_TAG" \
    -t "$VOXTRAL_ECR_REPOSITORY_URI:$VOXTRAL_DOCKER_IMAGE_TAG" \
    docker/voxtral/

echo "✅ Voxtral Docker image built successfully"
echo "Local tag: $VOXTRAL_ECR_REPO_NAME:$VOXTRAL_DOCKER_IMAGE_TAG"
echo "ECR tag: $VOXTRAL_ECR_REPOSITORY_URI:$VOXTRAL_DOCKER_IMAGE_TAG"
