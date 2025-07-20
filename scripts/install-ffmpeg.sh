#!/bin/bash

# install-ffmpeg.sh - Install ffmpeg for audio testing

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🎵 Install FFmpeg for Audio Testing${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Check if ffmpeg is already installed
if command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} FFmpeg is already installed"
    ffmpeg -version | head -1
    exit 0
fi

echo -e "${YELLOW}[INFO]${NC} FFmpeg not found. Installing..."

# Update package list
echo -e "${GREEN}[STEP 1]${NC} Updating package list..."
sudo apt-get update -y

# Install ffmpeg
echo -e "${GREEN}[STEP 2]${NC} Installing FFmpeg..."
sudo apt-get install -y ffmpeg

# Verify installation
echo -e "${GREEN}[STEP 3]${NC} Verifying installation..."
if command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} FFmpeg installed successfully"
    ffmpeg -version | head -1
else
    echo -e "${RED}[ERROR]${NC} FFmpeg installation failed"
    exit 1
fi

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ FFmpeg Installation Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[USAGE]${NC}"
echo "You can now create test audio files:"
echo "  ffmpeg -f lavfi -i \"sine=frequency=440:duration=3\" -ar 16000 -ac 1 test.wav"
echo
echo "Run Real Voxtral tests:"
echo "  ./scripts/step-430-voxtral-test-transcription.sh"