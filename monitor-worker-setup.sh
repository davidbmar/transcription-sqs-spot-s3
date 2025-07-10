#!/bin/bash

INSTANCE_IP="52.14.196.67"
INSTANCE_ID="i-03737064d4d91206e"
LAUNCH_TIME="2025-07-10T03:43:31Z"
KEY_FILE="transcription-worker-key-dev.pem"

echo "=================================="
echo "COMPREHENSIVE WORKER MONITORING"
echo "=================================="
echo "Instance: $INSTANCE_ID"
echo "IP: $INSTANCE_IP"
echo "Launch Time: $LAUNCH_TIME"
echo "Monitor Start: $(date -u)"
echo ""

# Function to calculate runtime
calculate_runtime() {
    python3 -c "
from datetime import datetime
import sys
launch = datetime(2025,7,10,3,43,31)
now = datetime.utcnow()
runtime_sec = (now - launch).total_seconds()
runtime_min = runtime_sec / 60
print(f'Runtime: {runtime_sec:.0f}s ({runtime_min:.1f}min)')
" 2>/dev/null || echo "Runtime calculation failed"
}

# Function to test SSH connectivity
test_ssh() {
    echo "[$(date -u +%H:%M:%S)] Testing SSH connectivity..."
    if timeout 10 ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$INSTANCE_IP 'echo "SSH OK"' 2>/dev/null; then
        echo "  ✅ SSH connection successful"
        return 0
    else
        echo "  ❌ SSH connection failed"
        return 1
    fi
}

# Function to check instance state
check_instance_state() {
    echo "[$(date -u +%H:%M:%S)] Checking instance state..."
    STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region us-east-2 --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
    echo "  Instance state: $STATE"
}

# Function to monitor cloud-init
monitor_cloud_init() {
    if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$INSTANCE_IP 'exit' 2>/dev/null; then
        echo "[$(date -u +%H:%M:%S)] Checking cloud-init status..."
        
        # Check cloud-init status
        CLOUD_INIT_STATUS=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'cloud-init status 2>/dev/null || echo "cloud-init command failed"')
        echo "  Cloud-init status: $CLOUD_INIT_STATUS"
        
        # Check if boot-finished exists
        if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; then
            echo "  ✅ Cloud-init boot-finished marker exists"
        else
            echo "  ⏳ Cloud-init boot-finished marker missing"
        fi
        
        # Check worker setup log
        echo "  Checking worker setup log..."
        ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'sudo tail -3 /var/log/worker-setup.log 2>/dev/null || echo "Worker setup log not found"' | sed 's/^/    /'
        
        # Check for key processes
        echo "  Checking for setup processes..."
        PROCESSES=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'ps aux | grep -E "(apt|pip|wget|curl)" | grep -v grep | wc -l' 2>/dev/null || echo "0")
        echo "    Active setup processes: $PROCESSES"
        
        # Check system load
        LOAD=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'uptime' 2>/dev/null || echo "Load check failed")
        echo "    System load: $LOAD"
        
        # Check disk space
        DISK=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'df -h / | tail -1' 2>/dev/null || echo "Disk check failed")
        echo "    Disk usage: $DISK"
        
        # Check if transcription worker service exists
        if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'systemctl status transcription-worker' >/dev/null 2>&1; then
            echo "  ✅ Transcription worker service exists"
            SERVICE_STATUS=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'systemctl is-active transcription-worker' 2>/dev/null)
            echo "    Service status: $SERVICE_STATUS"
        else
            echo "  ⏳ Transcription worker service not created yet"
        fi
    else
        echo "  ❌ Cannot connect via SSH to check cloud-init"
    fi
}

# Function to check for common failure indicators
check_failure_indicators() {
    echo "[$(date -u +%H:%M:%S)] Checking for failure indicators..."
    
    if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'exit' 2>/dev/null; then
        # Check for errors in cloud-init logs
        ERRORS=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'sudo grep -i error /var/log/cloud-init-output.log 2>/dev/null | wc -l' 2>/dev/null || echo "0")
        echo "  Errors in cloud-init log: $ERRORS"
        
        if [ "$ERRORS" -gt "0" ]; then
            echo "  Last few errors:"
            ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'sudo grep -i error /var/log/cloud-init-output.log 2>/dev/null | tail -3' | sed 's/^/    /'
        fi
        
        # Check for network issues
        NETWORK=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'ping -c1 google.com >/dev/null 2>&1 && echo "OK" || echo "FAILED"' 2>/dev/null)
        echo "  Network connectivity: $NETWORK"
        
        # Check available memory
        MEMORY=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'free -h | grep Mem:' 2>/dev/null || echo "Memory check failed")
        echo "  Memory status: $MEMORY"
    fi
}

# Main monitoring loop
echo "Starting monitoring loop..."
echo ""

for i in {1..60}; do  # Monitor for up to 10 minutes
    echo "=== MONITORING CYCLE $i ==="
    calculate_runtime
    check_instance_state
    
    if test_ssh; then
        monitor_cloud_init
        check_failure_indicators
        
        # Check if setup is complete
        if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'systemctl is-active transcription-worker' 2>/dev/null | grep -q "active"; then
            echo ""
            echo "🎉 SETUP COMPLETED SUCCESSFULLY!"
            echo "Final runtime: $(calculate_runtime)"
            echo "Worker service is active and running"
            exit 0
        fi
    fi
    
    echo "---"
    
    # Wait 10 seconds between checks
    sleep 10
done

echo ""
echo "⚠️ MONITORING TIMEOUT REACHED"
echo "Setup did not complete within 10 minutes"
calculate_runtime