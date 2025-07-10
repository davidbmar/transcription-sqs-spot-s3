#!/bin/bash
set -e

echo "============================================"
echo "🚀 Step 211: Push Docker Image to ECR"
echo "============================================"
echo ""

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check if previous steps completed
if ! grep -q "step-210-completed" .setup-status 2>/dev/null; then
    echo "❌ Error: step-210-build-worker-image.sh must be run first."
    exit 1
fi

echo "📦 Pushing Docker image to Amazon ECR..."
echo ""

# Check if image exists locally
if ! docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "${ECR_REPOSITORY_URI}:latest"; then
    echo "❌ Error: Docker image not found locally. Run step-210-build-worker-image.sh first."
    exit 1
fi

# Get image information
IMAGE_ID=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep "${ECR_REPOSITORY_URI}:latest" | awk '{print $2}')
IMAGE_SIZE=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep "${ECR_REPOSITORY_URI}:latest" | awk '{print $2}')

echo "📊 Image Information:"
echo "  • Repository: $ECR_REPOSITORY_URI"
echo "  • Tag: latest"
echo "  • Image ID: $IMAGE_ID"
echo "  • Size: $IMAGE_SIZE"
echo ""

# Authenticate with ECR
echo "🔐 Authenticating with ECR..."
if aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI"; then
    echo "✅ ECR authentication successful"
else
    echo "❌ ECR authentication failed"
    exit 1
fi

# Push the image
echo ""
echo "⬆️  Pushing image to ECR (this may take several minutes)..."
echo "   Target: $ECR_REPOSITORY_URI:latest"
echo ""

# Track push progress
push_start_time=$(date +%s)

if docker push "$ECR_REPOSITORY_URI:latest"; then
    push_end_time=$(date +%s)
    push_duration=$((push_end_time - push_start_time))
    
    echo ""
    echo "✅ Image pushed successfully!"
    echo "   Duration: ${push_duration}s"
    echo "   Repository: $ECR_REPOSITORY_URI"
    echo "   Tag: latest"
    
    # Also push with timestamp tag
    TIMESTAMP_TAG="${ECR_REPOSITORY_URI}:$(date +%Y%m%d-%H%M%S)"
    echo ""
    echo "🏷️  Creating timestamped tag: $TIMESTAMP_TAG"
    docker tag "$ECR_REPOSITORY_URI:latest" "$TIMESTAMP_TAG"
    
    if docker push "$TIMESTAMP_TAG"; then
        echo "✅ Timestamped tag pushed successfully!"
    else
        echo "⚠️  Timestamped tag push failed (latest tag pushed successfully)"
    fi
    
else
    echo "❌ Image push failed!"
    exit 1
fi

# Verify the push
echo ""
echo "✅ Verifying push..."
if aws ecr describe-images --repository-name "$(echo "$ECR_REPOSITORY_URI" | cut -d'/' -f2)" --image-ids imageTag=latest --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "✅ Image verified in ECR repository"
    
    # Get image details from ECR
    ECR_IMAGE_INFO=$(aws ecr describe-images \
        --repository-name "$(echo "$ECR_REPOSITORY_URI" | cut -d'/' -f2)" \
        --image-ids imageTag=latest \
        --region "$AWS_REGION" \
        --query 'imageDetails[0]' \
        --output json)
    
    PUSH_DATE=$(echo "$ECR_IMAGE_INFO" | jq -r '.imagePushedAt')
    IMAGE_SIZE_MB=$(echo "$ECR_IMAGE_INFO" | jq -r '.imageSizeInBytes / 1024 / 1024 | floor')
    
    echo "📊 ECR Image Details:"
    echo "  • Pushed: $PUSH_DATE"
    echo "  • Size: ${IMAGE_SIZE_MB}MB"
    echo "  • Repository: $ECR_REPOSITORY_URI"
    
else
    echo "❌ Image verification failed"
    exit 1
fi

# Create deployment script
echo ""
echo "📄 Creating deployment script..."
cat > docker/worker/deploy.sh << EOF
#!/bin/bash
set -e

# Quick deployment script for Docker worker
echo "🚀 Deploying Docker worker from ECR..."

# Load configuration
if [ -f "../../.env" ]; then
    source "../../.env"
fi

# Pull latest image
docker pull "$ECR_REPOSITORY_URI:latest"

# Run container with required environment variables
docker run -d \\
    --name whisper-worker-\$(date +%s) \\
    --gpus all \\
    --restart unless-stopped \\
    -e AWS_REGION="\$AWS_REGION" \\
    -e QUEUE_URL="\$QUEUE_URL" \\
    -e AWS_ACCESS_KEY_ID="\$AWS_ACCESS_KEY_ID" \\
    -e AWS_SECRET_ACCESS_KEY="\$AWS_SECRET_ACCESS_KEY" \\
    -e AUDIO_BUCKET="\$AUDIO_BUCKET" \\
    -e TRANSCRIPT_BUCKET="\$TRANSCRIPT_BUCKET" \\
    -p 8080:8080 \\
    "$ECR_REPOSITORY_URI:latest"

echo "✅ Docker worker deployed!"
echo "   Health check: http://localhost:8080/health"
EOF

chmod +x docker/worker/deploy.sh
echo "✅ Created docker/worker/deploy.sh"

# Clean up old local images (keep last 3)
echo ""
echo "🧹 Cleaning up old local images..."
OLD_IMAGES=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep "$ECR_REPOSITORY_URI" | tail -n +4 | awk '{print $2}')
if [ -n "$OLD_IMAGES" ]; then
    echo "$OLD_IMAGES" | xargs docker rmi -f 2>/dev/null || true
    echo "✅ Old images cleaned up"
else
    echo "ℹ️  No old images to clean up"
fi

# Update status
echo ""
echo "📊 Push Summary:"
echo "  • Repository: $ECR_REPOSITORY_URI"
echo "  • Tag: latest"
echo "  • Push Duration: ${push_duration}s"
echo "  • Registry Size: ${IMAGE_SIZE_MB}MB"
echo ""
echo "📋 Next steps:"
echo "  1. Run: ./scripts/step-220-launch-docker-worker.sh"
echo "  2. Or manually: docker run --gpus all $ECR_REPOSITORY_URI:latest"
echo ""

# Update setup status
echo "step-211-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
echo "docker-image-pushed=true" >> .setup-status
echo "ecr-image-uri=$ECR_REPOSITORY_URI:latest" >> .setup-status

# Create success summary
cat > docker/ECR_PUSH_SUMMARY.md << EOF
# ECR Push Summary

## Image Details
- **Repository**: $ECR_REPOSITORY_URI
- **Tag**: latest
- **Size**: ${IMAGE_SIZE_MB}MB
- **Pushed**: $PUSH_DATE

## Quick Commands
\`\`\`bash
# Pull image
docker pull $ECR_REPOSITORY_URI:latest

# Run locally
docker run --gpus all -p 8080:8080 $ECR_REPOSITORY_URI:latest

# Deploy on EC2
./docker/worker/deploy.sh
\`\`\`

## Next Steps
1. Launch GPU-enabled EC2 instance
2. Run: \`./scripts/step-220-launch-docker-worker.sh\`
3. Monitor: \`./scripts/step-225-check-docker-health.sh\`

Generated: $(date)
EOF

echo "📄 Created docker/ECR_PUSH_SUMMARY.md"