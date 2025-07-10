#!/bin/bash

# step-125-check-worker-health.sh - Check DLAMI worker instance health and readiness (PATH 100)

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Worker Instance Health Check (with Auto-Wait)${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Configuration for auto-wait
MAX_WAIT_MINUTES=6  # 2x expected time for DLAMI (3 min expected)
CHECK_INTERVAL=60   # Check every 60 seconds
MAX_ATTEMPTS=$((MAX_WAIT_MINUTES * 60 / CHECK_INTERVAL))
ATTEMPT=1

echo -e "${YELLOW}[INFO]${NC} Will check every ${CHECK_INTERVAL}s for up to ${MAX_WAIT_MINUTES} minutes..."
echo

# Main health check function
check_worker_health() {
    local attempt_num=$1
    local max_attempts=$2
    
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Health Check Attempt $attempt_num/$max_attempts${NC}"
    echo -e "${BLUE}======================================${NC}"
    
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
    return 1
fi

echo -e "${GREEN}[OK]${NC} Found worker instances:"
echo "$INSTANCES"
echo

# Track if any worker is healthy
local healthy_workers=0
local total_workers=0

# Check each instance
while IFS=$'\t' read -r INSTANCE_ID STATE PUBLIC_IP LAUNCH_TIME; do
    ((total_workers++))
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
                ((healthy_workers++))
                
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
            echo -e "${YELLOW}[WARNING]${NC} Cloud-init still running, but checking if worker is operational..."
            
            # Check if transcription worker is running despite cloud-init status
            WORKER_PROCESSES=$(ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'ps aux | grep transcription_worker | grep -v grep | wc -l' 2>/dev/null || echo "0")
            
            if [ "$WORKER_PROCESSES" -gt 0 ]; then
                echo -e "${GREEN}[OK]${NC} ✅ Transcription worker is running despite cloud-init status!"
                echo -e "${GREEN}[INFO]${NC} Worker is operational and processing jobs"
                
                # Check recent worker activity
                echo -e "${GREEN}[STEP 5]${NC} Checking recent worker activity..."
                RECENT_ACTIVITY=$(ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" 'sudo tail -5 /var/log/cloud-init-output.log | grep -E "(SUCCESS|processing|Transcription worker|Queue is empty)" | tail -2' 2>/dev/null || echo "No recent activity")
                echo "Recent activity:"
                echo "$RECENT_ACTIVITY"
                
            else
                echo -e "${YELLOW}[INFO]${NC} Worker not started yet - cloud-init still setting up"
                echo -e "${YELLOW}[INFO]${NC} Wait a few more minutes and run this check again"
            fi
            
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

    # Return success if any workers are healthy
    echo -e "${BLUE}Status: $healthy_workers/$total_workers workers healthy${NC}"
    
    if [ "$healthy_workers" -gt 0 ]; then
        echo -e "${GREEN}✅ SUCCESS: At least one worker is healthy!${NC}"
        return 0
    else
        echo -e "${YELLOW}⏳ No healthy workers yet, will retry...${NC}"
        return 1
    fi
}

# Main execution with retry loop
echo -e "${YELLOW}🔄 Starting health check with auto-retry...${NC}"
echo

SUCCESS=false

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    REMAINING_MINUTES=$(( (MAX_ATTEMPTS - ATTEMPT + 1) * CHECK_INTERVAL / 60 ))
    echo -e "${CYAN}⏱️  Attempt $ATTEMPT/$MAX_ATTEMPTS (${REMAINING_MINUTES} min remaining)${NC}"
    
    if check_worker_health $ATTEMPT $MAX_ATTEMPTS; then
        SUCCESS=true
        break
    fi
    
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        echo -e "${YELLOW}⏳ Waiting ${CHECK_INTERVAL} seconds before next check...${NC}"
        echo
        sleep $CHECK_INTERVAL
    fi
    
    ((ATTEMPT++))
done

echo
echo -e "${BLUE}======================================${NC}"

if [ "$SUCCESS" = true ]; then
    echo -e "${GREEN}🎉 HEALTH CHECK SUCCESSFUL!${NC}"
    echo -e "${GREEN}Worker(s) are healthy and ready to process jobs${NC}"
    
    # Auto-detect and show next step
    if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
        source "$(dirname "$0")/next-step-helper.sh"
        show_next_step "$0" "$(dirname "$0")"
    fi
else
    echo -e "${RED}❌ HEALTH CHECK TIMEOUT${NC}"
    echo -e "${RED}Workers not healthy after ${MAX_WAIT_MINUTES} minutes${NC}"
    echo
    echo -e "${YELLOW}💡 Troubleshooting suggestions:${NC}"
    echo "1. Check cloud-init logs: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'sudo tail -50 /var/log/cloud-init-output.log'"
    echo "2. Check DLAMI setup logs: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'sudo tail -30 /var/log/dlami-worker-setup.log'"
    echo "3. Check worker logs: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'tail -30 /var/log/transcription-worker.log'"
    echo "4. Manually re-run health check: ./scripts/step-125-check-worker-health.sh"
    
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
