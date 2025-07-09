#!/bin/bash
# Build Docker image for transcription worker

set -e

# Configuration
IMAGE_NAME="transcription-worker"
TAG="latest"
REGISTRY="your-account.dkr.ecr.us-east-2.amazonaws.com"  # Update with your ECR registry

echo "🐳 Building Docker image: $IMAGE_NAME:$TAG"

# Build the image
docker build -t "$IMAGE_NAME:$TAG" -f Dockerfile .

# Tag for registry
docker tag "$IMAGE_NAME:$TAG" "$REGISTRY/$IMAGE_NAME:$TAG"

echo "✅ Image built successfully!"
echo ""
echo "📋 Next steps:"
echo "1. Test locally:"
echo "   docker run --rm $IMAGE_NAME:$TAG --help"
echo ""
echo "2. Push to registry:"
echo "   aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin $REGISTRY"
echo "   docker push $REGISTRY/$IMAGE_NAME:$TAG"
echo ""
echo "3. Launch workers:"
echo "   ./scripts/launch-docker-worker.sh --cpu-only"
echo ""
echo "📊 Image size:"
docker images "$IMAGE_NAME:$TAG" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"