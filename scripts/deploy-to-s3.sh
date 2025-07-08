#!/bin/bash

# deploy-to-s3.sh - Deploy worker code to S3 for reliable access

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found."
    exit 1
fi

echo "🚀 DEPLOYING WORKER CODE TO S3"
echo "================================"

# S3 deployment path
S3_CODE_PREFIX="worker-code/latest"
S3_CODE_BUCKET="${METRICS_BUCKET}"

# Files to deploy
declare -a WORKER_FILES=(
    "src/transcription_worker.py"
    "src/transcription_worker_enhanced.py"
    "src/queue_metrics.py"
    "src/transcriber.py"
    "src/transcriber_gpu_optimized.py"
    "src/transcriber_faster_whisper.py"
    "src/transcriber_whisperx.py"
    "src/transcriber_base_whisper.py"
    "src/progress_logger.py"
)

echo "📦 Uploading worker files to S3..."
echo "Destination: s3://${S3_CODE_BUCKET}/${S3_CODE_PREFIX}/"
echo ""

# Upload each file
for file in "${WORKER_FILES[@]}"; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        echo "📤 Uploading $file..."
        aws s3 cp "$file" "s3://${S3_CODE_BUCKET}/${S3_CODE_PREFIX}/${filename}" \
            --region "${AWS_REGION}" || echo "⚠️ Failed to upload $file"
    else
        echo "❌ File not found: $file"
    fi
done

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📥 Workers can now download from:"
echo "   aws s3 cp s3://${S3_CODE_BUCKET}/${S3_CODE_PREFIX}/file.py ."
echo ""
echo "🔍 To verify deployment:"
echo "   aws s3 ls s3://${S3_CODE_BUCKET}/${S3_CODE_PREFIX}/"