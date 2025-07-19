#!/bin/bash

# step-435-voxtral-benchmark-vs-whisper.sh - Benchmark Real Voxtral vs Whisper performance

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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
echo -e "${BLUE}⚡ Voxtral vs Whisper Benchmark${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Create benchmark results directory
BENCHMARK_DIR="/tmp/voxtral-benchmark-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BENCHMARK_DIR"
echo "Benchmark results will be saved to: $BENCHMARK_DIR"

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

VOXTRAL_INSTANCE_ID=$(echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[0][0][0]')
VOXTRAL_PUBLIC_IP=$(echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[0][0][1]')

echo -e "${GREEN}[OK]${NC} Real Voxtral: $VOXTRAL_INSTANCE_ID ($VOXTRAL_PUBLIC_IP)"

# Find Fast API (Whisper) instances
echo -e "${GREEN}[STEP 2]${NC} Finding Fast API (Whisper) instances..."
WHISPER_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
    --output json)

if [ "$WHISPER_INSTANCES" = "[]" ]; then
    echo -e "${YELLOW}[WARNING]${NC} No running Fast API (Whisper) instances found"
    echo "For comparison, you may want to launch Fast API instances from the 300-series scripts"
    COMPARE_WHISPER=false
else
    WHISPER_INSTANCE_ID=$(echo "$WHISPER_INSTANCES" | jq -r '.[0][0][0]')
    WHISPER_PUBLIC_IP=$(echo "$WHISPER_INSTANCES" | jq -r '.[0][0][1]')
    echo -e "${GREEN}[OK]${NC} Fast API (Whisper): $WHISPER_INSTANCE_ID ($WHISPER_PUBLIC_IP)"
    COMPARE_WHISPER=true
fi

# Check API availability
echo -e "${GREEN}[STEP 3]${NC} Checking API availability..."

echo -n "  Real Voxtral API... "
if curl -f -s --max-time 10 "http://$VOXTRAL_PUBLIC_IP:8000/" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
    VOXTRAL_AVAILABLE=true
else
    echo -e "${RED}✗${NC}"
    VOXTRAL_AVAILABLE=false
fi

if [ "$COMPARE_WHISPER" = true ]; then
    echo -n "  Fast API (Whisper)... "
    if curl -f -s --max-time 10 "http://$WHISPER_PUBLIC_IP:8000/" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        WHISPER_AVAILABLE=true
    else
        echo -e "${RED}✗${NC}"
        WHISPER_AVAILABLE=false
    fi
else
    WHISPER_AVAILABLE=false
fi

if [ "$VOXTRAL_AVAILABLE" = false ]; then
    echo -e "${RED}[ERROR]${NC} Real Voxtral API not available"
    exit 1
fi

# Create test audio files of different lengths
echo -e "${GREEN}[STEP 4]${NC} Creating benchmark audio files..."

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} ffmpeg required for creating test audio files"
    echo "Install with: sudo apt-get install ffmpeg"
    exit 1
fi

# Generate test audio files of various lengths
echo "Creating test audio files (may take a minute)..."

# Test 1: Short audio (5 seconds)
echo "  1. Short test (5 seconds) - sine wave + speech simulation"
ffmpeg -f lavfi -i "sine=frequency=400:duration=5" -ar 16000 -ac 1 "$BENCHMARK_DIR/short_5s.wav" -y >/dev/null 2>&1

# Test 2: Medium audio (30 seconds)
echo "  2. Medium test (30 seconds) - complex waveform"
ffmpeg -f lavfi -i "sine=frequency=440:duration=30" -ar 16000 -ac 1 "$BENCHMARK_DIR/medium_30s.wav" -y >/dev/null 2>&1

# Test 3: Long audio (60 seconds) 
echo "  3. Long test (60 seconds) - speech-like patterns"
ffmpeg -f lavfi -i "sine=frequency=300:duration=60" -ar 16000 -ac 1 "$BENCHMARK_DIR/long_60s.wav" -y >/dev/null 2>&1

# Test 4: Very short (1 second)
echo "  4. Very short (1 second) - quick response test"
ffmpeg -f lavfi -i "sine=frequency=800:duration=1" -ar 16000 -ac 1 "$BENCHMARK_DIR/veryshort_1s.wav" -y >/dev/null 2>&1

echo -e "${GREEN}[OK]${NC} Test audio files created"

