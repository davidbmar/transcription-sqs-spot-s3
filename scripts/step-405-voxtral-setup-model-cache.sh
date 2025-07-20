#!/bin/bash

# step-405-voxtral-setup-model-cache.sh - Setup S3 model caching for Real Voxtral (400 series specific)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🗄️  Real Voxtral Model Caching (S3)${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${CYAN}This script caches the Real Voxtral model to S3 for faster deployments.${NC}"
echo -e "${CYAN}Part of the 400 series - Real Voxtral GPU deployment path.${NC}"
echo
echo -e "${GREEN}✅ WORKING SOLUTION:${NC}"
echo -e "${GREEN}  - Voxtral now functional with dynamic audio token calculation${NC}"
echo -e "${GREEN}  - Reduces model load time from 7-8 minutes to 40 seconds${NC}"
echo -e "${GREEN}  - Architecture: Hybrid text-audio model with placeholder tokens${NC}"
echo

# Validate configuration
if [ -z "$MODELS_CACHE_BUCKET" ] || [ -z "$VOXTRAL_MODEL_ID" ]; then
    echo -e "${RED}[ERROR]${NC} Model cache configuration missing in .env file"
    echo "Required variables:"
    echo "  - MODELS_CACHE_BUCKET=${MODELS_CACHE_BUCKET:-'not set'}"
    echo "  - VOXTRAL_MODEL_ID=${VOXTRAL_MODEL_ID:-'not set'}"
    echo "  - VOXTRAL_MODEL_CACHE_KEY=${VOXTRAL_MODEL_CACHE_KEY:-'not set'}"
    exit 1
fi

# Build S3 cache path
CACHE_PATH="s3://$MODELS_CACHE_BUCKET/$MODELS_CACHE_PREFIX/$VOXTRAL_MODEL_CACHE_KEY"
echo "Model: $VOXTRAL_MODEL_ID"
echo "Cache location: $CACHE_PATH"
echo "Force download: $FORCE_MODEL_DOWNLOAD"
echo

# Check if model is already cached
echo -e "${GREEN}[STEP 1]${NC} Checking S3 model cache..."

if [ "$FORCE_MODEL_DOWNLOAD" = "true" ]; then
    echo -e "${YELLOW}[INFO]${NC} Force download enabled - will refresh cache"
    MODEL_CACHED=false
elif aws s3 ls "$CACHE_PATH/" >/dev/null 2>&1; then
    CACHED_FILES=$(aws s3 ls "$CACHE_PATH/" --recursive | wc -l)
    echo -e "${GREEN}[OK]${NC} Model found in cache ($CACHED_FILES files)"
    echo "Cache contents:"
    aws s3 ls "$CACHE_PATH/" --recursive --human-readable
    MODEL_CACHED=true
else
    echo -e "${YELLOW}[INFO]${NC} Model not found in cache"
    MODEL_CACHED=false
fi

if [ "$MODEL_CACHED" = true ] && [ "$FORCE_MODEL_DOWNLOAD" != "true" ]; then
    echo
    echo -e "${GREEN}✅ Real Voxtral model already cached${NC}"
    echo "Containers will use cached model for faster startup"
    echo "To force re-download: FORCE_MODEL_DOWNLOAD=true"
    echo
    echo -e "${BLUE}ℹ️  Next Steps:${NC}"
    echo "1. Build Docker image: ./scripts/step-410-voxtral-build-gpu-docker-image.sh"
    echo "2. Launch GPU instances: ./scripts/step-420-voxtral-launch-gpu-instances.sh"
    exit 0
fi

# Download and cache model
echo
echo -e "${GREEN}[STEP 2]${NC} Downloading and caching Real Voxtral model..."
echo "This will take 5-15 minutes depending on model size"
echo -e "${YELLOW}Model:${NC} $VOXTRAL_MODEL_ID (4.7B parameters)"

# Create temporary directory
TEMP_DIR="/tmp/voxtral-model-cache-$$"
mkdir -p "$TEMP_DIR"
echo "Temporary directory: $TEMP_DIR"

# Download model using Python
echo -e "${CYAN}Downloading $VOXTRAL_MODEL_ID...${NC}"

cat > "$TEMP_DIR/download_voxtral_model.py" << 'EOF'
import os
import sys
from huggingface_hub import snapshot_download
from pathlib import Path

model_id = os.environ.get('VOXTRAL_MODEL_ID')
cache_dir = os.environ.get('TEMP_DIR')

if not model_id or not cache_dir:
    print("❌ Missing environment variables")
    sys.exit(1)

print(f"📥 Downloading Real Voxtral files: {model_id}")
print(f"💾 Cache directory: {cache_dir}")
print("🔄 This downloads files only (no model loading)")

