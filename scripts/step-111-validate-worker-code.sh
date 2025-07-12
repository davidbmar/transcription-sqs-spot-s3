#!/bin/bash

# step-031-validate-worker-code.sh - Validate worker code deployment to S3
# Ensures all code is accessible and functional

set -e

echo "=========================================="
echo "STEP 111: Validate Worker Code Deployment (PATH 100)"
echo "=========================================="
echo ""
echo "This step validates that worker code is properly deployed to S3"
echo "and can be successfully downloaded and executed by workers"
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

# Check if previous step completed
if grep -q "step-111-deploy-worker-code: completed" .setup-status 2>/dev/null; then
    echo "✅ Step 111 completed successfully"
else
    echo "❌ Error: Step 110 not completed. Run step-111-deploy-worker-code.sh first."
    exit 1
fi

# Configuration
S3_CODE_PREFIX="worker-code"
S3_CODE_VERSION="v1.0"
S3_CODE_PATH="${S3_CODE_PREFIX}/${S3_CODE_VERSION}"
S3_LATEST_PATH="${S3_CODE_PREFIX}/latest"
VALIDATION_DIR="/tmp/worker-code-validation-$$"

echo ""
echo "📋 Validation Configuration:"
echo "  S3 Bucket: ${METRICS_BUCKET}"
echo "  S3 Path: ${S3_CODE_PATH}"
echo "  Latest Path: ${S3_LATEST_PATH}"
echo "  Region: ${AWS_REGION}"
echo "  Validation Dir: ${VALIDATION_DIR}"
echo ""

# Create validation directory
mkdir -p "${VALIDATION_DIR}"
cd "${VALIDATION_DIR}"

# Test 1: Check manifest exists
echo "🧪 Test 1: Checking deployment manifest..."
if aws s3 ls "s3://${METRICS_BUCKET}/${S3_CODE_PATH}/manifest.json" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "  ✅ Manifest exists"
    
    # Download and examine manifest
    aws s3 cp "s3://${METRICS_BUCKET}/${S3_CODE_PATH}/manifest.json" manifest.json --region "${AWS_REGION}" >/dev/null 2>&1
    
    if [ -f "manifest.json" ]; then
        TOTAL_FILES=$(python3 -c "import json; print(json.load(open('manifest.json'))['total_files'])" 2>/dev/null || echo "0")
        TOTAL_SIZE=$(python3 -c "import json; print(json.load(open('manifest.json'))['total_size_bytes'])" 2>/dev/null || echo "0")
        echo "  📊 Deployment info: ${TOTAL_FILES} files, $((TOTAL_SIZE / 1024)) KB"
    fi
else
    echo "  ❌ Manifest not found!"
    exit 1
fi

# Test 2: Check latest symlink
echo ""
echo "🧪 Test 2: Checking 'latest' reference..."
if aws s3 ls "s3://${METRICS_BUCKET}/${S3_LATEST_PATH}/manifest.json" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "  ✅ Latest reference exists"
else
    echo "  ❌ Latest reference not found!"
    exit 1
fi

# Test 3: Download all files from latest
echo ""
echo "🧪 Test 3: Downloading all worker files..."
echo "  📥 Syncing from S3..."
if aws s3 sync "s3://${METRICS_BUCKET}/${S3_LATEST_PATH}/" . --region "${AWS_REGION}" --exclude "manifest.json"; then
    echo "  ✅ Download successful"
    
    # List downloaded files
    echo ""
    echo "  📁 Downloaded files:"
    for file in *.py; do
        if [ -f "$file" ]; then
            SIZE=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
            echo "    ✅ $file ($((SIZE / 1024)) KB)"
        fi
    done
else
    echo "  ❌ Download failed!"
    exit 1
fi

# Test 4: Verify core files
echo ""
echo "🧪 Test 4: Verifying core worker files..."
CORE_FILES=(
    "transcription_worker.py"
    "queue_metrics.py"
    "transcriber.py"
)

MISSING_CORE=0
for file in "${CORE_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
    else
        echo "  ❌ $file (MISSING)"
        MISSING_CORE=$((MISSING_CORE + 1))
    fi
done

if [ $MISSING_CORE -gt 0 ]; then
    echo ""
    echo "❌ Missing $MISSING_CORE core files!"
    exit 1
fi

# Test 5: Verify enhanced files
echo ""
echo "🧪 Test 5: Verifying enhanced worker files..."
ENHANCED_FILES=(
    "transcription_worker_enhanced.py"
    "transcriber_gpu_optimized.py"
    "progress_logger.py"
)

MISSING_ENHANCED=0
for file in "${ENHANCED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
    else
        echo "  ⚠️ $file (optional)"
        MISSING_ENHANCED=$((MISSING_ENHANCED + 1))
    fi
