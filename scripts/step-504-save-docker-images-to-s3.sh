#!/bin/bash
set -e

echo "💾 SAVING DOCKER IMAGES TO S3"
echo "=============================="

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found."
    exit 1
fi

# Configuration
S3_BUCKET="${MODELS_CACHE_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${MODELS_CACHE_PREFIX:-bintarball}/docker-images"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Function to save and upload Docker image
save_docker_image_to_s3() {
    local image_uri=$1
    local image_name=$2
    local worker_ip=$3
    
    echo ""
    echo "📦 Processing $image_name..."
    echo "  Image: $image_uri"
    
    # Extract version/tag info
    local image_tag=$(echo "$image_uri" | cut -d: -f2)
    local filename="${image_name}-${image_tag}-${TIMESTAMP}.tar.gz"
    local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${filename}"
    
    echo "  🔄 Saving Docker image to tar.gz..."
    ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$worker_ip \
        "docker save $image_uri | gzip > /tmp/${filename}" || {
        echo "  ❌ Failed to save Docker image"
        return 1
    }
    
    # Get file size
    local size=$(ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$worker_ip \
        "ls -lh /tmp/${filename} | awk '{print \$5}'")
    echo "  📏 Compressed size: $size"
    
    echo "  ☁️ Uploading to S3..."
    ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$worker_ip \
        "aws s3 cp /tmp/${filename} $s3_path --region $AWS_REGION" || {
        echo "  ❌ Failed to upload to S3"
        return 1
    }
    
    echo "  🧹 Cleaning up temporary file..."
    ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$worker_ip \
        "rm /tmp/${filename}"
    
    echo "  ✅ Saved to: $s3_path"
    
    # Save location for future use
    echo "${image_name}_s3_path=$s3_path" >> docker-images-s3.env
    echo "${image_name}_s3_key=${S3_PREFIX}/${filename}" >> docker-images-s3.env
}

# Get worker IP
if [ -z "$1" ]; then
    # Try to get from .setup-status
    if [ -f ".setup-status" ]; then
        WORKER_IP=$(grep "hybrid-worker-public-ip=" .setup-status | tail -1 | cut -d= -f2) || true
    fi
    
    if [ -z "$WORKER_IP" ]; then
        echo "❌ No worker IP provided. Usage: $0 <worker-ip>"
        exit 1
    fi
else
    WORKER_IP=$1
fi

echo "🎯 Using worker: $WORKER_IP"

# Check if worker is accessible
echo "🔍 Checking worker connectivity..."
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP "echo 'Connected'" >/dev/null 2>&1; then
    echo "❌ Cannot connect to worker at $WORKER_IP"
    exit 1
fi

# List Docker images on worker
echo ""
echo "📋 Docker images on worker:"
ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'"

# Create S3 paths file
> docker-images-s3.env
echo "# Docker Images S3 Locations - Generated $(date)" >> docker-images-s3.env

# Save Whisper image
if ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "docker images | grep -q whisper-worker"; then
    save_docker_image_to_s3 "$WHISPER_ECR_URI" "whisper-gpu" "$WORKER_IP"
else
    echo "⚠️ Whisper image not found on worker"
fi

# Save Voxtral image  
if ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "docker images | grep -q voxtral-gpu"; then
    save_docker_image_to_s3 "$VOXTRAL_ECR_URI" "voxtral-gpu" "$WORKER_IP"
else
    echo "⚠️ Voxtral image not found on worker"
fi

echo ""
echo "✅ DOCKER IMAGE BACKUP COMPLETE!"
echo "================================"
echo ""
echo "📋 Summary:"
echo "  S3 Bucket: $S3_BUCKET"
echo "  S3 Prefix: $S3_PREFIX"
echo "  Locations saved to: docker-images-s3.env"
echo ""
echo "🚀 To restore images on a new instance:"
echo "  1. Download: aws s3 cp s3://path/to/image.tar.gz ."
echo "  2. Load: docker load < image.tar.gz"
echo "  3. Tag: docker tag <image-id> <original-uri>"
echo ""
echo "💡 Add to future launch scripts for faster deployment!"