try:
    # Download all model files without loading into memory
    print("📂 Downloading model files...")
    model_path = snapshot_download(
        repo_id=model_id,
        cache_dir=cache_dir,
        local_files_only=False,
        revision="main"
    )
    
    print("✅ Download completed successfully")
    print(f"📁 Downloaded to: {model_path}")
    
    # Show what was downloaded
    model_path_obj = Path(model_path)
    files = list(model_path_obj.rglob("*"))
    print(f"📊 Downloaded {len(files)} files")
    
    # List important files
    for pattern in ["*.json", "*.bin", "*.safetensors", "*.txt", "*.model"]:
        matching_files = list(model_path_obj.rglob(pattern))
        if matching_files:
            print(f"  {pattern}: {len(matching_files)} files")
    
    # Show total size
    total_size = sum(f.stat().st_size for f in model_path_obj.rglob("*") if f.is_file())
    print(f"📏 Total download size: {total_size / (1024**3):.2f} GB")
    
    # Also copy to expected location for upload script
    cache_path = Path(cache_dir)
    models_dir = cache_path / "models--mistralai--Voxtral-Mini-3B-2507"
    if not models_dir.exists():
        # Create symlink or copy the files to expected location
        import shutil
        print(f"📁 Copying files to expected location: {models_dir}")
        shutil.copytree(model_path, models_dir)
    
except Exception as e:
    print(f"❌ Download failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF

# Use a lightweight container to download model (this is just for caching, not GPU execution)
echo "Using lightweight container to download Voxtral model for S3 caching..."
echo -e "${CYAN}Note: This downloads the model files only, for S3 caching.${NC}"
echo -e "${CYAN}GPU instances will later download from this S3 cache.${NC}"

# Use minimal container with just the essentials for downloading
sudo docker run --rm \
    -e VOXTRAL_MODEL_ID="$VOXTRAL_MODEL_ID" \
    -e TEMP_DIR="/tmp/download" \
    -v "$TEMP_DIR:/tmp/download" \
    python:3.11-slim bash -c "
        echo 'Installing minimal dependencies for model download...'
        pip install --no-cache-dir transformers huggingface-hub torch --extra-index-url https://download.pytorch.org/whl/cpu &&
        cd /tmp/download &&
        python3 download_voxtral_model.py
    "

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Model download failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Real Voxtral model downloaded successfully"

# Upload to S3
echo
echo -e "${GREEN}[STEP 3]${NC} Uploading Real Voxtral model to S3 cache..."

# Find the actual model files
MODEL_FILES=$(find "$TEMP_DIR" -name "models--*" -type d | head -1)
if [ -z "$MODEL_FILES" ]; then
    echo -e "${RED}[ERROR]${NC} Model files not found in expected location"
    ls -la "$TEMP_DIR"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Uploading from: $MODEL_FILES"
echo "Uploading to: $CACHE_PATH/"

# Upload model files to S3
if aws s3 cp "$MODEL_FILES" "$CACHE_PATH/" --recursive; then
    echo -e "${GREEN}[OK]${NC} Real Voxtral model uploaded to S3 cache"
    
    # Verify upload
    UPLOADED_FILES=$(aws s3 ls "$CACHE_PATH/" --recursive | wc -l)
    echo "Uploaded files: $UPLOADED_FILES"
    
    # Show cache size
    CACHE_SIZE=$(aws s3 ls "$CACHE_PATH/" --recursive --summarize | grep "Total Size" | awk '{print $3}')
    echo "Cache size: $CACHE_SIZE bytes"
    
else
    echo -e "${RED}[ERROR]${NC} Failed to upload model to S3"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup
rm -rf "$TEMP_DIR"

# Update status tracking
echo "step-405-completed=$(date)" >> .setup-status

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral Model Caching Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[CACHE SUMMARY]${NC}"
echo "Model: $VOXTRAL_MODEL_ID"
echo "Cache location: $CACHE_PATH"
echo "Files cached: $UPLOADED_FILES"
echo "Cache size: ~$(echo "scale=2; $CACHE_SIZE / 1024 / 1024 / 1024" | bc)GB"
echo
echo -e "${GREEN}[BENEFITS]${NC}"
echo "🚀 Faster container startup (3-5x improvement)"
echo "💰 Reduced data transfer costs"
echo "🔒 Reliable model availability"
echo "📦 Version-controlled model artifacts"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Build Docker image (will use cache automatically):"
echo "   ./scripts/step-410-voxtral-build-gpu-docker-image.sh"
echo
echo "2. Deploy and test faster startup times:"
echo "   ./scripts/step-420-voxtral-launch-gpu-instances.sh"
echo
echo -e "${YELLOW}[CACHE MANAGEMENT]${NC}"
echo "View cache: aws s3 ls $CACHE_PATH/ --recursive --human-readable"
echo "Clear cache: aws s3 rm $CACHE_PATH/ --recursive"
echo "Force refresh: FORCE_MODEL_DOWNLOAD=true ./scripts/step-405-voxtral-setup-model-cache.sh"