#!/bin/bash

# step-426-voxtral-check-gpu-health.sh - Check Real Voxtral GPU worker health

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
echo -e "${BLUE}🏥 Real Voxtral GPU Health Check${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Function to check status with visual feedback
check_status() {
    local description="$1"
    local command="$2"
    local help_text="$3"
    
    echo -n "  $description... "
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        if [ -n "$help_text" ]; then
            echo -e "    ${YELLOW}Help:${NC} $help_text"
        fi
        return 1
    fi
}

# Function to check HTTP endpoint
check_http() {
    local url="$1"
    local timeout="${2:-5}"
    curl -f -s --max-time "$timeout" "$url" >/dev/null 2>&1
}

# Function to check JSON endpoint and parse
check_json_endpoint() {
    local url="$1"
    local timeout="${2:-5}"
    curl -f -s --max-time "$timeout" "$url" 2>/dev/null
}

# Find Real Voxtral instances
echo -e "${GREEN}[STEP 1]${NC} Finding Real Voxtral instances..."
REAL_VOXTRAL_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,PrivateIpAddress,State.Name,LaunchTime]' \
    --output json)

if [ "$REAL_VOXTRAL_INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Real Voxtral instances found"
    echo "Launch instances first: ./scripts/step-420-voxtral-launch-gpu-instances.sh"
    exit 1
fi

INSTANCE_COUNT=$(echo "$REAL_VOXTRAL_INSTANCES" | jq 'length')
echo -e "${GREEN}[OK]${NC} Found $INSTANCE_COUNT Real Voxtral instance(s)"

# Display instance overview
echo
echo -e "${CYAN}Instance Overview:${NC}"
echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "  \(.[0]) - Public: \(.[1]) - Private: \(.[2]) - \(.[3]) (launched: \(.[4]))"'

# Check each instance
echo
echo -e "${GREEN}[STEP 2]${NC} Checking instance health..."

HEALTHY_COUNT=0
TOTAL_CHECKS=0

echo "$REAL_VOXTRAL_INSTANCES" | jq -c '.[][]' | while read -r instance; do
    INSTANCE_ID=$(echo "$instance" | jq -r '.[0]')
    PUBLIC_IP=$(echo "$instance" | jq -r '.[1]')
    PRIVATE_IP=$(echo "$instance" | jq -r '.[2]')
    STATE=$(echo "$instance" | jq -r '.[3]')
    
    echo
    echo -e "${BLUE}Instance: $INSTANCE_ID${NC}"
    echo -e "  Public IP: $PUBLIC_IP"
    echo -e "  Private IP: $PRIVATE_IP"
    
    INSTANCE_HEALTHY=true
    
    # Check 1: Instance state
    if [ "$STATE" = "running" ]; then
        echo -e "  Instance state... ${GREEN}✓ $STATE${NC}"
    else
        echo -e "  Instance state... ${RED}✗ $STATE${NC}"
        INSTANCE_HEALTHY=false
    fi
    
    # Check 2: SSH connectivity (try public first, then private)
    echo -n "  SSH connectivity... "
    SSH_WORKS=false
    SSH_IP=""
    
    # Try public IP first
    if ssh -i "$KEY_NAME.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" "echo 'test'" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ (public IP)${NC}"
        SSH_WORKS=true
        SSH_IP="$PUBLIC_IP"
    # Try private IP as fallback
    elif ssh -i "$KEY_NAME.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$PRIVATE_IP" "echo 'test'" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ (private IP)${NC}"
        SSH_WORKS=true
        SSH_IP="$PRIVATE_IP"
    else
        echo -e "${RED}✗${NC}"
        echo -e "    ${YELLOW}Help:${NC} Check security group SSH rules or try: ./scripts/step-425-voxtral-add-current-ip-to-security-group.sh"
        INSTANCE_HEALTHY=false
    fi
    
    # Check 3: Health endpoint
    echo -n "  Health endpoint (port 8080)... "
    if check_http "http://$PUBLIC_IP:8080/health" 10; then
        echo -e "${GREEN}✓${NC}"
        
        # Get detailed health info
        HEALTH_INFO=$(check_json_endpoint "http://$PUBLIC_IP:8080/health" 10)
        if [ -n "$HEALTH_INFO" ]; then
            echo "    $(echo "$HEALTH_INFO" | jq -r '.status // "unknown"') - GPU: $(echo "$HEALTH_INFO" | jq -r '.gpu_available // "unknown"')"
        fi
    else
        echo -e "${RED}✗${NC}"
        echo -e "    ${YELLOW}Help:${NC} Container may still be starting (wait 5-10 minutes)"
        INSTANCE_HEALTHY=false
    fi
    
    # Check 4: Main API endpoint
    echo -n "  Main API (port 8000)... "
    if check_http "http://$PUBLIC_IP:8000/" 10; then
        echo -e "${GREEN}✓${NC}"
        
        # Get API info
        API_INFO=$(check_json_endpoint "http://$PUBLIC_IP:8000/" 10)
        if [ -n "$API_INFO" ]; then
            MODEL=$(echo "$API_INFO" | jq -r '.model // "unknown"')
            STATUS=$(echo "$API_INFO" | jq -r '.status // "unknown"')
            echo "    $STATUS - Model: $MODEL"
        fi
    else
        echo -e "${RED}✗${NC}"
        echo -e "    ${YELLOW}Help:${NC} Check if Voxtral container is running"
        INSTANCE_HEALTHY=false
    fi
    
    # Check 5: Docker container status (requires SSH)
    if [ "$SSH_WORKS" = true ]; then
        echo -n "  Docker container... "
        CONTAINER_STATUS=$(ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$SSH_IP" \
            "docker ps --filter name=real-voxtral-worker --format '{{.Status}}'" 2>/dev/null || echo "unknown")
        
        if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
            echo -e "${GREEN}✓ $CONTAINER_STATUS${NC}"
        elif [ "$CONTAINER_STATUS" = "unknown" ]; then
            echo -e "${YELLOW}? SSH failed${NC}"
            INSTANCE_HEALTHY=false
        else
            echo -e "${RED}✗ $CONTAINER_STATUS${NC}"
            INSTANCE_HEALTHY=false
        fi
        
        # Check 6: GPU availability (if accessible)
        echo -n "  GPU detection... "
        GPU_STATUS=$(ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$SSH_IP" \
            "docker exec real-voxtral-worker nvidia-smi --query-gpu=name --format=csv,noheader" 2>/dev/null || echo "unknown")
    else
        echo "  Docker container... ${YELLOW}? SSH not available${NC}"
        echo "  GPU detection... ${YELLOW}? SSH not available${NC}"
        INSTANCE_HEALTHY=false
    fi
    
    if [ "$GPU_STATUS" != "unknown" ] && [ -n "$GPU_STATUS" ]; then
        echo -e "${GREEN}✓ $GPU_STATUS${NC}"
    else
        echo -e "${YELLOW}? Unable to detect${NC}"
    fi
    
    # Summary for this instance
    if [ "$INSTANCE_HEALTHY" = true ]; then
        echo -e "  ${GREEN}Overall Status: HEALTHY ✓${NC}"
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        echo -e "  ${RED}Overall Status: UNHEALTHY ✗${NC}"
    fi
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
done

# Wait for the while loop to complete
wait

# Re-count for summary (since subshell doesn't update parent variables)
HEALTHY_COUNT=0
TOTAL_CHECKS=0

echo "$REAL_VOXTRAL_INSTANCES" | jq -c '.[][]' | while read -r instance; do
    PUBLIC_IP=$(echo "$instance" | jq -r '.[1]')
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if check_http "http://$PUBLIC_IP:8080/health" 5 && check_http "http://$PUBLIC_IP:8000/" 5; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    fi
done

echo
echo -e "${GREEN}[STEP 3]${NC} Troubleshooting information..."

# Show common troubleshooting commands
echo
echo -e "${YELLOW}[TROUBLESHOOTING COMMANDS]${NC}"
echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | 
    "Instance \(.[0]) (\(.[1])):
  Monitor startup: ssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1]) \"sudo tail -f /var/log/voxtral-startup.log\"
  Container logs: ssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1]) \"docker logs real-voxtral-worker\"
  Container status: ssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1]) \"docker ps -a\"
  Test health: curl http://\(.[1]):8080/health
  Test API: curl http://\(.[1]):8000/
"'

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Real Voxtral Health Check Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[HEALTH SUMMARY]${NC}"
echo "Total instances: $INSTANCE_COUNT"
echo "Model: $VOXTRAL_MODEL_ID"
echo
echo -e "${GREEN}[API ENDPOINTS]${NC}"
echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | 
    "Instance \(.[0]):
  API: http://\(.[1]):8000
  Health: http://\(.[1]):8080/health
  Docs: http://\(.[1]):8000/docs
"'

echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Test Real Voxtral transcription:"
echo "   ./scripts/step-430-voxtral-test-transcription.sh"
echo
echo "2. Benchmark against Whisper:"
echo "   ./scripts/step-435-voxtral-benchmark-vs-whisper.sh"
echo
if [ "$HEALTHY_COUNT" -lt "$TOTAL_CHECKS" ]; then
    echo -e "${YELLOW}[NOTE]${NC} Some instances are unhealthy. Check troubleshooting commands above."
    echo "Real Voxtral containers may take 5-10 minutes to fully initialize."
fi