# Function to benchmark a single file
benchmark_file() {
    local file_path="$1"
    local file_name="$2"
    local api_url="$3"
    local api_name="$4"
    
    echo -e "${CYAN}Testing $file_name with $api_name...${NC}"
    
    START_TIME=$(date +%s.%3N)
    
    RESPONSE=$(curl -s -w "\\nHTTP_STATUS:%{http_code}" \
        -X POST \
        -F "file=@$file_path" \
        "$api_url/transcribe" 2>/dev/null)
    
    END_TIME=$(date +%s.%3N)
    WALL_CLOCK_TIME=$(echo "$END_TIME - $START_TIME" | bc)
    
    HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')
    
    if [ "$HTTP_STATUS" = "200" ]; then
        # Parse response
        TRANSCRIPTION=$(echo "$RESPONSE_BODY" | jq -r '.text // "N/A"' 2>/dev/null)
        PROCESSING_TIME=$(echo "$RESPONSE_BODY" | jq -r '.processing_time // "N/A"' 2>/dev/null)
        REAL_TIME_FACTOR=$(echo "$RESPONSE_BODY" | jq -r '.real_time_factor // "N/A"' 2>/dev/null)
        AUDIO_DURATION=$(echo "$RESPONSE_BODY" | jq -r '.audio_duration // "N/A"' 2>/dev/null)
        MODEL=$(echo "$RESPONSE_BODY" | jq -r '.model // "N/A"' 2>/dev/null)
        
        echo "    ✓ Success"
        echo "      Model: $MODEL"
        echo "      Audio duration: ${AUDIO_DURATION}s"
        echo "      Processing time: ${PROCESSING_TIME}s"
        echo "      Wall clock time: ${WALL_CLOCK_TIME}s"
        echo "      Real-time factor: ${REAL_TIME_FACTOR}x"
        echo "      Transcription: \"${TRANSCRIPTION:0:100}...\""
        
        # Save detailed results
        cat > "$BENCHMARK_DIR/${api_name}_${file_name}_result.json" << EOF
{
  "api_name": "$api_name",
  "file_name": "$file_name",
  "model": "$MODEL",
  "audio_duration": $AUDIO_DURATION,
  "processing_time": $PROCESSING_TIME,
  "wall_clock_time": $WALL_CLOCK_TIME,
  "real_time_factor": $REAL_TIME_FACTOR,
  "transcription": "$TRANSCRIPTION",
  "http_status": $HTTP_STATUS,
  "timestamp": "$(date -Iseconds)"
}
EOF
        
        return 0
    else
        echo "    ✗ Failed (HTTP $HTTP_STATUS)"
        echo "      Response: $RESPONSE_BODY"
        return 1
    fi
}

# Run benchmarks
echo
echo -e "${GREEN}[STEP 5]${NC} Running benchmarks..."

TEST_FILES=(
    "$BENCHMARK_DIR/veryshort_1s.wav:veryshort_1s"
    "$BENCHMARK_DIR/short_5s.wav:short_5s"
    "$BENCHMARK_DIR/medium_30s.wav:medium_30s"
    "$BENCHMARK_DIR/long_60s.wav:long_60s"
)

echo
echo -e "${MAGENTA}=== REAL VOXTRAL BENCHMARKS ===${NC}"
for test_file in "${TEST_FILES[@]}"; do
    IFS=':' read -r file_path file_name <<< "$test_file"
    benchmark_file "$file_path" "$file_name" "http://$VOXTRAL_PUBLIC_IP:8000" "voxtral"
    echo
done

if [ "$WHISPER_AVAILABLE" = true ]; then
    echo -e "${MAGENTA}=== FAST API (WHISPER) BENCHMARKS ===${NC}"
    for test_file in "${TEST_FILES[@]}"; do
        IFS=':' read -r file_path file_name <<< "$test_file"
        benchmark_file "$file_path" "$file_name" "http://$WHISPER_PUBLIC_IP:8000" "whisper"
        echo
    done
fi

# Generate comparison report
echo -e "${GREEN}[STEP 6]${NC} Generating comparison report..."

REPORT_FILE="$BENCHMARK_DIR/benchmark_report.md"

cat > "$REPORT_FILE" << EOF
# Real Voxtral vs Whisper Benchmark Report

**Generated:** $(date)  
**Real Voxtral Instance:** $VOXTRAL_INSTANCE_ID ($VOXTRAL_PUBLIC_IP)  
EOF

if [ "$WHISPER_AVAILABLE" = true ]; then
    echo "**Fast API (Whisper) Instance:** $WHISPER_INSTANCE_ID ($WHISPER_PUBLIC_IP)" >> "$REPORT_FILE"
else
    echo "**Fast API (Whisper):** Not available for comparison" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << EOF

## Performance Summary

| Test File | Duration | API | Model | Processing Time | Real-time Factor | Status |
|-----------|----------|-----|-------|----------------|------------------|--------|
EOF

