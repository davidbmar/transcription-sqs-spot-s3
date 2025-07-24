#!/bin/bash

# Test script for Fast API with S3 support

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Load configuration
source .env

echo -e "${GREEN}Testing Fast API S3 Integration${NC}"
echo "================================"

# Get API endpoint from user or use default
if [ -z "$1" ]; then
    echo "Usage: $0 <API_ENDPOINT>"
    echo "Example: $0 http://3.22.235.17:8000"
    exit 1
fi

API_ENDPOINT="$1"

# Test 1: Health check
echo -e "\n${YELLOW}Test 1: Health Check${NC}"
curl -s "$API_ENDPOINT/health" | jq .

# Test 2: S3 to S3 transcription
echo -e "\n${YELLOW}Test 2: S3 Input to S3 Output${NC}"
echo "Using test file: s3://$AUDIO_BUCKET/test_30sec.mp3"

# Create request payload
REQUEST_PAYLOAD=$(cat <<EOF
{
    "s3_input_path": "s3://$AUDIO_BUCKET/test_30sec.mp3",
    "s3_output_path": "s3://$AUDIO_BUCKET/transcripts/fast-api-test-$(date +%s).json",
    "return_text": true
}
EOF
)

echo "Request payload:"
echo "$REQUEST_PAYLOAD" | jq .

echo -e "\n${GREEN}Sending transcription request...${NC}"
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$REQUEST_PAYLOAD" \
    "$API_ENDPOINT/transcribe-s3")

echo -e "\n${GREEN}Response:${NC}"
echo "$RESPONSE" | jq .

# Extract output path
OUTPUT_PATH=$(echo "$RESPONSE" | jq -r '.s3_output_path')
if [ "$OUTPUT_PATH" != "null" ]; then
    echo -e "\n${GREEN}Transcript saved to: $OUTPUT_PATH${NC}"
    
    # Verify file exists in S3
    BUCKET=$(echo "$OUTPUT_PATH" | sed 's|s3://||' | cut -d'/' -f1)
    KEY=$(echo "$OUTPUT_PATH" | sed 's|s3://||' | cut -d'/' -f2-)
    
    if aws s3 ls "s3://$BUCKET/$KEY" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Output file verified in S3${NC}"
        
        # Download and show content
        echo -e "\n${YELLOW}Downloaded transcript content:${NC}"
        aws s3 cp "$OUTPUT_PATH" - | jq .
    else
        echo -e "${RED}✗ Output file not found in S3${NC}"
    fi
fi

# Test 3: File upload (existing functionality)
echo -e "\n${YELLOW}Test 3: File Upload (existing functionality)${NC}"
if [ -f "/home/ubuntu/transcription-sqs-spot-s3/test-audio/test_30sec.mp3" ]; then
    curl -s -X POST \
        -F "file=@/home/ubuntu/transcription-sqs-spot-s3/test-audio/test_30sec.mp3" \
        "$API_ENDPOINT/transcribe" | jq .
else
    echo "Test audio file not found locally"
fi

echo -e "\n${GREEN}Testing complete!${NC}"