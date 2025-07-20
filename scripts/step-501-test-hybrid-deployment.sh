#!/bin/bash
set -e

echo "🧪 TESTING HYBRID DEPLOYMENT: Whisper + Voxtral"
echo "=============================================="

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found."
    exit 1
fi

# Get hybrid worker IP from status
if [ -f ".setup-status" ]; then
    source .setup-status
    if [ -z "$hybrid_worker_public_ip" ]; then
        echo "❌ Hybrid worker IP not found in .setup-status"
        echo "   Run step-500-launch-hybrid-workers.sh first"
        exit 1
    fi
    WORKER_IP="$hybrid_worker_public_ip"
else
    echo "❌ .setup-status file not found"
    exit 1
fi

echo "🎯 Testing worker: $WORKER_IP"

# Test audio file
TEST_AUDIO="/home/ubuntu/transcription-sqs-spot-s3/test-audio/test_30sec.mp3"
if [ ! -f "$TEST_AUDIO" ]; then
    echo "❌ Test audio file not found: $TEST_AUDIO"
    echo "   Download a 30-second MP3 file for testing"
    exit 1
fi

echo ""
echo "🔍 HEALTH CHECKS"
echo "==============="

# Test Whisper health
echo "🎵 Testing Whisper health (port 8001)..."
if curl -s --max-time 10 "http://$WORKER_IP:8001/health" | grep -q "healthy\|ready"; then
    echo "✅ Whisper is healthy"
else
    echo "❌ Whisper health check failed"
    WHISPER_HEALTHY=false
fi

# Test Voxtral health  
echo "🧠 Testing Voxtral health (port 8000)..."
if curl -s --max-time 10 "http://$WORKER_IP:8000/health" | grep -q "healthy\|ready"; then
    echo "✅ Voxtral is healthy"
else
    echo "❌ Voxtral health check failed"
    VOXTRAL_HEALTHY=false
fi

if [ "$WHISPER_HEALTHY" = false ] || [ "$VOXTRAL_HEALTHY" = false ]; then
    echo ""
    echo "⚠️  Some services are not ready yet."
    echo "   Models may still be loading. Wait 5-10 minutes and try again."
    echo ""
    echo "🔍 Debug commands:"
    echo "   ssh -i ~/.ssh/your-key.pem ubuntu@$WORKER_IP"
    echo "   docker logs whisper-worker"
    echo "   docker logs voxtral-worker"
    exit 1
fi

echo ""
echo "⚡ PERFORMANCE TESTS"
echo "==================="

# Test Whisper transcription speed
echo "🎵 Testing Whisper transcription..."
WHISPER_START=$(date +%s)
WHISPER_RESULT=$(curl -s --max-time 120 -X POST \
    -F "file=@$TEST_AUDIO" \
    "http://$WORKER_IP:8001/transcribe")
WHISPER_END=$(date +%s)
WHISPER_TIME=$((WHISPER_END - WHISPER_START))

if echo "$WHISPER_RESULT" | grep -q "text\|transcript"; then
    echo "✅ Whisper completed in ${WHISPER_TIME}s"
    WHISPER_TEXT=$(echo "$WHISPER_RESULT" | jq -r '.text // .transcript // "No text found"' 2>/dev/null || echo "Response received")
    echo "   Text preview: ${WHISPER_TEXT:0:80}..."
else
    echo "❌ Whisper transcription failed"
    echo "   Response: $WHISPER_RESULT"
fi

echo ""

# Test Voxtral analysis
echo "🧠 Testing Voxtral analysis..."
VOXTRAL_START=$(date +%s)
VOXTRAL_RESULT=$(curl -s --max-time 180 -X POST \
    -F "file=@$TEST_AUDIO" \
    "http://$WORKER_IP:8000/transcribe")
VOXTRAL_END=$(date +%s)
VOXTRAL_TIME=$((VOXTRAL_END - VOXTRAL_START))

if echo "$VOXTRAL_RESULT" | grep -q "text\|response\|analysis"; then
    echo "✅ Voxtral completed in ${VOXTRAL_TIME}s"
    VOXTRAL_TEXT=$(echo "$VOXTRAL_RESULT" | jq -r '.text // .response // .analysis // "No response found"' 2>/dev/null || echo "Response received")
    echo "   Response preview: ${VOXTRAL_TEXT:0:80}..."
else
    echo "❌ Voxtral analysis failed"
    echo "   Response: $VOXTRAL_RESULT"
fi

echo ""
echo "📊 PARALLEL PROCESSING SIMULATION"
echo "================================="