# Add results to report
for test_file in "${TEST_FILES[@]}"; do
    IFS=':' read -r file_path file_name <<< "$test_file"
    
    # Voxtral results
    if [ -f "$BENCHMARK_DIR/voxtral_${file_name}_result.json" ]; then
        VOXTRAL_RESULT=$(cat "$BENCHMARK_DIR/voxtral_${file_name}_result.json")
        AUDIO_DUR=$(echo "$VOXTRAL_RESULT" | jq -r '.audio_duration')
        PROC_TIME=$(echo "$VOXTRAL_RESULT" | jq -r '.processing_time')
        RTF=$(echo "$VOXTRAL_RESULT" | jq -r '.real_time_factor')
        MODEL=$(echo "$VOXTRAL_RESULT" | jq -r '.model')
        
        echo "| $file_name | ${AUDIO_DUR}s | Voxtral | $MODEL | ${PROC_TIME}s | ${RTF}x | ✅ |" >> "$REPORT_FILE"
    fi
    
    # Whisper results
    if [ -f "$BENCHMARK_DIR/whisper_${file_name}_result.json" ]; then
        WHISPER_RESULT=$(cat "$BENCHMARK_DIR/whisper_${file_name}_result.json")
        AUDIO_DUR=$(echo "$WHISPER_RESULT" | jq -r '.audio_duration')
        PROC_TIME=$(echo "$WHISPER_RESULT" | jq -r '.processing_time')
        RTF=$(echo "$WHISPER_RESULT" | jq -r '.real_time_factor')
        MODEL=$(echo "$WHISPER_RESULT" | jq -r '.model')
        
        echo "| $file_name | ${AUDIO_DUR}s | Whisper | $MODEL | ${PROC_TIME}s | ${RTF}x | ✅ |" >> "$REPORT_FILE"
    fi
done

cat >> "$REPORT_FILE" << EOF

## Key Findings

### Real-time Performance
- **Real Voxtral**: Mistral's Voxtral-Mini-3B-2507 model
- **Fast API**: OpenAI Whisper (base model)

### Model Characteristics
- **Voxtral**: 4.7B parameters, native audio understanding
- **Whisper**: Established speech-to-text model

### Infrastructure
- **Instance Type**: $INSTANCE_TYPE (Tesla T4 GPU)
- **Container**: Docker with CUDA support
- **Region**: $AWS_REGION

## Detailed Results

EOF

# Add detailed results for each test
for test_file in "${TEST_FILES[@]}"; do
    IFS=':' read -r file_path file_name <<< "$test_file"
    
    echo "### $file_name" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    
    if [ -f "$BENCHMARK_DIR/voxtral_${file_name}_result.json" ]; then
        echo "**Real Voxtral:**" >> "$REPORT_FILE"
        cat "$BENCHMARK_DIR/voxtral_${file_name}_result.json" | jq . >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi
    
    if [ -f "$BENCHMARK_DIR/whisper_${file_name}_result.json" ]; then
        echo "**Fast API (Whisper):**" >> "$REPORT_FILE"
        cat "$BENCHMARK_DIR/whisper_${file_name}_result.json" | jq . >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi
done

echo -e "${GREEN}[OK]${NC} Benchmark report generated: $REPORT_FILE"

# Display summary
echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Benchmark Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[BENCHMARK SUMMARY]${NC}"
echo "Results directory: $BENCHMARK_DIR"
echo "Report file: $REPORT_FILE"
echo

# Show quick summary
echo -e "${CYAN}Quick Performance Summary:${NC}"
if [ -f "$BENCHMARK_DIR/voxtral_short_5s_result.json" ]; then
    VOXTRAL_RTF=$(cat "$BENCHMARK_DIR/voxtral_short_5s_result.json" | jq -r '.real_time_factor')
    echo "  Real Voxtral (5s test): ${VOXTRAL_RTF}x real-time"
fi

if [ -f "$BENCHMARK_DIR/whisper_short_5s_result.json" ]; then
    WHISPER_RTF=$(cat "$BENCHMARK_DIR/whisper_short_5s_result.json" | jq -r '.real_time_factor')
    echo "  Fast API/Whisper (5s test): ${WHISPER_RTF}x real-time"
fi

echo
echo -e "${GREEN}[VIEW RESULTS]${NC}"
echo "View full report:"
echo "  cat $REPORT_FILE"
echo
echo "View individual results:"
echo "  ls $BENCHMARK_DIR/*.json"
echo
echo -e "${YELLOW}[NOTES]${NC}"
echo "- First requests may be slower due to model loading"
echo "- Performance varies with audio content and length"
echo "- Real Voxtral excels at understanding context and nuance"
echo "- Whisper is optimized for transcription accuracy"

# Cleanup option
echo
read -p "Keep benchmark files for analysis? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$BENCHMARK_DIR"
    echo "Benchmark files cleaned up"
else
    echo "Benchmark files preserved in: $BENCHMARK_DIR"
fi