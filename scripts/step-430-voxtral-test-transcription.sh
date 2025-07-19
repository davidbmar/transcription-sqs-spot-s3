#!/bin/bash

# step-430-voxtral-test-transcription.sh - Test Real Voxtral transcription

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
echo -e "${BLUE}🎤 Test Real Voxtral Transcription${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Find Real Voxtral instances
echo -e "${GREEN}[STEP 1]${NC} Finding Real Voxtral instances..."
REAL_VOXTRAL_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
    --output json)

if [ "$REAL_VOXTRAL_INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Real Voxtral instances found"
    echo "Launch instances first: ./scripts/step-420-voxtral-launch-gpu-instances.sh"
    exit 1
fi

INSTANCE_ID=$(echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[0][0][0]')
PUBLIC_IP=$(echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[0][0][1]')

echo -e "${GREEN}[OK]${NC} Found instance: $INSTANCE_ID ($PUBLIC_IP)"

# Test API health first
echo -e "${GREEN}[STEP 2]${NC} Testing API health..."
if curl -f -s --max-time 10 "http://$PUBLIC_IP:8000/" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Main API is accessible${NC}"
    
    # Get API info
    API_INFO=$(curl -s "http://$PUBLIC_IP:8000/" | jq . 2>/dev/null || echo '{}')
    MODEL=$(echo "$API_INFO" | jq -r '.model // "unknown"')
    STATUS=$(echo "$API_INFO" | jq -r '.status // "unknown"')
    
    echo "  Model: $MODEL"
    echo "  Status: $STATUS"
    
    if [ "$STATUS" != "ready" ]; then
        echo -e "${YELLOW}[WARNING]${NC} Model status is '$STATUS' - may still be loading"
        echo "Real Voxtral model takes 5-10 minutes to load initially"
    fi
else
    echo -e "${RED}✗ Main API not accessible${NC}"
    exit 1
fi

# Check health endpoint
if curl -f -s --max-time 5 "http://$PUBLIC_IP:8080/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Health endpoint is accessible${NC}"
    
    HEALTH_INFO=$(curl -s "http://$PUBLIC_IP:8080/health" | jq . 2>/dev/null || echo '{}')
    HEALTH_STATUS=$(echo "$HEALTH_INFO" | jq -r '.status // "unknown"')
    MODEL_LOADED=$(echo "$HEALTH_INFO" | jq -r '.model_loaded // false')
    
    echo "  Health: $HEALTH_STATUS"
    echo "  Model loaded: $MODEL_LOADED"
    
    if [ "$MODEL_LOADED" != "true" ]; then
        echo -e "${YELLOW}[WARNING]${NC} Model not yet loaded - wait a few minutes"
    fi
else
    echo -e "${RED}✗ Health endpoint not accessible${NC}"
    exit 1
fi

# Create test audio files
echo -e "${GREEN}[STEP 3]${NC} Creating test audio files..."

# Create a simple spoken text file (if we have text-to-speech)
TEST_AUDIO_DIR="/tmp/voxtral-test"
mkdir -p "$TEST_AUDIO_DIR"

echo -e "${CYAN}Creating test audio files...${NC}"

# Test 1: Simple sine wave (for basic API testing)
if command -v ffmpeg >/dev/null 2>&1; then
    echo "  1. Creating sine wave test (3 seconds)..."
    ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 -ac 1 "$TEST_AUDIO_DIR/sine_test.wav" -y >/dev/null 2>&1
    echo "    ✓ sine_test.wav created"
    
    # Test 2: White noise (more realistic for transcription testing)
    echo "  2. Creating white noise test (2 seconds)..."
    ffmpeg -f lavfi -i "anoisesrc=duration=2:color=white:sample_rate=16000:amplitude=0.1" "$TEST_AUDIO_DIR/noise_test.wav" -y >/dev/null 2>&1
    echo "    ✓ noise_test.wav created"
else
    echo -e "${YELLOW}[WARNING]${NC} ffmpeg not available, creating minimal WAV files"
    
    # Create minimal WAV header for testing (won't transcribe properly)
    echo "RIFF....WAVEfmt ............data...." > "$TEST_AUDIO_DIR/minimal_test.wav"
    echo "    ✓ minimal_test.wav created (placeholder)"
fi

# Test transcription with different files
echo -e "${GREEN}[STEP 4]${NC} Testing Real Voxtral transcription..."

TEST_FILES=()
if [ -f "$TEST_AUDIO_DIR/sine_test.wav" ]; then
    TEST_FILES+=("$TEST_AUDIO_DIR/sine_test.wav")
fi
if [ -f "$TEST_AUDIO_DIR/noise_test.wav" ]; then
    TEST_FILES+=("$TEST_AUDIO_DIR/noise_test.wav")
fi
if [ -f "$TEST_AUDIO_DIR/minimal_test.wav" ]; then
    TEST_FILES+=("$TEST_AUDIO_DIR/minimal_test.wav")
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo -e "${RED}[ERROR]${NC} No test files created"
    exit 1
fi

for TEST_FILE in "${TEST_FILES[@]}"; do
    FILE_NAME=$(basename "$TEST_FILE")
    echo
    echo -e "${CYAN}Testing with: $FILE_NAME${NC}"
    
    echo -n "  Uploading and transcribing... "
    START_TIME=$(date +%s)
    
    # Make the transcription request
    RESPONSE=$(curl -s -w "\\nHTTP_STATUS:%{http_code}" \
        -X POST \
        -F "file=@$TEST_FILE" \
        "http://$PUBLIC_IP:8000/transcribe" 2>/dev/null)
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')
    
    echo "($DURATION seconds)"
    echo "  HTTP Status: $HTTP_STATUS"
    
    if [ "$HTTP_STATUS" = "200" ]; then
        echo -e "  ${GREEN}✓ Transcription successful${NC}"
        
        # Parse response
        TRANSCRIPTION=$(echo "$RESPONSE_BODY" | jq -r '.text // "N/A"' 2>/dev/null)
        PROCESSING_TIME=$(echo "$RESPONSE_BODY" | jq -r '.processing_time // "N/A"' 2>/dev/null)
        REAL_TIME_FACTOR=$(echo "$RESPONSE_BODY" | jq -r '.real_time_factor // "N/A"' 2>/dev/null)
        AUDIO_DURATION=$(echo "$RESPONSE_BODY" | jq -r '.audio_duration // "N/A"' 2>/dev/null)
        
        echo "  Transcription: \"$TRANSCRIPTION\""
        echo "  Processing time: ${PROCESSING_TIME}s"
        echo "  Audio duration: ${AUDIO_DURATION}s"
        echo "  Real-time factor: ${REAL_TIME_FACTOR}x"
        
        # Show full response for debugging
        echo -e "${BLUE}  Full response:${NC}"
        echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
        
    elif [ "$HTTP_STATUS" = "503" ]; then
        echo -e "  ${RED}✗ Service unavailable${NC}"
        echo "  Model may not be loaded yet. Wait 5-10 minutes and try again."
        echo "  Response: $RESPONSE_BODY"
        
    elif [ "$HTTP_STATUS" = "422" ]; then
        echo -e "  ${YELLOW}⚠ Invalid audio format${NC}"
        echo "  This is expected for test files that aren't real speech"
        echo "  Response: $RESPONSE_BODY"
        
    else
        echo -e "  ${RED}✗ Request failed${NC}"
        echo "  Response: $RESPONSE_BODY"
    fi
done

# Test batch endpoint if available
echo
echo -e "${GREEN}[STEP 5]${NC} Testing batch transcription..."

if curl -f -s --max-time 5 "http://$PUBLIC_IP:8000/docs" >/dev/null 2>&1; then
    echo "  API documentation available at: http://$PUBLIC_IP:8000/docs"
    echo "  Check if /transcribe-batch endpoint is available for multiple files"
else
    echo "  API documentation not accessible"
fi

# Provide usage examples
echo
echo -e "${GREEN}[STEP 6]${NC} Usage examples..."

echo -e "${YELLOW}[CURL EXAMPLES]${NC}"
echo "1. Test with your own audio file:"
echo "   curl -X POST -F 'file=@your_audio.mp3' http://$PUBLIC_IP:8000/transcribe"
echo
echo "2. Test from local machine:"
echo "   curl -X POST -F 'file=@/path/to/audio.wav' http://$PUBLIC_IP:8000/transcribe | jq ."
echo
echo "3. Health check:"
echo "   curl http://$PUBLIC_IP:8080/health | jq ."
echo
echo "4. API info:"
echo "   curl http://$PUBLIC_IP:8000/ | jq ."

# Performance comparison note
echo
echo -e "${YELLOW}[PERFORMANCE NOTES]${NC}"
echo "- Real Voxtral model takes 5-10 minutes to load initially"
echo "- Subsequent requests are much faster"
echo "- Performance depends on audio length and GPU utilization"
echo "- Expected: 2-5x real-time speed for typical audio"

# Cleanup
echo
echo -e "${GREEN}[CLEANUP]${NC}"
rm -rf "$TEST_AUDIO_DIR"
echo "Test files cleaned up"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral Test Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[TEST SUMMARY]${NC}"
echo "Instance: $INSTANCE_ID"
echo "API endpoint: http://$PUBLIC_IP:8000"
echo "Health endpoint: http://$PUBLIC_IP:8080/health"
echo "Model: $VOXTRAL_MODEL_ID"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Test with real audio files using the curl examples above"
echo "2. Compare performance with Whisper:"
echo "   ./scripts/step-435-voxtral-benchmark-vs-whisper.sh"
echo
echo "3. Monitor usage and costs"
echo
echo -e "${YELLOW}[REAL AUDIO TESTING]${NC}"
echo "To test with real speech audio:"
echo "1. Upload an MP3/WAV file to your machine"
echo "2. Use: curl -X POST -F 'file=@audio.mp3' http://$PUBLIC_IP:8000/transcribe"
echo "3. Compare results with other transcription services"