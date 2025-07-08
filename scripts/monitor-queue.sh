#!/bin/bash
# monitor-queue.sh - Check SQS queue status

CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: .env file not found"
    exit 1
fi

echo "🔍 QUEUE STATUS"
aws sqs get-queue-attributes \
    --region $AWS_REGION \
    --queue-url $QUEUE_URL \
    --attribute-names All | \
    jq -r '.Attributes | "Visible: \(.ApproximateNumberOfMessages), Processing: \(.ApproximateNumberOfMessagesNotVisible)"'