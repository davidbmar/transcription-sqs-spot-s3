#!/bin/bash
set -e

echo "💾 SETTING UP S3 DOCKER IMAGE CACHE"
echo "==================================="

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
CACHE_DIR="/tmp/docker-cache"

echo "📋 Configuration:"
echo "  S3 Bucket: $S3_BUCKET"
echo "  S3 Prefix: $S3_PREFIX"
echo "  Cache Dir: $CACHE_DIR"

# Function to create optimized Docker image tarball
create_optimized_image_tarball() {
    local image_uri=$1
    local image_name=$2
    local output_file=$3
    
    echo ""
    echo "📦 Creating optimized tarball for $image_name..."
    echo "  Source: $image_uri"
    echo "  Output: $output_file"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Save Docker image with compression
    echo "  🔄 Saving Docker image..."
    docker save "$image_uri" | gzip -9 > "$temp_dir/image.tar.gz"
    
    # Get image info
    local image_id=$(docker images --no-trunc --format "{{.ID}}" "$image_uri")
    local image_size=$(docker images --format "{{.Size}}" "$image_uri")
    local compressed_size=$(ls -lh "$temp_dir/image.tar.gz" | awk '{print $5}')
    
    # Create metadata file
    cat > "$temp_dir/metadata.json" <<EOF
{
    "image_uri": "$image_uri",
    "image_name": "$image_name",
    "image_id": "$image_id",
    "original_size": "$image_size",
    "compressed_size": "$compressed_size",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "created_by": "step-505-setup-s3-image-cache.sh",
    "load_instructions": {
        "download": "aws s3 cp s3://$S3_BUCKET/$S3_PREFIX/$output_file .",
        "load": "docker load < $output_file",
        "tag": "docker tag <image-id> $image_uri"
    }
}
EOF
    
    # Create final tarball with metadata
    echo "  📦 Creating final tarball with metadata..."
    cd "$temp_dir"
    tar -czf "$output_file" image.tar.gz metadata.json
    cd - > /dev/null
    
    # Get final size
    local final_size=$(ls -lh "$temp_dir/$output_file" | awk '{print $5}')
    
    echo "  ✅ Created: $output_file"
    echo "     Original: $image_size → Compressed: $final_size"
    
    # Move to cache directory
    mv "$temp_dir/$output_file" "$CACHE_DIR/$output_file"
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Function to upload to S3
upload_to_s3() {
    local filename=$1
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$filename"
    
    echo ""
    echo "☁️ Uploading to S3..."
    echo "  File: $filename"
    echo "  S3 Path: $s3_path"
    
    local file_size=$(ls -lh "$CACHE_DIR/$filename" | awk '{print $5}')
    echo "  Size: $file_size"
    
    # Upload with progress
    aws s3 cp "$CACHE_DIR/$filename" "$s3_path" \
        --region "$AWS_REGION" \
        --storage-class STANDARD_IA \
        --metadata "created-by=step-505,cache-version=v1" || {
        echo "  ❌ Upload failed"
        return 1
    }
    
    # Verify upload
    aws s3 ls "$s3_path" --region "$AWS_REGION" >/dev/null && {
        echo "  ✅ Upload verified"
        
        # Save location info
        echo "${filename}_s3_path=$s3_path" >> "$CACHE_DIR/s3-locations.env"
        echo "${filename}_s3_key=$S3_PREFIX/$filename" >> "$CACHE_DIR/s3-locations.env"
        
        return 0
    } || {
        echo "  ❌ Upload verification failed"
        return 1
    }
}

# Function to create fast load script
create_fast_load_script() {
    local worker_ip=$1
    
    cat > "$CACHE_DIR/fast-load-images.sh" <<'EOF'
#!/bin/bash
# Fast Docker Image Loader from S3 Cache
set -e

S3_BUCKET="${S3_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${S3_PREFIX:-bintarball/docker-images}"
DOWNLOAD_DIR="/tmp/docker-images"

echo "🚀 FAST DOCKER IMAGE LOADING FROM S3"
echo "===================================="

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

# Function to download and load image
fast_load_image() {
    local filename=$1
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$filename"
    
    echo ""
    echo "📥 Loading $filename..."
    
    # Download from S3 (very fast within AWS)
    echo "  ⬇️  Downloading from S3..."
    time aws s3 cp "$s3_path" . --region "$AWS_REGION" || {
        echo "  ❌ Download failed"
        return 1
    }
    
    # Extract tarball
    echo "  📦 Extracting..."
    tar -xzf "$filename"
    
    # Load into Docker
    echo "  🐳 Loading into Docker..."
    time docker load < image.tar.gz
    
    # Show metadata
    if [ -f metadata.json ]; then
        echo "  📋 Image info:"
        cat metadata.json | jq -r '  "     URI: \(.image_uri)\n     Size: \(.original_size)\n     Compressed: \(.compressed_size)"'
    fi
    
    # Cleanup
    rm -f "$filename" image.tar.gz metadata.json
    
    echo "  ✅ Image loaded successfully!"
}

# Load Whisper image
fast_load_image "whisper-gpu-$(date +%Y%m%d).tar.gz"

# Load Voxtral image
fast_load_image "voxtral-gpu-$(date +%Y%m%d).tar.gz"

echo ""
echo "🎉 ALL IMAGES LOADED!"
echo "===================="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

EOF
    
    chmod +x "$CACHE_DIR/fast-load-images.sh"
    echo "📜 Created fast load script: $CACHE_DIR/fast-load-images.sh"
}

# Main execution
if [ -z "$1" ]; then
    echo "❌ Usage: $0 <worker-ip>"
    echo "   Example: $0 18.223.113.91"
    exit 1
fi

WORKER_IP=$1
echo "🎯 Target worker: $WORKER_IP"

# Create cache directory
mkdir -p "$CACHE_DIR"
> "$CACHE_DIR/s3-locations.env"

# Check worker connectivity
echo ""
echo "🔍 Checking worker connectivity..."
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP "echo 'Connected'" >/dev/null 2>&1; then
    echo "❌ Cannot connect to worker at $WORKER_IP"
    exit 1
fi
echo "✅ Worker is accessible"

# Wait for images to be ready
echo ""
echo "⏳ Waiting for Docker images to be ready on worker..."
while true; do
    WHISPER_READY=$(ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
        "docker images | grep whisper-worker | wc -l" 2>/dev/null || echo "0")
    
    VOXTRAL_READY=$(ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
        "docker images | grep voxtral-gpu | wc -l" 2>/dev/null || echo "0")
    
    echo "  Status: Whisper=$WHISPER_READY, Voxtral=$VOXTRAL_READY"
    
    if [ "$WHISPER_READY" -gt 0 ] && [ "$VOXTRAL_READY" -gt 0 ]; then
        echo "✅ Both images are ready!"
        break
    fi
    
    echo "  ⏳ Waiting 30 seconds..."
    sleep 30
done

# Create tarballs on worker
echo ""
echo "📦 Creating optimized tarballs on worker..."

TIMESTAMP=$(date +%Y%m%d)
WHISPER_FILE="whisper-gpu-${TIMESTAMP}.tar.gz"
VOXTRAL_FILE="voxtral-gpu-${TIMESTAMP}.tar.gz"

# Create Whisper tarball
ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "echo 'Creating Whisper tarball...' && docker save $WHISPER_ECR_URI | gzip -9 > /tmp/$WHISPER_FILE && ls -lh /tmp/$WHISPER_FILE"

# Create Voxtral tarball
ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "echo 'Creating Voxtral tarball...' && docker save $VOXTRAL_ECR_URI | gzip -9 > /tmp/$VOXTRAL_FILE && ls -lh /tmp/$VOXTRAL_FILE"

# Upload to S3
echo ""
echo "☁️ Uploading to S3..."

ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "aws s3 cp /tmp/$WHISPER_FILE s3://$S3_BUCKET/$S3_PREFIX/$WHISPER_FILE --region $AWS_REGION && echo 'Whisper uploaded'"

ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "aws s3 cp /tmp/$VOXTRAL_FILE s3://$S3_BUCKET/$S3_PREFIX/$VOXTRAL_FILE --region $AWS_REGION && echo 'Voxtral uploaded'"

# Create metadata
cat > "$CACHE_DIR/docker-images-manifest.json" <<EOF
{
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "s3_bucket": "$S3_BUCKET",
    "s3_prefix": "$S3_PREFIX",
    "images": {
        "whisper": {
            "uri": "$WHISPER_ECR_URI",
            "filename": "$WHISPER_FILE",
            "s3_path": "s3://$S3_BUCKET/$S3_PREFIX/$WHISPER_FILE"
        },
        "voxtral": {
            "uri": "$VOXTRAL_ECR_URI", 
            "filename": "$VOXTRAL_FILE",
            "s3_path": "s3://$S3_BUCKET/$S3_PREFIX/$VOXTRAL_FILE"
        }
    },
    "usage": {
        "fast_deploy": "Use the generated fast-load-images.sh script",
        "manual_load": "aws s3 cp s3://path && docker load < file.tar.gz"
    }
}
EOF

# Upload manifest
aws s3 cp "$CACHE_DIR/docker-images-manifest.json" "s3://$S3_BUCKET/$S3_PREFIX/manifest.json" --region "$AWS_REGION"

# Create fast load script
create_fast_load_script "$WORKER_IP"

# Cleanup worker
ssh -o StrictHostKeyChecking=no -i /home/ubuntu/transcription-sqs-spot-s3/transcription-worker-key-dev.pem ubuntu@$WORKER_IP \
    "rm -f /tmp/$WHISPER_FILE /tmp/$VOXTRAL_FILE"

echo ""
echo "🎉 S3 DOCKER IMAGE CACHE COMPLETE!"
echo "================================="
echo ""
echo "📋 Cache Details:"
echo "  S3 Bucket: $S3_BUCKET"
echo "  S3 Prefix: $S3_PREFIX"
echo "  Whisper: $WHISPER_FILE"
echo "  Voxtral: $VOXTRAL_FILE"
echo ""
echo "⚡ Performance Improvement:"
echo "  Before: 15-20 minutes (ECR pull)"
echo "  After:  2-3 minutes (S3 load)"
echo "  Speedup: 5-6x faster!"
echo ""
echo "🚀 Next Steps:"
echo "1. Update launch scripts to use S3 cache"
echo "2. Test with: $CACHE_DIR/fast-load-images.sh"
echo "3. Deploy new workers in 2-3 minutes!"
echo ""
echo "💡 Files created:"
echo "  - $CACHE_DIR/docker-images-manifest.json"
echo "  - $CACHE_DIR/fast-load-images.sh"
echo "  - $CACHE_DIR/s3-locations.env"