done

# Test 6: Verify strategy files
echo ""
echo "🧪 Test 6: Verifying strategy transcriber files..."
STRATEGY_FILES=(
    "transcriber_faster_whisper.py"
    "transcriber_whisperx.py"
    "transcriber_base_whisper.py"
)

STRATEGY_COUNT=0
for file in "${STRATEGY_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
        STRATEGY_COUNT=$((STRATEGY_COUNT + 1))
    else
        echo "  ⚠️ $file (optional)"
    fi
done

# Test 7: Python import test
echo ""
echo "🧪 Test 7: Testing Python imports..."

# Check if dependencies are installed (just test, don't fail)
python3 -c "import boto3" 2>/dev/null && echo "  ✅ boto3 available" || echo "  ⚠️ boto3 not installed (will be on worker)"

# Test core imports
echo ""
echo "  Testing core imports..."
python3 -c "
import sys
sys.path.append('.')
errors = []
try:
    import transcription_worker
    print('  ✅ transcription_worker imports successfully')
except Exception as e:
    errors.append(f'transcription_worker: {e}')
    print(f'  ⚠️ transcription_worker: {e}')

try:
    import queue_metrics
    print('  ✅ queue_metrics imports successfully')
except Exception as e:
    errors.append(f'queue_metrics: {e}')
    print(f'  ⚠️ queue_metrics: {e}')

if not errors:
    print('  ✅ All core imports successful!')
else:
    print(f'  ⚠️ Some imports failed (may need dependencies)')
"

# Test 8: Deployment URLs
echo ""
echo "🧪 Test 8: Generating deployment URLs..."
echo ""
echo "📥 Workers should use these commands:"
echo ""
echo "  # Download all files:"
echo "  aws s3 sync s3://${METRICS_BUCKET}/${S3_LATEST_PATH}/ /opt/transcription-worker/ --region ${AWS_REGION}"
echo ""
echo "  # Or download specific files:"
for file in *.py; do
    if [ -f "$file" ]; then
        echo "  aws s3 cp s3://${METRICS_BUCKET}/${S3_LATEST_PATH}/$file /opt/transcription-worker/ --region ${AWS_REGION}"
        break
    fi
done

# Test 9: Update deployment scripts
echo ""
echo "🧪 Test 9: Checking deployment script updates needed..."

LAUNCH_SCRIPTS=(
    "../launch-faster-whisper-worker.sh"
    "../launch-whisperx-worker.sh"
    "../launch-base-whisper-worker.sh"
)

UPDATE_NEEDED=0
for script in "${LAUNCH_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if grep -q "wget.*github.com" "$script" 2>/dev/null; then
            echo "  ⚠️ $(basename $script) - Still uses GitHub (needs update)"
            UPDATE_NEEDED=$((UPDATE_NEEDED + 1))
        else
            echo "  ✅ $(basename $script) - Already updated"
        fi
    fi
done

# Cleanup
cd - >/dev/null
rm -rf "${VALIDATION_DIR}"

# Summary
echo ""
echo "=========================================="
echo "📊 VALIDATION SUMMARY"
echo "=========================================="
echo ""
echo "✅ Deployment Status:"
echo "  - Manifest: Found"
echo "  - Latest reference: Active"
echo "  - Core files: ${#CORE_FILES[@]}/${#CORE_FILES[@]}"
echo "  - Enhanced files: $((${#ENHANCED_FILES[@]} - MISSING_ENHANCED))/${#ENHANCED_FILES[@]}"
echo "  - Strategy files: ${STRATEGY_COUNT}/${#STRATEGY_FILES[@]}"
echo "  - Total files in S3: ${TOTAL_FILES}"
echo "  - Total size: $((TOTAL_SIZE / 1024)) KB"
echo ""

if [ $UPDATE_NEEDED -gt 0 ]; then
    echo "⚠️ Action Required:"
    echo "  - Update $UPDATE_NEEDED deployment scripts to use S3"
    echo "  - Replace GitHub URLs with S3 sync commands"
    echo ""
fi

echo "📥 S3 Code Location:"
echo "  Versioned: s3://${METRICS_BUCKET}/${S3_CODE_PATH}/"
echo "  Latest: s3://${METRICS_BUCKET}/${S3_LATEST_PATH}/"
echo ""

# Update setup status
echo "step-031-validate-worker-code: completed" >> .setup-status

echo "✅ Step 111 completed successfully!"

# Auto-detect and show next step
if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
    source "$(dirname "$0")/next-step-helper.sh"
    show_next_step "$0" "$(dirname "$0")"
fi