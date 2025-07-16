#!/bin/bash

# step-005-setup-vad-model.sh - Download VAD model from HuggingFace and upload to S3

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
echo -e "${BLUE}Setup VAD Model for WhisperX${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${CYAN}This step downloads the Voice Activity Detection (VAD) model"
echo -e "from HuggingFace and uploads it to S3 for reliable access.${NC}"
echo
echo -e "${YELLOW}Prerequisites:${NC}"
echo "1. HuggingFace account with access to pyannote/segmentation model"
echo "2. HuggingFace CLI installed and authenticated"
echo "3. AWS CLI configured with S3 access"
echo
echo -e "${YELLOW}The VAD model is required for:${NC}"
echo "- Automatic speech activity detection in audio files"
echo "- Improved transcription accuracy by filtering silence"
echo "- Speaker diarization capabilities"
echo

# Check if VAD model already exists in S3 first
echo -e "${GREEN}[STEP 1]${NC} Checking if VAD model already exists in S3..."
if aws s3 ls s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} VAD model already exists in S3"
    
    # Get S3 file info
    S3_INFO=$(aws s3 ls s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin)
    echo "S3 file info: $S3_INFO"
    
    echo
    echo -e "${YELLOW}VAD model is already available. Do you want to re-download and update it? (y/N)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}[SKIP]${NC} Using existing VAD model"
        echo "step-005-completed=$(date)" >> .setup-status
        
        echo
        echo -e "${BLUE}======================================${NC}"
        echo -e "${GREEN}✅ VAD Model Already Available${NC}"
        echo -e "${BLUE}======================================${NC}"
        echo
        echo -e "${GREEN}[SUMMARY]${NC}"
        echo "VAD model location: s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin"
        echo "Model source: pyannote/segmentation (HuggingFace)"
        echo "Purpose: Voice Activity Detection for WhisperX transcription"
        echo
        echo -e "${CYAN}The VAD model is ready for Docker deployments.${NC}"
        echo
        echo -e "${GREEN}[NEXT STEP]${NC}"
        echo "Continue with: ./scripts/step-010-setup-iam-permissions.sh"
        exit 0
    fi
fi

# Check if HuggingFace CLI is installed
if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} Installing HuggingFace CLI..."
    python3 -m pip install huggingface-hub
fi

# Check if logged in to HuggingFace
echo -e "${GREEN}[STEP 2]${NC} Checking HuggingFace authentication..."
if huggingface-cli whoami >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} HuggingFace authentication verified"
    huggingface-cli whoami
else
    echo -e "${RED}[ERROR]${NC} Not authenticated with HuggingFace"
    echo
    echo "Please authenticate with HuggingFace:"
    echo "1. Get your token from: https://huggingface.co/settings/tokens"
    echo "2. Run: huggingface-cli login"
    echo "3. Accept terms at: https://huggingface.co/pyannote/segmentation"
    echo
    echo "Then run this script again."
    exit 1
fi

echo -e "${GREEN}[STEP 3]${NC} Checking S3 bucket access..."
if aws s3 ls s3://dbm-cf-2-web/bintarball/ >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} S3 bucket access verified"
else
    echo -e "${RED}[ERROR]${NC} Cannot access S3 bucket s3://dbm-cf-2-web/bintarball/"
    echo "Please check your AWS credentials and permissions."
    exit 1
fi

echo -e "${GREEN}[STEP 4]${NC} Downloading VAD model from HuggingFace..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Downloading pyannote/segmentation model..."
echo "This may take a few minutes (17MB download)..."

# Download the model
python3 -c "
from huggingface_hub import hf_hub_download
import sys

try:
    path = hf_hub_download(
        repo_id='pyannote/segmentation', 
        filename='pytorch_model.bin',
        cache_dir='$TEMP_DIR'
    )
    print(f'Downloaded to: {path}')
    
    # Find the actual file
    import os
    import glob
    
    pattern = '$TEMP_DIR/models--pyannote--segmentation/snapshots/*/pytorch_model.bin'
    files = glob.glob(pattern)
    
    if files:
        src_file = files[0]
        dst_file = '$TEMP_DIR/whisperx-vad-segmentation.bin'
        
        # Copy to expected filename
        import shutil
        shutil.copy2(src_file, dst_file)
        print(f'Model ready at: {dst_file}')
        
        # Check file size
        size = os.path.getsize(dst_file)
        print(f'File size: {size/1024/1024:.1f} MB')
        
        if size < 10000000:
            print('ERROR: File seems too small')
            sys.exit(1)
    else:
        print('ERROR: Downloaded file not found')
        sys.exit(1)
        
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
"

# Check if download succeeded
if [ ! -f "$TEMP_DIR/whisperx-vad-segmentation.bin" ]; then
    echo -e "${RED}[ERROR]${NC} VAD model download failed"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} VAD model downloaded successfully"

echo -e "${GREEN}[STEP 5]${NC} Uploading VAD model to S3..."

# Upload to S3
aws s3 cp "$TEMP_DIR/whisperx-vad-segmentation.bin" s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin

# Verify upload
if aws s3 ls s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} VAD model uploaded to S3 successfully"
else
    echo -e "${RED}[ERROR]${NC} VAD model upload failed"
    exit 1
fi

echo -e "${GREEN}[STEP 6]${NC} Verifying S3 model..."

# Get S3 file info
S3_INFO=$(aws s3 ls s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin)
echo "S3 file info: $S3_INFO"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ VAD Model Setup Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[SUMMARY]${NC}"
echo "VAD model location: s3://dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin"
echo "Model source: pyannote/segmentation (HuggingFace)"
echo "Purpose: Voice Activity Detection for WhisperX transcription"
echo
echo -e "${CYAN}The VAD model is now ready for Docker deployments.${NC}"
echo -e "${CYAN}All future builds will download this model automatically.${NC}"

# Update status tracking
echo "step-005-completed=$(date)" >> .setup-status

echo
echo -e "${GREEN}[NEXT STEP]${NC}"
echo "Continue with: ./scripts/step-010-setup-iam-permissions.sh"