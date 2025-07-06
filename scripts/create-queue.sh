#!/bin/bash

# Create SQS queue in your account
QUEUE_NAME="transcription-queue"
REGION="us-east-2"

# Create the queue
QUEUE_URL=$(aws sqs create-queue \
  --queue-name $QUEUE_NAME \
  --region $REGION \
  --attributes '{
    "MessageRetentionPeriod": "1209600",
    "VisibilityTimeout": "1800",
    "ReceiveMessageWaitTimeSeconds": "20"
  }' \
  --query 'QueueUrl' \
  --output text)

echo "Queue created: $QUEUE_URL"

# Get the queue ARN
QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --region $REGION \
  --query 'Attributes.QueueArn' \
  --output text)

echo "Queue ARN: $QUEUE_ARN"