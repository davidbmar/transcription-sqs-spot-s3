#!/bin/bash

# step-428-voxtral-flexible-monitor.sh - Flexible monitoring for Real Voxtral with polling options

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

# Parse command line arguments
MODE="medium"  # Default mode
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -q|--quick)
            MODE="quick"
            shift
            ;;
        -m|--medium)
            MODE="medium"
            shift
            ;;
        -f|--full|--forever)
            MODE="full"
            shift
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            SHOW_HELP=true
            shift
            ;;
    esac
done

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}📊 Real Voxtral Flexible Monitor${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -q, --quick      Quick poll (2 minutes) - Check if already running"
    echo "  -m, --medium     Medium poll (10 minutes) - Wait for container start [DEFAULT]"
    echo "  -f, --full       Full monitoring until ready (30 minutes) - Complete startup"
    echo "  -h, --help       Show this help message"
    echo
    echo "Examples:"
    echo "  $0 --quick       # Quick check if container is already up"
    echo "  $0 --medium      # Wait up to 10 min for container to start"
    echo "  $0 --full        # Monitor complete startup including model loading"
    echo
    exit 0
fi

# Set timeouts based on mode
case $MODE in
    quick)
        TIMEOUT_MINUTES=2
        CHECK_INTERVAL=10
        echo -e "${CYAN}🚀 Quick Mode: Checking for ${TIMEOUT_MINUTES} minutes${NC}"
        ;;
    medium)
        TIMEOUT_MINUTES=10
        CHECK_INTERVAL=20
        echo -e "${YELLOW}⏱️  Medium Mode: Monitoring for ${TIMEOUT_MINUTES} minutes${NC}"
        ;;
    full)
        TIMEOUT_MINUTES=30
        CHECK_INTERVAL=30
        echo -e "${GREEN}♾️  Full Mode: Monitoring for ${TIMEOUT_MINUTES} minutes${NC}"
        ;;
esac

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}📊 Real Voxtral Flexible Monitor${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Create benchmark results directory
mkdir -p "$BENCHMARK_RESULTS_DIR"
BENCHMARK_FILE="$BENCHMARK_RESULTS_DIR/voxtral-monitor-$(date +%Y%m%d-%H%M%S).json"

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

# Initialize timing data
START_TIME=$(date +%s)
TIMING_DATA=$(jq -n \
    --arg instance_id "$INSTANCE_ID" \
    --arg public_ip "$PUBLIC_IP" \
    --arg private_ip "$PRIVATE_IP" \
    --arg launch_time "$LAUNCH_TIME" \
    --arg model_id "$VOXTRAL_MODEL_ID" \
    --arg container_name "$VOXTRAL_CONTAINER_NAME" \
    --arg monitoring_start "$(date -Iseconds)" \
    --arg mode "$MODE" \
    --arg timeout "$TIMEOUT_MINUTES" \
'{
    "instance_id": $instance_id,
    "public_ip": $public_ip,
    "private_ip": $private_ip,
    "launch_time": $launch_time,
    "model_id": $model_id,
    "container_name": $container_name,
    "monitoring_start": $monitoring_start,
    "mode": $mode,
    "timeout_minutes": ($timeout | tonumber),
    "timeline": []
}')

# Function to add timing event
add_timing_event() {
    local phase="$1"
    local status="$2"
    local details="$3"
    local timestamp=$(date -Iseconds)
    local elapsed=$(($(date +%s) - START_TIME))
    
    TIMING_DATA=$(echo "$TIMING_DATA" | jq --arg phase "$phase" --arg status "$status" --arg details "$details" --arg ts "$timestamp" --arg elapsed "$elapsed" \
        '.timeline += [{"phase": $phase, "status": $status, "details": $details, "timestamp": $ts, "elapsed_seconds": ($elapsed | tonumber)}]')
    
    echo "$TIMING_DATA" > "$BENCHMARK_FILE"
}

# Helper functions
check_container() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" \
        "docker ps -a --filter name=$VOXTRAL_CONTAINER_NAME --format '{{.Status}}' 2>/dev/null" 2>/dev/null || echo ""
}

