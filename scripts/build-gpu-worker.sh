#!/bin/bash
# GPU Worker Image Build Script
set -e

source .env
echo "🚀 Building GPU worker Docker image..."
echo "Repository: $ECR_REPOSITORY_URI"

cd "$(dirname "$0")/.."

# Build image with GPU worker tag
docker build \
    -f docker/gpu-worker/Dockerfile \
    -t "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" \
    -t "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG" \
    .

echo "✅ Docker image built successfully"
echo "Local tag: $ECR_REPO_NAME:$DOCKER_IMAGE_TAG"
echo "ECR tag: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"
