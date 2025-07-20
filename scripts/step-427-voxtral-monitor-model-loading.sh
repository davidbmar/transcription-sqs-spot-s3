#!/bin/bash

# step-427-voxtral-monitor-model-loading.sh - Monitor Real Voxtral model loading with timing

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}⏱️  Real Voxtral Model Loading Monitor${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Create benchmark results directory
mkdir -p "$BENCHMARK_RESULTS_DIR"
BENCHMARK_FILE="$BENCHMARK_RESULTS_DIR/voxtral-loading-$(date +%Y%m%d-%H%M%S).json"

# Find Real Voxtral instances
echo -e "${GREEN}[STEP 1]${NC} Finding Real Voxtral instances..."
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,PrivateIpAddress,LaunchTime]' \
    --output json)

if [ "$INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Real Voxtral instances found"
    exit 1
fi

INSTANCE_ID=$(echo "$INSTANCES" | jq -r '.[0][0][0]')
PUBLIC_IP=$(echo "$INSTANCES" | jq -r '.[0][0][1]')
PRIVATE_IP=$(echo "$INSTANCES" | jq -r '.[0][0][2]')
LAUNCH_TIME=$(echo "$INSTANCES" | jq -r '.[0][0][3]')

echo -e "${GREEN}[OK]${NC} Monitoring instance: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  Private IP: $PRIVATE_IP" 
echo "  Launched: $LAUNCH_TIME"

# Determine which IP to use for SSH
SSH_IP="$PUBLIC_IP"
if ! ssh -i "$KEY_NAME.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" "echo 'test'" >/dev/null 2>&1; then
    echo "  Public IP failed, trying private IP..."
    if ssh -i "$KEY_NAME.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$PRIVATE_IP" "echo 'test'" >/dev/null 2>&1; then
        SSH_IP="$PRIVATE_IP"
        echo "  Using private IP for SSH"
    else
        echo -e "${RED}[ERROR]${NC} Cannot connect via SSH"
        exit 1
    fi
fi

# Function to get container info
get_container_info() {
    ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$SSH_IP" \
        "docker ps --filter name=$VOXTRAL_CONTAINER_NAME --format 'table {{.Status}}\t{{.CreatedAt}}'" 2>/dev/null || echo "unknown"
}

# Function to get recent container logs
get_container_logs() {
    local lines=${1:-10}
    ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$SSH_IP" \
        "docker logs --tail $lines $VOXTRAL_CONTAINER_NAME" 2>/dev/null || echo "No logs available"
}

# Function to check API health
check_api() {
    local endpoint="$1"
    curl -f -s --max-time 5 "$endpoint" 2>/dev/null
}

# Initialize timing data
START_TIME=$(date +%s)
TIMING_DATA="{
  \"instance_id\": \"$INSTANCE_ID\",
  \"public_ip\": \"$PUBLIC_IP\",
  \"private_ip\": \"$PRIVATE_IP\",
  \"launch_time\": \"$LAUNCH_TIME\",
  \"model_id\": \"$VOXTRAL_MODEL_ID\",
  \"container_name\": \"$VOXTRAL_CONTAINER_NAME\",
  \"monitoring_start\": \"$(date -Iseconds)\",
  \"timeline\": []
}"

# Function to add timing event
add_timing_event() {
    local event="$1"
    local status="$2"
    local details="$3"
    local timestamp=$(date -Iseconds)
    local elapsed=$(($(date +%s) - START_TIME))
    
    TIMING_DATA=$(echo "$TIMING_DATA" | jq --arg event "$event" --arg status "$status" --arg details "$details" --arg ts "$timestamp" --arg elapsed "$elapsed" \
        '.timeline += [{"event": $event, "status": $status, "details": $details, "timestamp": $ts, "elapsed_seconds": ($elapsed | tonumber)}]')
    
    echo "$TIMING_DATA" > "$BENCHMARK_FILE"
}

echo -e "${GREEN}[STEP 2]${NC} Monitoring container and model loading..."
echo "Timeout: $MODEL_LOAD_TIMEOUT_MINUTES minutes"
echo "Check interval: $HEALTH_CHECK_INTERVAL_SECONDS seconds"
echo "Results file: $BENCHMARK_FILE"
echo

# Monitor container status
CONTAINER_STATUS=$(get_container_info)
if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
    CONTAINER_START_TIME=$(echo "$CONTAINER_STATUS" | awk '{print $2 " " $3}')
    echo -e "${GREEN}✓${NC} Container is running (started: $CONTAINER_START_TIME)"
    add_timing_event "container_running" "success" "Container status: $CONTAINER_STATUS"
