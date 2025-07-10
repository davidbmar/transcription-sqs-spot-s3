#!/bin/bash

# step-030-deploy-worker-code.sh - Deploy worker code to S3 for reliable access
# This eliminates external GitHub dependencies and ensures code availability

set -e

echo "=========================================="
echo "STEP 040: Deploy Worker Code to S3"
echo "=========================================="
echo ""
echo "This step uploads all worker code to S3 for reliable deployment"
echo "Workers will download code from S3 instead of GitHub"
echo ""

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check prerequisites
echo "🔍 Checking prerequisites..."

# Check if metrics bucket exists
if aws s3 ls "s3://${METRICS_BUCKET}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "✅ Metrics bucket exists: ${METRICS_BUCKET}"
else
    echo "❌ Error: Metrics bucket not found. Run step-020-create-sqs-resources.sh first."
    exit 1
fi

# Define S3 deployment configuration
S3_CODE_PREFIX="worker-code"
S3_CODE_VERSION="v1.0"
S3_CODE_PATH="${S3_CODE_PREFIX}/${S3_CODE_VERSION}"

# Core worker files that must exist
declare -a CORE_FILES=(
    "src/transcription_worker.py"
    "src/queue_metrics.py"
    "src/transcriber.py"
)

# Enhanced worker files (optional but recommended)
declare -a ENHANCED_FILES=(
    "src/transcription_worker_enhanced.py"
    "src/transcriber_gpu_optimized.py"
    "src/progress_logger.py"
)

# Strategy-specific transcribers (optional)
declare -a STRATEGY_FILES=(
    "src/transcriber_faster_whisper.py"
    "src/transcriber_whisperx.py"
    "src/transcriber_base_whisper.py"
)

echo ""
echo "📋 Deployment Configuration:"
echo "  S3 Bucket: ${METRICS_BUCKET}"
echo "  S3 Path: ${S3_CODE_PATH}"
echo "  Region: ${AWS_REGION}"
echo ""

# Check core files exist
echo "🔍 Checking core worker files..."
MISSING_CORE=0
for file in "${CORE_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
    else
        echo "  ❌ $file (MISSING - REQUIRED)"
        MISSING_CORE=$((MISSING_CORE + 1))
    fi
done

if [ $MISSING_CORE -gt 0 ]; then
    echo ""
    echo "❌ Error: Missing $MISSING_CORE core files. Cannot proceed."
    exit 1
fi

# Check enhanced files
echo ""
echo "🔍 Checking enhanced worker files..."
ENHANCED_COUNT=0
for file in "${ENHANCED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
        ENHANCED_COUNT=$((ENHANCED_COUNT + 1))
    else
        echo "  ⚠️ $file (optional)"
    fi
done

# Check strategy files
echo ""
echo "🔍 Checking strategy transcriber files..."
STRATEGY_COUNT=0
for file in "${STRATEGY_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
        STRATEGY_COUNT=$((STRATEGY_COUNT + 1))
    else
        echo "  ⚠️ $file (optional)"
    fi
done

echo ""
echo "📊 File Summary:"
echo "  Core files: ${#CORE_FILES[@]}/${#CORE_FILES[@]} ✅"
echo "  Enhanced files: $ENHANCED_COUNT/${#ENHANCED_FILES[@]}"
echo "  Strategy files: $STRATEGY_COUNT/${#STRATEGY_FILES[@]}"
echo ""

# Create deployment manifest
MANIFEST_FILE="/tmp/deployment-manifest.json"
echo "📝 Creating deployment manifest..."

cat > "$MANIFEST_FILE" << EOF
{
  "deployment_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployment_version": "${S3_CODE_VERSION}",
  "deployment_bucket": "${METRICS_BUCKET}",
  "deployment_path": "${S3_CODE_PATH}",
  "files": {
EOF

# Start deployment
echo ""
echo "🚀 Starting deployment to S3..."
echo ""

FIRST_FILE=true
UPLOAD_COUNT=0
UPLOAD_SIZE=0

# Upload all files and build manifest
for category in "CORE_FILES" "ENHANCED_FILES" "STRATEGY_FILES"; do
    declare -n files=$category
    
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            filesize=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
            
            # Add comma if not first file
            if [ "$FIRST_FILE" = false ]; then
                echo "," >> "$MANIFEST_FILE"
            fi
            FIRST_FILE=false
            
            # Add file info to manifest
            cat >> "$MANIFEST_FILE" << EOF
    "$filename": {
      "source_path": "$file",
      "s3_key": "${S3_CODE_PATH}/${filename}",
      "size_bytes": $filesize,
      "category": "${category,,}"
    }
EOF
            
            # Upload file
            echo "📤 Uploading $file..."
            if aws s3 cp "$file" "s3://${METRICS_BUCKET}/${S3_CODE_PATH}/${filename}" \
                --region "${AWS_REGION}"; then
                echo "  ✅ Uploaded successfully"
                UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                UPLOAD_SIZE=$((UPLOAD_SIZE + filesize))
            else
                echo "  ❌ Upload failed!"
            fi
        fi
    done
done

# Complete manifest
cat >> "$MANIFEST_FILE" << EOF

  },
  "total_files": $UPLOAD_COUNT,
  "total_size_bytes": $UPLOAD_SIZE
}
EOF

# Upload manifest
echo ""
echo "📤 Uploading deployment manifest..."
aws s3 cp "$MANIFEST_FILE" "s3://${METRICS_BUCKET}/${S3_CODE_PATH}/manifest.json" \
    --region "${AWS_REGION}"

# Create latest symlink
echo ""
echo "🔗 Creating 'latest' reference..."
aws s3 cp "$MANIFEST_FILE" "s3://${METRICS_BUCKET}/${S3_CODE_PREFIX}/latest/manifest.json" \
    --region "${AWS_REGION}"

# Sync all files to latest
aws s3 sync "s3://${METRICS_BUCKET}/${S3_CODE_PATH}/" \
    "s3://${METRICS_BUCKET}/${S3_CODE_PREFIX}/latest/" \
    --region "${AWS_REGION}" \
    --exclude "manifest.json"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Deployment Summary:"
echo "  Files uploaded: $UPLOAD_COUNT"
echo "  Total size: $((UPLOAD_SIZE / 1024)) KB"
echo "  S3 location: s3://${METRICS_BUCKET}/${S3_CODE_PATH}/"
echo "  Latest link: s3://${METRICS_BUCKET}/${S3_CODE_PREFIX}/latest/"
echo ""
echo "📥 Workers can download code using:"
echo "  aws s3 sync s3://${METRICS_BUCKET}/${S3_CODE_PREFIX}/latest/ /opt/transcription-worker/"
echo ""

# Update setup status
echo "step-030-deploy-worker-code: completed" >> .setup-status

echo "✅ Step 030 completed successfully!"

# Auto-detect and show next step
if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
    source "$(dirname "$0")/next-step-helper.sh"
    show_next_step "$0" "$(dirname "$0")"
fi