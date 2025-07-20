#!/bin/bash

echo "🔍 HYBRID WORKER HEALTH MONITORING"
echo "=================================="

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found."
    exit 1
fi

# Get worker details
if [ -f ".setup-status" ]; then
    source .setup-status
    WORKER_IP="$hybrid_worker_public_ip"
    INSTANCE_ID="$hybrid_worker_instance_id"
else
    echo "❌ No hybrid worker found in .setup-status"
    exit 1
fi

# Function to check HTTP endpoint
check_endpoint() {
    local url=$1
    local name=$2
    local response=$(curl -s --max-time 5 "$url" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        echo "✅ $name: Responding"
        if echo "$response" | grep -q "healthy\|ready"; then
            echo "   Status: Healthy"
        else
            echo "   Status: Responding but may not be ready"
        fi
    else
        echo "❌ $name: Not responding"
        return 1
    fi
}

# Function to get container stats
get_container_stats() {
    ssh -o ConnectTimeout=5 -i ~/.ssh/your-key.pem ubuntu@$WORKER_IP "
        echo '🐳 CONTAINER STATUS:'
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
        echo ''
        echo '📊 RESOURCE USAGE:'
        docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}'
        echo ''
        echo '🎮 GPU STATUS:'
        nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader
        echo ''
        echo '📋 RECENT LOGS (last 10 lines each):'
        echo '--- Whisper Logs ---'
        docker logs whisper-worker --tail 10 2>/dev/null || echo 'No Whisper logs'
        echo '--- Voxtral Logs ---' 
        docker logs voxtral-worker --tail 10 2>/dev/null || echo 'No Voxtral logs'
    " 2>/dev/null
}

echo "🎯 Monitoring worker: $WORKER_IP (Instance: $INSTANCE_ID)"
echo ""

# Check AWS instance status
echo "☁️ AWS INSTANCE STATUS:"
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null)

if [ "$INSTANCE_STATE" = "running" ]; then
    echo "✅ Instance: Running"
else
    echo "❌ Instance: $INSTANCE_STATE"
    exit 1
fi

echo ""

# Check network connectivity
echo "🌐 NETWORK CONNECTIVITY:"
if ping -c 1 -W 3 "$WORKER_IP" >/dev/null 2>&1; then
    echo "✅ Ping: Reachable"
else
    echo "❌ Ping: Not reachable"
fi

echo ""

# Check service endpoints
echo "🔌 SERVICE ENDPOINTS:"
check_endpoint "http://$WORKER_IP:8001/health" "Whisper (8001)"
check_endpoint "http://$WORKER_IP:8000/health" "Voxtral (8000)"

echo ""

# Get detailed container information
echo "📊 DETAILED SYSTEM STATUS:"
get_container_stats

echo ""
echo "⏱️ PERFORMANCE QUICK TEST:"

# Quick transcription test
TEST_START=$(date +%s)
QUICK_TEST=$(curl -s --max-time 30 -X POST \
    -F "file=@/home/ubuntu/transcription-sqs-spot-s3/test-audio/test_30sec.mp3" \
    "http://$WORKER_IP:8001/transcribe" 2>/dev/null)
TEST_END=$(date +%s)
TEST_TIME=$((TEST_END - TEST_START))

if echo "$QUICK_TEST" | grep -q "text\|transcript"; then
    echo "✅ Quick transcription test: ${TEST_TIME}s"
else
    echo "❌ Quick transcription test failed"
fi

echo ""
echo "📈 QUEUE STATUS:"
QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
    --region "$AWS_REGION" \
    --output json 2>/dev/null)

if [ $? -eq 0 ]; then
    PENDING=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
    PROCESSING=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')
    echo "  Pending jobs: $PENDING"
    echo "  Processing jobs: $PROCESSING"
else
    echo "❌ Could not check queue status"
fi

echo ""
echo "🔄 CONTINUOUS MONITORING (Ctrl+C to stop):"
echo "Press Enter to start continuous monitoring..."
read

# Continuous monitoring loop
while true; do
    clear
    echo "🔍 LIVE HYBRID WORKER MONITORING - $(date)"
    echo "=========================================="
    echo "Worker: $WORKER_IP | Instance: $INSTANCE_ID"
    echo ""
    
    # Quick health checks
    echo "🏥 Quick Health Check:"
    curl -s --max-time 3 "http://$WORKER_IP:8001/health" >/dev/null && echo "  ✅ Whisper: OK" || echo "  ❌ Whisper: Down"
    curl -s --max-time 3 "http://$WORKER_IP:8000/health" >/dev/null && echo "  ✅ Voxtral: OK" || echo "  ❌ Voxtral: Down"
    
    echo ""
    
    # Live container status
    ssh -o ConnectTimeout=3 -i ~/.ssh/your-key.pem ubuntu@$WORKER_IP "
        echo '🐳 Live Container Status:'
        docker ps --format 'table {{.Names}}\t{{.Status}}'
        echo ''
        echo '🎮 Live GPU Usage:'
        nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits | while read used total util; do
            echo \"  Memory: \${used}MB / \${total}MB (\$(echo \"scale=1; \$used * 100 / \$total\" | bc)%)\"
            echo \"  GPU Utilization: \${util}%\"
        done
        echo ''
        echo '📊 Live Performance:'
        docker stats --no-stream whisper-worker voxtral-worker --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
    " 2>/dev/null
    
    echo ""
    echo "🔄 Refreshing in 10 seconds... (Ctrl+C to stop)"
    sleep 10
done