else
    echo -e "${YELLOW}⏳${NC} Container not running yet. Checking startup progress..."
    
    # Check if Docker is pulling the image
    DOCKER_PULL_STATUS=$(ssh -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" "sudo journalctl -u cloud-final -n 5 --no-pager" 2>/dev/null || echo "")
    if echo "$DOCKER_PULL_STATUS" | grep -q "Pull complete\|Download complete\|Verifying"; then
        echo -e "${CYAN}📥 Docker image still downloading...${NC}"
        echo "Recent progress:"
        echo "$DOCKER_PULL_STATUS" | grep -E "(Pull|Download|Verifying)" | tail -5
        add_timing_event "docker_pull" "in_progress" "Docker image downloading"
    fi
    
    # Check cloud-init status
    CLOUD_INIT_STATUS=$(ssh -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" "sudo cloud-init status" 2>/dev/null || echo "")
    echo -e "${CYAN}Cloud-init status:${NC} $CLOUD_INIT_STATUS"
    
    # Instead of exiting, wait and retry
    echo -e "${YELLOW}[INFO]${NC} Waiting for container startup (this can take 10-15 minutes for first deployment)..."
    echo "Will continue monitoring..."
    
    # Don't exit - let the main loop handle retries
    add_timing_event "container_check" "waiting" "Container not running yet: $CONTAINER_STATUS"
fi

# Monitor loading progress
TIMEOUT_SECONDS=$((MODEL_LOAD_TIMEOUT_MINUTES * 60))
ELAPSED=0
MODEL_LOADED=false
API_READY=false

echo
echo -e "${CYAN}Monitoring loading progress...${NC}"

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
    # Check API health (FastAPI has model_loaded status)
    HEALTH_RESPONSE=$(check_api "http://$PUBLIC_IP:$VOXTRAL_API_PORT/health" 2>/dev/null || echo "")
    API_RESPONSE=$(check_api "http://$PUBLIC_IP:$VOXTRAL_API_PORT/" 2>/dev/null || echo "")
    
    if [ -n "$HEALTH_RESPONSE" ]; then
        MODEL_LOADED_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.model_loaded // false' 2>/dev/null || echo "false")
        HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        
        if [ "$MODEL_LOADED_STATUS" = "true" ] && [ "$MODEL_LOADED" = false ]; then
            echo -e "${GREEN}🎉 MODEL LOADED!${NC} (after ${ELAPSED}s)"
            MODEL_LOADED=true
            add_timing_event "model_loaded" "success" "Model fully loaded and ready"
        fi
        
        if [ -n "$API_RESPONSE" ] && [ "$API_READY" = false ]; then
            API_STATUS=$(echo "$API_RESPONSE" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            if [ "$API_STATUS" = "ready" ]; then
                echo -e "${GREEN}🚀 API READY!${NC} (after ${ELAPSED}s)"
                API_READY=true
                add_timing_event "api_ready" "success" "API responding and ready"
            fi
        fi
        
        # Both ready - we're done!
        if [ "$MODEL_LOADED" = true ] && [ "$API_READY" = true ]; then
            break
        fi
        
        # Show progress
        echo -e "${YELLOW}[$ELAPSED/${TIMEOUT_SECONDS}s]${NC} Health: $HEALTH_STATUS | Model: $MODEL_LOADED_STATUS | API: $API_STATUS"
    else
        echo -e "${YELLOW}[$ELAPSED/${TIMEOUT_SECONDS}s]${NC} APIs not responding yet..."
        add_timing_event "api_check" "waiting" "APIs not responding at ${ELAPSED}s"
    fi
    
    # Check for loading progress in logs
    RECENT_LOGS=$(get_container_logs 5)
    if echo "$RECENT_LOGS" | grep -q "Fetching.*files"; then
        FETCH_LINE=$(echo "$RECENT_LOGS" | grep "Fetching.*files" | tail -1)
        echo -e "${CYAN}  📥 $FETCH_LINE${NC}"
        add_timing_event "model_download" "in_progress" "$FETCH_LINE"
    elif echo "$RECENT_LOGS" | grep -q "Loading.*model"; then
        echo -e "${CYAN}  🔄 Loading model components...${NC}"
        add_timing_event "model_loading" "in_progress" "Loading model components"
    elif echo "$RECENT_LOGS" | grep -q "MODEL LOADED"; then
        echo -e "${GREEN}  ✅ Model loaded successfully${NC}"
    fi
    
    sleep "$HEALTH_CHECK_INTERVAL_SECONDS"
    ELAPSED=$((ELAPSED + HEALTH_CHECK_INTERVAL_SECONDS))
done

# Final status
if [ "$MODEL_LOADED" = true ] && [ "$API_READY" = true ]; then
    echo
    echo -e "${GREEN}✅ MONITORING COMPLETE${NC}"
    add_timing_event "monitoring_complete" "success" "Model and API fully ready"
    
    # Calculate total times
    TOTAL_TIME=$(($(date +%s) - START_TIME))
    
    # Update final timing data
    TIMING_DATA=$(echo "$TIMING_DATA" | jq --arg total "$TOTAL_TIME" --arg status "success" \
        '.monitoring_end = (now | strftime("%Y-%m-%dT%H:%M:%SZ")) | .total_time_seconds = ($total | tonumber) | .final_status = $status')
else
    echo
    echo -e "${RED}❌ TIMEOUT REACHED${NC}"
    add_timing_event "monitoring_timeout" "failed" "Timeout after $TIMEOUT_SECONDS seconds"
    
    TIMING_DATA=$(echo "$TIMING_DATA" | jq --arg total "$TIMEOUT_SECONDS" --arg status "timeout" \
        '.monitoring_end = (now | strftime("%Y-%m-%dT%H:%M:%SZ")) | .total_time_seconds = ($total | tonumber) | .final_status = $status')
fi

# Save final results
echo "$TIMING_DATA" > "$BENCHMARK_FILE"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}📊 Timing Results${NC}"
echo -e "${BLUE}======================================${NC}"

# Display timing summary
echo "$TIMING_DATA" | jq -r '.timeline[] | "\(.elapsed_seconds)s - \(.event): \(.status) - \(.details)"'

echo
echo -e "${GREEN}[RESULTS FILE]${NC}"
echo "Detailed timing data saved to: $BENCHMARK_FILE"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
if [ "$MODEL_LOADED" = true ] && [ "$API_READY" = true ]; then
    echo "1. Test transcription performance:"
    echo "   ./scripts/step-430-voxtral-test-transcription.sh"
    echo
    echo "2. Run benchmarks:"
    echo "   ./scripts/step-435-voxtral-benchmark-vs-whisper.sh"
else
    echo "1. Check container logs for issues:"
    echo "   ssh -i $KEY_NAME.pem ubuntu@$SSH_IP \"docker logs $VOXTRAL_CONTAINER_NAME\""
    echo
    echo "2. Restart if needed and monitor again"
fi