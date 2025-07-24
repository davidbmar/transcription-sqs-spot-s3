#!/bin/bash

# step-330-fast-api-test-voice-transcription.sh - Test Fast API voice transcription

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🎤 Test Fast API Voice Transcription${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Find Fast API instances
echo -e "${GREEN}[STEP 1]${NC} Finding Fast API instances..."
FAST_API_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
    --output json)

if [ "$FAST_API_INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Fast API instances found"
    exit 1
fi

INSTANCE_ID=$(echo "$FAST_API_INSTANCES" | jq -r '.[0][0][0]')
PUBLIC_IP=$(echo "$FAST_API_INSTANCES" | jq -r '.[0][0][1]')

echo -e "${GREEN}[OK]${NC} Found instance: $INSTANCE_ID ($PUBLIC_IP)"

# Test API health first
echo -e "${GREEN}[STEP 2]${NC} Testing API health..."
if curl -f -s --max-time 5 "http://$PUBLIC_IP:8000/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ API is healthy${NC}"
    curl -s "http://$PUBLIC_IP:8000/health" | jq .
else
    echo -e "${RED}✗ API health check failed${NC}"
    exit 1
fi

# Create a test audio file (simple WAV tone)
echo -e "${GREEN}[STEP 3]${NC} Creating test audio file..."
if command -v ffmpeg >/dev/null 2>&1; then
    # Create a 3-second sine wave at 440Hz
    ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 -ac 1 /tmp/test_audio.wav -y >/dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Created test audio file: /tmp/test_audio.wav"
else
    echo -e "${YELLOW}[WARNING]${NC} ffmpeg not available, creating placeholder file"
    # Create a minimal WAV header (won't actually work for transcription)
    echo "RIFF....WAVEfmt ............data...." > /tmp/test_audio.wav
fi

# Test transcription endpoint
echo -e "${GREEN}[STEP 4]${NC} Testing transcription endpoint..."
echo "Endpoint: http://$PUBLIC_IP:8000/transcribe"

echo -e "${YELLOW}[INFO]${NC} Sending POST request with audio file..."
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -X POST \
    -F "file=@/tmp/test_audio.wav" \
    "http://$PUBLIC_IP:8000/transcribe" 2>/dev/null)

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')

echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ Transcription request successful${NC}"
    echo -e "${BLUE}Response:${NC}"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
elif [ "$HTTP_STATUS" = "422" ]; then
    echo -e "${YELLOW}⚠ Invalid file format (expected for test tone)${NC}"
    echo -e "${BLUE}Response:${NC}"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
else
    echo -e "${RED}✗ Transcription request failed${NC}"
    echo -e "${BLUE}Response:${NC}"
    echo "$RESPONSE_BODY"
fi

# Test with curl command examples
echo -e "${GREEN}[STEP 5]${NC} API Usage Examples..."
echo
echo -e "${YELLOW}[CURL EXAMPLES - 3 Endpoints Available]${NC}"
echo "1. S3 to S3 transcription (s3:// URIs):"
echo "   curl -X POST http://$PUBLIC_IP:8000/transcribe-s3 \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"s3_input_path\": \"s3://bucket/audio.mp3\", \"s3_output_path\": \"s3://bucket/transcript.json\"}'"
echo
echo "2. URL transcription (http/https URLs):"
echo "   curl -X POST http://$PUBLIC_IP:8000/transcribe-url \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"audio_url\": \"https://example.com/audio.mp3\"}'"
echo
echo "3. File upload (original functionality):"
echo "   curl -X POST -F 'file=@your_audio.mp3' http://$PUBLIC_IP:8000/transcribe"
echo
echo "4. Health check (shows s3_enabled: true):"
echo "   curl http://$PUBLIC_IP:8000/health"
echo
echo "5. API documentation:"
echo "   Open http://$PUBLIC_IP:8000/docs in your browser"

# Test API docs endpoint
echo -e "${GREEN}[STEP 6]${NC} Testing API documentation..."
if curl -f -s --max-time 5 "http://$PUBLIC_IP:8000/docs" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ API docs available at: http://$PUBLIC_IP:8000/docs${NC}"
else
    echo -e "${YELLOW}⚠ API docs not accessible${NC}"
fi

# Cleanup
rm -f /tmp/test_audio.wav

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API Test Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[API ENDPOINTS - S3-Enhanced Version]${NC}"
echo "Health:           http://$PUBLIC_IP:8000/health"
echo "Main:             http://$PUBLIC_IP:8000/"
echo "S3 Transcription: POST http://$PUBLIC_IP:8000/transcribe-s3"
echo "URL Transcription:POST http://$PUBLIC_IP:8000/transcribe-url"
echo "File Upload:      POST http://$PUBLIC_IP:8000/transcribe"
echo "Documentation:    http://$PUBLIC_IP:8000/docs"
echo
echo -e "${YELLOW}[ENDPOINT USAGE]${NC}"
echo "• /transcribe-s3:  Use with s3:// URIs for input/output"
echo "• /transcribe-url: Use with http:// or https:// URLs"
echo "• /transcribe:     Use with file uploads (multipart/form-data)"
echo "• Health endpoint: Returns s3_enabled: true for enhanced version"