#!/bin/bash

# create-default-config.sh - Create default configuration for testing

# Create default configuration
cat > transcription-config.env << 'EOF'
# Audio Transcription System Configuration
# Generated on $(date)
# Environment: dev

# AWS Configuration
export AWS_ACCOUNT_ID="821850226835"
export AWS_REGION="us-east-2"
export IAM_USER="davidbmar"
export ENVIRONMENT="dev"

# Queue Configuration
export QUEUE_NAME="audio-transcription-queue"
export DLQ_NAME="audio-transcription-dlq"
export QUEUE_PREFIX="audio-transcription"
export MESSAGE_RETENTION_SECONDS="1209600"
export VISIBILITY_TIMEOUT="1800"
export MAX_RECEIVE_COUNT="3"

# S3 Configuration
export METRICS_BUCKET="transcription-metrics-20250705"
export AUDIO_BUCKET="dbm-cf-2-web"

# Worker Configuration
export WHISPER_MODEL="large-v3"
export IDLE_TIMEOUT_MINUTES="5"
export CHUNK_SIZE="30"

# EC2/Spot Configuration
export INSTANCE_TYPE="g4dn.xlarge"
export SPOT_PRICE="0.50"
export AMI_ID="ami-0c7217cdde317cfec"
export SECURITY_GROUP_ID=""
export KEY_NAME=""
export SUBNET_ID=""

# Scaling Configuration
export MIN_INSTANCES="0"
export MAX_INSTANCES="10"
export MINUTES_PER_INSTANCE_HOUR="60"
export SCALE_UP_THRESHOLD="30"
export SCALE_DOWN_THRESHOLD="10"

# Computed values (set after resources are created)
export QUEUE_URL="https://sqs.us-east-2.amazonaws.com/821850226835/audio-transcription-queue"
export DLQ_URL="https://sqs.us-east-2.amazonaws.com/821850226835/audio-transcription-dlq"
export QUEUE_ARN=""
export DLQ_ARN=""
EOF

echo "Created transcription-config.env with default values"

# Create worker config
cat > worker-config.env << 'EOF'
# Worker Configuration
# This file is used by worker instances

# Queue Configuration
export QUEUE_URL="https://sqs.us-east-2.amazonaws.com/821850226835/audio-transcription-queue"
export QUEUE_REGION="us-east-2"

# S3 Configuration
export S3_BUCKET="transcription-metrics-20250705"
export AUDIO_BUCKET="dbm-cf-2-web"

# Worker Settings
export WHISPER_MODEL="large-v3"
export IDLE_TIMEOUT="5"
export CHUNK_SIZE="30"
export USE_GPU="true"
export TEMP_DIR="/tmp"

# AWS Region
export AWS_DEFAULT_REGION="us-east-2"
EOF

echo "Created worker-config.env"

# Create docker env
cat > docker.env << 'EOF'
# Docker Environment Variables
AWS_REGION=us-east-2
QUEUE_URL=https://sqs.us-east-2.amazonaws.com/821850226835/audio-transcription-queue
S3_BUCKET=transcription-metrics-20250705
AUDIO_BUCKET=dbm-cf-2-web
WHISPER_MODEL=large-v3
IDLE_TIMEOUT_MINUTES=5
CHUNK_SIZE=30
EOF

echo "Created docker.env"

echo ""
echo "Configuration files created with existing queue values."
echo "You can now test sending messages with:"
echo ""
echo "  source transcription-config.env"
echo "  python3 scripts/send_to_queue.py \\"
echo "    --s3_input_path \"s3://bucket/audio.mp3\" \\"
echo "    --s3_output_path \"s3://bucket/transcript.json\""