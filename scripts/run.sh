#!/bin/bash
set -e

# Script to run the Docker container with the worker

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Check required environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: Missing required environment variables."
    echo "Please set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, QUEUE_URL, and S3_BUCKET"
    echo "either in a .env file or as environment variables."
    exit 1
fi

# Run the Docker container
echo "Running YouTube Phrase Scanner worker..."
docker run --gpus all \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
    youtube-phrase-scanner \
    --queue_url "$QUEUE_URL" \
    --s3_bucket "$S3_BUCKET" \
    --region "${AWS_REGION:-us-east-1}"
