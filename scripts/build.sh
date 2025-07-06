#!/bin/bash
set -e

# Script to build the Docker image

echo "Building YouTube Phrase Scanner Docker image..."
docker build -t youtube-phrase-scanner -f docker/Dockerfile .

echo "Image built successfully. You can run it with:"
echo "docker run --gpus all -e AWS_ACCESS_KEY_ID=your_key -e AWS_SECRET_ACCESS_KEY=your_secret youtube-phrase-scanner --queue_url YOUR_QUEUE_URL --s3_bucket YOUR_BUCKET"
