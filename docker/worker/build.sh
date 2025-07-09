#!/bin/bash
set -e

# Load configuration
if [ -f "../../.env" ]; then
    source "../../.env"
fi

IMAGE_NAME="${ECR_REPOSITORY_URI}:latest"
IMAGE_TAG="${ECR_REPOSITORY_URI}:$(date +%Y%m%d-%H%M%S)"

echo "🏗️ Building Docker image: $IMAGE_NAME"
echo ""

# Build the image
docker build -t "$IMAGE_NAME" -t "$IMAGE_TAG" -f Dockerfile ../..

echo ""
echo "✅ Docker image built successfully!"
echo "   Latest: $IMAGE_NAME"
echo "   Tagged: $IMAGE_TAG"
