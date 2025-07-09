#!/bin/bash
set -e

echo "============================================"
echo "🏥 Step 225: Check Docker Worker Health"
echo "============================================"
echo ""

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check if Docker worker was launched
if ! grep -q "step-220-completed" .setup-status 2>/dev/null; then
    echo "❌ Error: step-220-launch-docker-worker.sh must be run first."
    exit 1
fi

# Get worker instance information
WORKER_INSTANCE_ID=$(grep "docker-worker-instance-id" .setup-status 2>/dev/null | cut -d'=' -f2)
WORKER_PUBLIC_IP=$(grep "docker-worker-public-ip" .setup-status 2>/dev/null | cut -d'=' -f2)

if [ -z "$WORKER_INSTANCE_ID" ] || [ -z "$WORKER_PUBLIC_IP" ]; then
    echo "❌ Error: Could not find worker instance information in .setup-status"
    echo "   Please run step-220-launch-docker-worker.sh first."
    exit 1
fi

echo "🔍 Checking Docker worker health..."
echo "  • Instance ID: $WORKER_INSTANCE_ID"
echo "  • Public IP: $WORKER_PUBLIC_IP"
echo ""

# Function to check SSH connectivity
check_ssh_connectivity() {
    echo "🔗 Testing SSH connectivity..."
    if timeout 10 ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$WORKER_PUBLIC_IP" 'echo "SSH OK"' >/dev/null 2>&1; then
        echo "✅ SSH connectivity: OK"
        return 0
    else
        echo "❌ SSH connectivity: FAILED"
        return 1
    fi
}

# Function to check EC2 instance status
check_ec2_status() {
    echo "🖥️  Checking EC2 instance status..."
    
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$WORKER_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null)
    
    if [ "$INSTANCE_STATE" = "running" ]; then
        echo "✅ EC2 instance status: $INSTANCE_STATE"
        return 0
    else
        echo "❌ EC2 instance status: $INSTANCE_STATE"
        return 1
    fi
}

# Function to check Docker daemon
check_docker_daemon() {
    echo "🐳 Checking Docker daemon..."
    
    if ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" 'sudo systemctl is-active docker' >/dev/null 2>&1; then
        echo "✅ Docker daemon: Running"
        return 0
    else
        echo "❌ Docker daemon: Not running"
        return 1
    fi
}

# Function to check Docker containers
check_docker_containers() {
    echo "📦 Checking Docker containers..."
    
    CONTAINERS=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
        "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'ancestor=$ECR_REPOSITORY_URI:latest'" 2>/dev/null)
    
    if [ -n "$CONTAINERS" ] && [ "$CONTAINERS" != "NAMES	STATUS	PORTS" ]; then
        echo "✅ Docker containers:"
        echo "$CONTAINERS" | while read line; do
            echo "   $line"
        done
        
        # Get container name for health check
        CONTAINER_NAME=$(echo "$CONTAINERS" | tail -n 1 | awk '{print $1}')
        echo "CONTAINER_NAME=$CONTAINER_NAME" > /tmp/container_info
        return 0
    else
        echo "❌ No Docker containers running"
        return 1
    fi
}

# Function to check container health
check_container_health() {
    echo "🏥 Checking container health..."
    
    # Source container info from previous check
    if [ -f /tmp/container_info ]; then
        source /tmp/container_info
    else
        echo "❌ Container information not available"
        return 1
    fi
    
    # Check Docker health status
    HEALTH_STATUS=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
        "docker inspect --format='{{.State.Health.Status}}' '$CONTAINER_NAME'" 2>/dev/null || echo "no-health")
    
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        echo "✅ Container health: $HEALTH_STATUS"
    elif [ "$HEALTH_STATUS" = "no-health" ]; then
        echo "ℹ️  Container health: Not configured"
    else
        echo "⚠️  Container health: $HEALTH_STATUS"
    fi
    
    # Check container logs for recent activity
    echo "📋 Recent container activity:"
    RECENT_LOGS=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
        "docker logs --since=5m '$CONTAINER_NAME' 2>&1 | tail -5" 2>/dev/null || echo "No recent logs")
    
    if [ -n "$RECENT_LOGS" ]; then
        echo "$RECENT_LOGS" | while read line; do
            echo "   $line"
        done
    else
        echo "   No recent activity"
    fi
}

# Function to check health endpoint
check_health_endpoint() {
    echo "🌐 Checking health endpoint..."
    
    if timeout 10 curl -s "http://$WORKER_PUBLIC_IP:8080/health" >/tmp/health_response 2>&1; then
        echo "✅ Health endpoint: Accessible"
        
        # Parse health response
        if command -v jq >/dev/null; then
            echo "📊 Health details:"
            cat /tmp/health_response | jq -r '. | to_entries[] | "   \(.key): \(.value)"' 2>/dev/null || {
                echo "   Raw response: $(cat /tmp/health_response)"
            }
        else
            echo "   Response: $(cat /tmp/health_response)"
        fi
        
        rm -f /tmp/health_response
        return 0
    else
        echo "❌ Health endpoint: Not accessible"
        echo "   Error: $(cat /tmp/health_response 2>/dev/null || echo 'Connection failed')"
        rm -f /tmp/health_response
        return 1
    fi
}

