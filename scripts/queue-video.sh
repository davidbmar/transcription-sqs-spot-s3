#!/bin/bash
set -e

# Script to send a YouTube video to the SQS queue

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Check if YouTube URL is provided
if [ -z "$1" ] && [ -z "$YOUTUBE_URL" ]; then
    echo "Error: No YouTube URL provided."
    echo "Usage: $0 <youtube_url>"
    echo "Or set YOUTUBE_URL environment variable."
    exit 1
fi

# Use the provided URL or the environment variable
YOUTUBE_URL="${1:-$YOUTUBE_URL}"

# Check required environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$QUEUE_URL" ]; then
    echo "Error: Missing required environment variables."
    echo "Please set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and QUEUE_URL"
    echo "either in a .env file or as environment variables."
    exit 1
fi

# Send the video to the queue
echo "Sending YouTube video to the queue: $YOUTUBE_URL"
python3 scripts/send_to_queue.py \
    --youtube_url "$YOUTUBE_URL" \
    --queue_url "$QUEUE_URL" \
    --region "${AWS_REGION:-us-east-1}"
