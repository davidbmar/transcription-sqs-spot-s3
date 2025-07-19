#!/bin/bash

# step-325-fast-api-check-gpu-health.sh - Check health of Fast API GPU instances

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
echo -e "${BLUE}🎤 Fast API GPU Health Check${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Find Fast API instances
echo -e "${GREEN}[STEP 1]${NC} Finding Fast API GPU instances..."

INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,PrivateIpAddress,LaunchTime,State.Name]' \
    --output json)

if [ "$INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Fast API instances found"
    exit 1
fi

# Parse instance details
INSTANCE_COUNT=$(echo "$INSTANCES" | jq -r '. | length')
echo -e "${GREEN}[OK]${NC} Found $INSTANCE_COUNT Fast API instance(s)"

# Check each instance
echo "$INSTANCES" | jq -r '.[][] | @tsv' | while IFS=$'\t' read -r instance_id public_ip private_ip launch_time state; do
    echo
    echo -e "${BLUE}Instance: $instance_id${NC}"
    echo "Public IP: $public_ip"
    echo "Private IP: $private_ip"
    echo "Launch Time: $launch_time"
    echo "State: $state"
    
    # Test SSH connectivity
    echo -e "\n${YELLOW}[TEST]${NC} SSH Connectivity..."
    if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$public_ip" "echo 'SSH connection successful'" 2>/dev/null; then
        echo -e "${GREEN}✓ SSH connection successful${NC}"
        
        # Check setup status
        echo -e "\n${YELLOW}[TEST]${NC} Setup Status..."
        SETUP_LOG=$(ssh -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" ubuntu@"$public_ip" "sudo tail -5 /var/log/fast-api-setup.log 2>/dev/null || echo 'Log not found'")
        echo "$SETUP_LOG"
        
        # Check Docker status
        echo -e "\n${YELLOW}[TEST]${NC} Docker Status..."
        DOCKER_STATUS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" ubuntu@"$public_ip" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo 'Docker not ready'")
        echo "$DOCKER_STATUS"
        
        # Check container logs
        echo -e "\n${YELLOW}[TEST]${NC} Fast API Container Logs (last 10 lines)..."
        CONTAINER_LOGS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" ubuntu@"$public_ip" "docker logs fast-api-gpu 2>&1 | tail -10 || echo 'Container not found'")
        echo "$CONTAINER_LOGS"
        
        # Check GPU status
        echo -e "\n${YELLOW}[TEST]${NC} GPU Status..."
        GPU_STATUS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" ubuntu@"$public_ip" "docker exec fast-api-gpu nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || echo 'GPU check failed'")
        if [ "$GPU_STATUS" != "GPU check failed" ]; then
            echo -e "${GREEN}✓ GPU detected: $GPU_STATUS${NC}"
        else
            echo -e "${YELLOW}⚠ GPU not accessible in container${NC}"
        fi
        
        # Test API endpoint
        echo -e "\n${YELLOW}[TEST]${NC} API Health Check..."
        if curl -f -s --max-time 5 "http://$public_ip:8000/health" > /tmp/fast-api_health.json 2>/dev/null; then
            echo -e "${GREEN}✓ API is healthy${NC}"
            cat /tmp/fast-api_health.json | jq . 2>/dev/null || cat /tmp/fast-api_health.json
        else
            echo -e "${RED}✗ API health check failed${NC}"
            echo "Trying to get more info..."
            curl -v --max-time 5 "http://$public_ip:8000/" 2>&1 | grep -E "Connected|HTTP|refused"
        fi
        
        # Overall status
        echo -e "\n${BLUE}Overall Status:${NC}"
        if curl -f -s --max-time 5 "http://$public_ip:8000/health" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ FAST_API READY${NC}"
            echo -e "API Endpoint: ${GREEN}http://$public_ip:8000${NC}"
            echo -e "Swagger Docs: ${GREEN}http://$public_ip:8000/docs${NC}"
        else
            echo -e "${YELLOW}⚠️  FAST_API STILL INITIALIZING${NC}"
            echo "Please wait a few more minutes for setup to complete"
        fi
        
    else
        echo -e "${RED}✗ SSH connection failed${NC}"
        echo "Instance may still be initializing. Try again in a minute."
    fi
    
    echo -e "\n${BLUE}======================================${NC}"
done

# Summary
echo
echo -e "${GREEN}[SUMMARY]${NC}"
echo "Total Fast API instances: $INSTANCE_COUNT"
echo
echo -e "${YELLOW}[TIPS]${NC}"
echo "• If API is not responding, wait 2-3 more minutes"
echo "• Check container logs: docker logs fast-api-gpu"
echo "• Test transcription: curl -X POST -F 'file=@audio.mp3' http://IP:8000/transcribe"