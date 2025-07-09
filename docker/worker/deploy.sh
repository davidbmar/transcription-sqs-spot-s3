#!/bin/bash
set -e

# Quick deployment script for Docker worker
echo "🚀 Deploying Docker worker from ECR..."

# Load configuration
if [ -f "../../.env" ]; then
    source "../../.env"
fi

# Pull latest image
docker pull "821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest"

# Run container with required environment variables
docker run -d \
    --name whisper-worker-$(date +%s) \
    --gpus all \
    --restart unless-stopped \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e TRANSCRIPT_BUCKET="$TRANSCRIPT_BUCKET" \
    -p 8080:8080 \
    "821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest"

echo "✅ Docker worker deployed!"
echo "   Health check: http://localhost:8080/health"
