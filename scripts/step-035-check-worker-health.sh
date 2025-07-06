#!/bin/bash

# step-035-check-worker-health.sh - Check worker instance health and readiness

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
echo -e "${BLUE}Worker Instance Health Check${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Find running worker instances
echo -e "${GREEN}[STEP 1]${NC} Finding worker instances..."
INSTANCES=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,LaunchTime]' \
    --output text)

if [ -z "$INSTANCES" ]; then
    echo -e "${RED}[ERROR]${NC} No worker instances found"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Found worker instances:"
echo "$INSTANCES"
echo

# Check each instance
while IFS=$'\t' read -r INSTANCE_ID STATE PUBLIC_IP LAUNCH_TIME; do
    echo -e "${GREEN}[STEP 2]${NC} Checking instance: $INSTANCE_ID"
    echo "  State: $STATE"
    echo "  Public IP: $PUBLIC_IP" 
    echo "  Launch Time: $LAUNCH_TIME"
    
    if [ "$STATE" != "running" ]; then
        echo -e "${YELLOW}[WARNING]${NC} Instance not running yet"
        continue
    fi
    
    if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
        echo -e "${RED}[ERROR]${NC} No public IP assigned"
        continue
    fi
    
    # Calculate uptime
    LAUNCH_SECONDS=$(date -d "$LAUNCH_TIME" +%s)
    CURRENT_SECONDS=$(date +%s)
    UPTIME_MINUTES=$(( (CURRENT_SECONDS - LAUNCH_SECONDS) / 60 ))
    echo "  Uptime: ${UPTIME_MINUTES} minutes"
    
    # Check if SSH is available
    echo -e "${GREEN}[STEP 3]${NC} Testing SSH connectivity..."
    if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'echo "SSH OK"' >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} SSH connection successful"
        
        # Check cloud-init status
        echo -e "${GREEN}[STEP 4]${NC} Checking cloud-init status..."
        CLOUD_INIT_STATUS=$(ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'cloud-init status' 2>/dev/null || echo "error")
        echo "  Cloud-init status: $CLOUD_INIT_STATUS"
        
        if [[ "$CLOUD_INIT_STATUS" == *"done"* ]]; then
            echo -e "${GREEN}[OK]${NC} Cloud-init completed successfully"
            
            # Check if transcription worker is running
            echo -e "${GREEN}[STEP 5]${NC} Checking transcription worker..."
            WORKER_PROCESSES=$(ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'ps aux | grep transcription_worker | grep -v grep | wc -l' 2>/dev/null || echo "0")
            
            if [ "$WORKER_PROCESSES" -gt 0 ]; then
                echo -e "${GREEN}[OK]${NC} Transcription worker is running ($WORKER_PROCESSES processes)"
                
                # Check worker logs for errors
                echo -e "${GREEN}[STEP 6]${NC} Checking recent worker logs..."
                ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'if [ -f transcription-sqs-spot-s3/src/worker.log ]; then tail -5 transcription-sqs-spot-s3/src/worker.log; else echo "No worker log found"; fi' 2>/dev/null || echo "Could not read logs"
                
            else
                echo -e "${RED}[ERROR]${NC} Transcription worker not running"
                
                # Check cloud-init logs for errors
                echo -e "${YELLOW}[INFO]${NC} Checking cloud-init logs for errors..."
                ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'sudo tail -20 /var/log/cloud-init-output.log | grep -i error | tail -5' 2>/dev/null || echo "Could not read cloud-init logs"
            fi
            
        elif [[ "$CLOUD_INIT_STATUS" == *"running"* ]]; then
            echo -e "${YELLOW}[WARNING]${NC} Cloud-init still running (setup in progress)"
            echo -e "${YELLOW}[INFO]${NC} Wait a few more minutes and run this check again"
            
        else
            echo -e "${RED}[ERROR]${NC} Cloud-init failed or encountered errors"
            echo -e "${YELLOW}[INFO]${NC} Checking cloud-init logs..."
            ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'sudo tail -10 /var/log/cloud-init-output.log' 2>/dev/null || echo "Could not read logs"
        fi
        
    else
        echo -e "${RED}[ERROR]${NC} SSH connection failed"
        if [ "$UPTIME_MINUTES" -lt 2 ]; then
            echo -e "${YELLOW}[INFO]${NC} Instance is very new, may still be booting"
        fi
    fi
    
    echo
    echo "---"
    echo
    
done <<< "$INSTANCES"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Health Check Complete${NC}"
echo -e "${BLUE}======================================${NC}"