# Function to check GPU availability
check_gpu_availability() {
    echo "🎮 Checking GPU availability..."
    
    # Check if GPU is available on host
    GPU_HOST=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
        'nvidia-smi --query-gpu=name --format=csv,noheader,nounits' 2>/dev/null || echo "")
    
    if [ -n "$GPU_HOST" ]; then
        echo "✅ Host GPU: $GPU_HOST"
        
        # Check if GPU is available in container
        if [ -f /tmp/container_info ]; then
            source /tmp/container_info
            GPU_CONTAINER=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
                "docker exec '$CONTAINER_NAME' nvidia-smi --query-gpu=name --format=csv,noheader,nounits" 2>/dev/null || echo "")
            
            if [ -n "$GPU_CONTAINER" ]; then
                echo "✅ Container GPU: $GPU_CONTAINER"
            else
                echo "⚠️  Container GPU: Not accessible (will use CPU)"
            fi
        fi
    else
        echo "⚠️  Host GPU: Not available (using CPU mode)"
    fi
}

# Function to check queue connectivity
check_queue_connectivity() {
    echo "📬 Checking SQS queue connectivity..."
    
    if [ -f /tmp/container_info ]; then
        source /tmp/container_info
        
        # Test queue access from container
        QUEUE_TEST=$(ssh -i "$KEY_NAME.pem" -o StrictHostKeyChecking=no ubuntu@"$WORKER_PUBLIC_IP" \
            "docker exec '$CONTAINER_NAME' aws sqs get-queue-attributes --queue-url '$QUEUE_URL' --attribute-names ApproximateNumberOfMessages --region '$AWS_REGION'" 2>/dev/null || echo "FAILED")
        
        if [ "$QUEUE_TEST" != "FAILED" ]; then
            echo "✅ Queue connectivity: OK"
            
            # Show queue depth if jq is available
            if command -v jq >/dev/null; then
                MSG_COUNT=$(echo "$QUEUE_TEST" | jq -r '.Attributes.ApproximateNumberOfMessages // "N/A"')
                echo "   Messages in queue: $MSG_COUNT"
            fi
        else
            echo "❌ Queue connectivity: FAILED"
        fi
    else
        echo "⚠️  Queue connectivity: Cannot test (no container info)"
    fi
}

# Function to show diagnostics
show_diagnostics() {
    echo ""
    echo "🔍 Diagnostics and Troubleshooting:"
    echo ""
    
    echo "📋 Useful commands:"
    echo "  • SSH to worker: ssh -i $KEY_NAME.pem ubuntu@$WORKER_PUBLIC_IP"
    echo "  • Check setup logs: sudo tail -f /var/log/docker-worker-setup.log"
    echo "  • Check container logs: docker logs -f \$(docker ps -q --filter 'ancestor=$ECR_REPOSITORY_URI:latest')"
    echo "  • Health check: curl http://$WORKER_PUBLIC_IP:8080/health"
    echo "  • Container shell: docker exec -it \$(docker ps -q --filter 'ancestor=$ECR_REPOSITORY_URI:latest') bash"
    echo ""
    
    echo "🚨 Common issues:"
    echo "  • Health endpoint not accessible: Check security group port 8080"
    echo "  • Container not running: Check Docker logs for startup errors"
    echo "  • GPU not working: Check NVIDIA driver installation"
    echo "  • Queue access failed: Check IAM permissions and credentials"
    echo ""
}

# Main health check sequence
echo "🏥 Starting comprehensive Docker worker health check..."
echo ""

# Track overall health
OVERALL_HEALTH=0

# Run all checks
if ! check_ec2_status; then
    OVERALL_HEALTH=1
fi

if ! check_ssh_connectivity; then
    OVERALL_HEALTH=1
    echo ""
    echo "❌ Cannot proceed with detailed checks - SSH connectivity failed"
    echo "   Instance may still be initializing or there may be network issues"
    show_diagnostics
    exit 1
fi

if ! check_docker_daemon; then
    OVERALL_HEALTH=1
fi

if ! check_docker_containers; then
    OVERALL_HEALTH=1
fi

if [ $OVERALL_HEALTH -eq 0 ]; then
    check_container_health
    check_health_endpoint
    check_gpu_availability
    check_queue_connectivity
fi

# Summary
echo ""
echo "============================================"
if [ $OVERALL_HEALTH -eq 0 ]; then
    echo "✅ Docker Worker Health Check: PASSED"
    echo ""
    echo "🎉 Worker is healthy and ready for transcription jobs!"
    echo "   • Instance: $WORKER_INSTANCE_ID"
    echo "   • Health URL: http://$WORKER_PUBLIC_IP:8080/health"
    echo "   • Queue: $QUEUE_URL"
else
    echo "❌ Docker Worker Health Check: FAILED"
    echo ""
    echo "⚠️  Worker has issues that need attention."
fi
echo "============================================"

show_diagnostics

# Clean up temporary files
rm -f /tmp/container_info /tmp/health_response

# Update status
echo ""
echo "step-225-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status

exit $OVERALL_HEALTH