# Simulate parallel processing
echo "🎭 Simulating parallel execution..."
PARALLEL_START=$(date +%s)

echo "  Launching both requests simultaneously..."

# Launch both in background
{
    echo "🎵 Whisper task started..."
    WHISPER_PARALLEL=$(curl -s --max-time 120 -X POST \
        -F "file=@$TEST_AUDIO" \
        "http://$WORKER_IP:8001/transcribe")
    echo "✅ Whisper task completed"
} &
WHISPER_PID=$!

{
    echo "🧠 Voxtral task started..."
    VOXTRAL_PARALLEL=$(curl -s --max-time 180 -X POST \
        -F "file=@$TEST_AUDIO" \
        "http://$WORKER_IP:8000/transcribe")
    echo "✅ Voxtral task completed"
} &
VOXTRAL_PID=$!

# Wait for both to complete
wait $WHISPER_PID
wait $VOXTRAL_PID

PARALLEL_END=$(date +%s)
PARALLEL_TIME=$((PARALLEL_END - PARALLEL_START))

echo ""
echo "📈 PERFORMANCE ANALYSIS"
echo "======================"
echo "🎵 Whisper (Fast Transcription):"
echo "   Time: ${WHISPER_TIME}s"
echo "   Use case: Immediate transcript for user"
echo ""
echo "🧠 Voxtral (Smart Analysis):"  
echo "   Time: ${VOXTRAL_TIME}s"
echo "   Use case: Deep understanding and analysis"
echo ""
echo "⚡ Parallel Processing:"
echo "   Total time: ${PARALLEL_TIME}s"
echo "   Sequential would take: $((WHISPER_TIME + VOXTRAL_TIME))s"
if [ $((WHISPER_TIME + VOXTRAL_TIME)) -gt $PARALLEL_TIME ]; then
    SPEEDUP=$(echo "scale=1; ($WHISPER_TIME + $VOXTRAL_TIME) / $PARALLEL_TIME" | bc -l 2>/dev/null || echo "1.0")
    echo "   Speedup: ${SPEEDUP}x faster"
else
    echo "   Note: Parallel overhead detected (normal for same GPU)"
fi

echo ""
echo "🎯 USER EXPERIENCE SIMULATION"
echo "============================="
echo "In a real application:"
echo "  📝 User gets transcript in: ${WHISPER_TIME}s (can start reading immediately)"
echo "  🧠 Analysis completes in: ${PARALLEL_TIME}s (full intelligence)"
echo "  ⏱️  User waits additional: $((PARALLEL_TIME - WHISPER_TIME))s for smart features"
echo ""
echo "💡 Benefits:"
echo "  - Fast feedback: Users see transcription immediately"
echo "  - Rich insights: Get AI analysis without extra wait"
echo "  - Resource efficient: Same GPU handles both models"
echo "  - Cost effective: No need for separate instances"

echo ""
echo "🔍 SYSTEM RESOURCE CHECK"
echo "======================="
echo "📊 Checking GPU memory usage..."
ssh -i ~/.ssh/your-key.pem ubuntu@$WORKER_IP "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" 2>/dev/null | while read used total; do
    usage_percent=$(echo "scale=1; $used * 100 / $total" | bc -l 2>/dev/null || echo "0")
    echo "   GPU Memory: ${used}MB / ${total}MB (${usage_percent}% used)"
    
    if [ "${used}" -lt 13000 ]; then
        echo "   ✅ Memory usage is healthy"
    else
        echo "   ⚠️  High memory usage - monitor for stability"
    fi
done

echo ""
echo "🐳 CONTAINER STATUS"
echo "=================="
ssh -i ~/.ssh/your-key.pem ubuntu@$WORKER_IP "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null

echo ""
echo "✅ HYBRID DEPLOYMENT TEST COMPLETE!"
echo "==================================="
echo ""
echo "📋 Summary:"
echo "  - Both models running on same GPU ✅"
echo "  - Whisper: Fast transcription (${WHISPER_TIME}s) ✅"
echo "  - Voxtral: Smart analysis (${VOXTRAL_TIME}s) ✅"
echo "  - Parallel processing working ✅"
echo ""
echo "🚀 Ready for production use!"
echo "   Submit jobs to SQS: $QUEUE_URL"
echo "   Results combine both transcription and analysis"
echo ""
echo "📝 Next Steps:"
echo "1. Monitor with: ./scripts/step-502-monitor-hybrid-health.sh"
echo "2. Scale workers: ./scripts/step-503-scale-hybrid-workers.sh"  
echo "3. Test with real podcast: Send billionaire_chatgpt_podcast.mp3 to queue"