check_startup_logs() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" \
        "sudo journalctl -u cloud-final -n 20 --no-pager 2>/dev/null | grep -E '(Pull|Download|Verifying|complete|Status|Starting|Digest|Created|Up)' | tail -10" 2>/dev/null || echo ""
}

check_docker_status() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" \
        "docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep voxtral || echo 'No images yet'; echo '---'; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Created}}' | grep -E '(NAMES|voxtral)' || echo 'No containers yet'" 2>/dev/null || echo ""
}

check_container_logs() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" \
        "docker logs $VOXTRAL_CONTAINER_NAME 2>&1 | tail -20" 2>/dev/null || echo ""
}

check_api_health() {
    local endpoint="$1"
    curl -sf -m 5 "$endpoint" 2>/dev/null || echo ""
}

echo -e "${GREEN}[STEP 2]${NC} Monitoring status..."
echo "Mode: $MODE"
echo "Timeout: $TIMEOUT_MINUTES minutes"
echo "Check interval: $CHECK_INTERVAL seconds"
echo "Results: $BENCHMARK_FILE"
echo

# Monitoring loop
TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
ELAPSED=0
CONTAINER_STARTED=false
MODEL_LOADED=false
API_READY=false

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
    # Phase 1: Check container status
    CONTAINER_STATUS=$(check_container)
    
    if [ -z "$CONTAINER_STATUS" ]; then
        echo -e "${YELLOW}[${ELAPSED}s]${NC} ⏳ No container found. Checking startup..."
        
        # Show Docker pull progress
        STARTUP_LOGS=$(check_startup_logs)
        if [ -n "$STARTUP_LOGS" ]; then
            echo -e "${CYAN}📥 Docker activity:${NC}"
            echo "$STARTUP_LOGS" | sed 's/^/    /'
        fi
        
        # Show Docker status
        DOCKER_STATUS=$(check_docker_status)
        if [ -n "$DOCKER_STATUS" ]; then
            echo -e "${CYAN}🐳 Docker status:${NC}"
            echo "$DOCKER_STATUS" | sed 's/^/    /'
        fi
        
        add_timing_event "startup" "waiting" "Container not found"
        
    elif [[ "$CONTAINER_STATUS" == *"Up"* ]] && [ "$CONTAINER_STARTED" = false ]; then
        echo -e "${GREEN}[${ELAPSED}s]${NC} ✅ Container started!"
        CONTAINER_STARTED=true
        add_timing_event "container_start" "success" "Container is running: $CONTAINER_STATUS"
        
        # For quick mode, this might be enough
        if [ "$MODE" = "quick" ]; then
            echo -e "${GREEN}✅ Container is running. Quick check complete!${NC}"
            break
        fi
        
    elif [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
        # Phase 2: Check API endpoints
        HEALTH_RESPONSE=$(check_api_health "http://$PUBLIC_IP:$VOXTRAL_API_PORT/health")
        
        if [ -n "$HEALTH_RESPONSE" ]; then
            MODEL_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.model_loaded // false' 2>/dev/null || echo "false")
            API_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            
            echo -e "${CYAN}[${ELAPSED}s]${NC} Container: ✅ | Model: $([ "$MODEL_STATUS" = "true" ] && echo "✅" || echo "⏳") | API: $([ "$API_STATUS" = "healthy" ] && echo "✅" || echo "⏳")"
            
            # Show detailed health response
            echo -e "${CYAN}📊 Health details:${NC}"
            echo "$HEALTH_RESPONSE" | jq '.' 2>/dev/null | sed 's/^/    /' || echo "    $HEALTH_RESPONSE"
            
            if [ "$MODEL_STATUS" = "true" ] && [ "$MODEL_LOADED" = false ]; then
                echo -e "${GREEN}[${ELAPSED}s]${NC} 🎉 Model loaded successfully!"
                MODEL_LOADED=true
                add_timing_event "model_loaded" "success" "Model fully loaded"
                
                # For medium mode, this is a good stopping point
                if [ "$MODE" = "medium" ]; then
                    echo -e "${GREEN}✅ Model loaded. Medium monitoring complete!${NC}"
                    break
                fi
            fi
            
            if [ "$API_STATUS" = "healthy" ] && [ "$API_READY" = false ]; then
                API_READY=true
                add_timing_event "api_ready" "success" "API is healthy and ready"
            fi
            
            # Check if fully ready
            if [ "$MODEL_LOADED" = true ] && [ "$API_READY" = true ]; then
                echo -e "${GREEN}[${ELAPSED}s]${NC} 🎉 Voxtral fully operational!"
                add_timing_event "fully_ready" "success" "System fully operational"
                break
            fi
        else
            echo -e "${YELLOW}[${ELAPSED}s]${NC} Container: ✅ | API not responding yet..."
            
            # Show container logs to see what's happening
            CONTAINER_LOGS=$(check_container_logs)
            if [ -n "$CONTAINER_LOGS" ]; then
                echo -e "${CYAN}📋 Container logs:${NC}"
                echo "$CONTAINER_LOGS" | sed 's/^/    /'
            fi
            
            # Show container status details
            DOCKER_STATUS=$(check_docker_status)
            if [ -n "$DOCKER_STATUS" ]; then
                echo -e "${CYAN}🐳 Container status:${NC}"
                echo "$DOCKER_STATUS" | sed 's/^/    /'
            fi
        fi
    elif [[ "$CONTAINER_STATUS" == *"Created"* ]] || [[ "$CONTAINER_STATUS" == *"Exited"* ]]; then
        echo -e "${RED}[${ELAPSED}s]${NC} ⚠️ Container status: $CONTAINER_STATUS"
        
        # Show container logs to diagnose issue
        CONTAINER_LOGS=$(check_container_logs)
        if [ -n "$CONTAINER_LOGS" ]; then
            echo -e "${CYAN}📋 Container logs:${NC}"
            echo "$CONTAINER_LOGS" | sed 's/^/    /'
        fi
        
        add_timing_event "container_issue" "error" "Container status: $CONTAINER_STATUS"
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

# Final status
echo
echo -e "${BLUE}======================================${NC}"

if [ "$MODEL_LOADED" = true ] && [ "$API_READY" = true ]; then
    echo -e "${GREEN}✅ Monitoring Complete - System Ready${NC}"
    FINAL_STATUS="ready"
elif [ "$CONTAINER_STARTED" = true ]; then
    echo -e "${YELLOW}⚠️  Monitoring Timeout - Container Running${NC}"
    FINAL_STATUS="partial"
else
    echo -e "${RED}❌ Monitoring Timeout - System Not Ready${NC}"
    FINAL_STATUS="timeout"
fi

# Update final timing data
TIMING_DATA=$(echo "$TIMING_DATA" | jq \
    --arg monitoring_end "$(date -Iseconds)" \
    --arg total_time "$ELAPSED" \
    --arg final_status "$FINAL_STATUS" \
    '.monitoring_end = $monitoring_end | .total_time_seconds = ($total_time | tonumber) | .final_status = $final_status')

echo "$TIMING_DATA" > "$BENCHMARK_FILE"

echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[SUMMARY]${NC}"
echo "Mode: $MODE"
echo "Duration: ${ELAPSED}s"
echo "Status: $FINAL_STATUS"
echo "Results saved: $BENCHMARK_FILE"

if [ "$CONTAINER_STARTED" = true ]; then
    echo
    echo -e "${GREEN}[API ENDPOINTS]${NC}"
    echo "API: http://$PUBLIC_IP:$VOXTRAL_API_PORT"
    echo "Health: http://$PUBLIC_IP:$VOXTRAL_API_PORT/health"
    echo "Docs: http://$PUBLIC_IP:$VOXTRAL_API_PORT/docs"
fi

echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
if [ "$FINAL_STATUS" = "ready" ]; then
    echo "1. Test transcription: ./scripts/step-430-voxtral-test-transcription.sh"
    echo "2. Run benchmarks: ./scripts/step-435-voxtral-benchmark-vs-whisper.sh"
elif [ "$FINAL_STATUS" = "partial" ]; then
    echo "1. Check logs: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'docker logs $VOXTRAL_CONTAINER_NAME'"
    echo "2. Continue monitoring: $0 --full"
else
    echo "1. Check startup: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'sudo tail -f /var/log/cloud-init-output.log'"
    echo "2. Check instance: ./scripts/step-426-voxtral-check-gpu-health.sh"
fi