#!/bin/bash

# step-225-docker-monitor-worker-health.sh - Health check for Docker GPU workers (PATH 200)

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
echo -e "${BLUE}Docker GPU Worker Health Check${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Check and fix SSH key permissions
if [ -f "${KEY_NAME}.pem" ]; then
    KEY_PERMS=$(stat -c '%a' "${KEY_NAME}.pem")
    if [ "$KEY_PERMS" != "600" ]; then
        echo -e "${YELLOW}[WARNING]${NC} SSH key permissions too open (${KEY_PERMS}). Fixing..."
        chmod 600 "${KEY_NAME}.pem"
        echo -e "${GREEN}[OK]${NC} SSH key permissions fixed"
    fi
else
    echo -e "${RED}[ERROR]${NC} SSH key file ${KEY_NAME}.pem not found"
    exit 1
fi

# Find running Docker workers
echo -e "${GREEN}[STEP 1]${NC} Finding Docker GPU workers..."

DOCKER_WORKERS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Type,Values=whisper-worker" \
        "Name=tag:Mode,Values=docker-gpu" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].[InstanceId,InstanceType,PublicIpAddress,Tags[?Key=='Name'].Value|[0]]" \
    --output text)

if [ -z "$DOCKER_WORKERS" ]; then
    echo -e "${RED}[ERROR]${NC} No Docker GPU workers found running"
    echo "Launch a worker with: ./scripts/step-220-launch-docker-gpu-worker.sh"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Found Docker GPU workers:"
echo "$DOCKER_WORKERS"
echo

# Function to check individual worker health
check_worker_health() {
    local instance_id=$1
    local instance_type=$2
    local instance_ip=$3
    local worker_name=$4
    
    echo -e "${CYAN}[HEALTH CHECK]${NC} Checking worker: $worker_name ($instance_id)"
    echo "Instance Type: $instance_type"
    echo "Public IP: $instance_ip"
    echo

    # Test SSH connectivity
    echo -e "${GREEN}[TEST 1]${NC} SSH connectivity..."
    if ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$instance_ip" 'echo "SSH OK"' >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} SSH connectivity working"
    else
        echo -e "${RED}[FAILED]${NC} SSH connectivity failed"
        return 1
    fi

    # Check Docker installation
    echo -e "${GREEN}[TEST 2]${NC} Docker installation..."
    DOCKER_VERSION=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker --version 2>/dev/null || echo "NOT_INSTALLED"')
    if [ "$DOCKER_VERSION" != "NOT_INSTALLED" ]; then
        echo -e "${GREEN}[OK]${NC} Docker installed: $DOCKER_VERSION"
    else
        echo -e "${RED}[FAILED]${NC} Docker not installed"
        return 1
    fi

    # Check GPU access
    echo -e "${GREEN}[TEST 3]${NC} GPU access..."
    GPU_STATUS=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'nvidia-smi >/dev/null 2>&1 && echo "OK" || echo "FAILED"')
    if [ "$GPU_STATUS" = "OK" ]; then
        echo -e "${GREEN}[OK]${NC} GPU access working"
        # Get GPU details
        GPU_INFO=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits')
        echo -e "${GREEN}[INFO]${NC} GPU: $GPU_INFO"
    else
        echo -e "${RED}[FAILED]${NC} GPU access failed"
        return 1
    fi

    # Check container status
    echo -e "${GREEN}[TEST 4]${NC} Container status..."
    CONTAINER_STATUS=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker ps --filter name=whisper-gpu-worker --format "{{.Status}}" 2>/dev/null || echo "NOT_RUNNING"')
    if [ "$CONTAINER_STATUS" != "NOT_RUNNING" ]; then
        echo -e "${GREEN}[OK]${NC} Container running: $CONTAINER_STATUS"
    else
        echo -e "${RED}[FAILED]${NC} Container not running"
        
        # Check if container exists but stopped
        STOPPED_CONTAINER=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker ps -a --filter name=whisper-gpu-worker --format "{{.Status}}" 2>/dev/null || echo "NOT_FOUND"')
        if [ "$STOPPED_CONTAINER" != "NOT_FOUND" ]; then
            echo -e "${YELLOW}[INFO]${NC} Found stopped container: $STOPPED_CONTAINER"
            echo -e "${YELLOW}[INFO]${NC} Container logs:"
            ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker logs whisper-gpu-worker --tail 10 2>/dev/null || echo "No logs available"'
        fi
        return 1
    fi

    # Check container GPU access
    echo -e "${GREEN}[TEST 5]${NC} Container GPU access..."
    CONTAINER_GPU=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker exec whisper-gpu-worker nvidia-smi >/dev/null 2>&1 && echo "OK" || echo "FAILED"')
    if [ "$CONTAINER_GPU" = "OK" ]; then
        echo -e "${GREEN}[OK]${NC} Container has GPU access"
    else
        echo -e "${RED}[FAILED]${NC} Container GPU access failed"
        return 1
    fi

    # Check worker process
    echo -e "${GREEN}[TEST 6]${NC} Worker process..."
    WORKER_PROCESS=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker exec whisper-gpu-worker ps aux | grep transcription_worker | grep -v grep | wc -l 2>/dev/null || echo "0"')
    if [ "$WORKER_PROCESS" -gt 0 ]; then
        echo -e "${GREEN}[OK]${NC} Worker process running"
        
        # Get worker memory usage
        WORKER_MEMORY=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker exec whisper-gpu-worker ps aux | grep transcription_worker | grep -v grep | awk "{print \$4}" 2>/dev/null || echo "0"')
        echo -e "${GREEN}[INFO]${NC} Worker memory usage: ${WORKER_MEMORY}%"
        
        # Check if models are loaded (high memory usage indicates loaded models)
        if [ "${WORKER_MEMORY%.*}" -gt 5 ]; then
            echo -e "${GREEN}[OK]${NC} Models appear to be loaded (high memory usage)"
        else
            echo -e "${YELLOW}[INFO]${NC} Models may still be loading (low memory usage)"
        fi
    else
        echo -e "${RED}[FAILED]${NC} Worker process not running"
        echo -e "${YELLOW}[INFO]${NC} Container logs:"
        ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" 'docker logs whisper-gpu-worker --tail 15 2>/dev/null || echo "No logs available"'
        return 1
    fi

    # Test queue connectivity
    echo -e "${GREEN}[TEST 7]${NC} Queue connectivity..."
    QUEUE_TEST=$(ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@"$instance_ip" "docker exec whisper-gpu-worker python3 -c \"
import boto3
try:
    sqs = boto3.client('sqs', region_name='$AWS_REGION')
    sqs.get_queue_attributes(QueueUrl='$QUEUE_URL', AttributeNames=['ApproximateNumberOfMessages'])
    print('OK')
except Exception as e:
    print(f'FAILED: {e}')
\"" 2>/dev/null || echo "FAILED")

    if [[ "$QUEUE_TEST" == "OK" ]]; then
        echo -e "${GREEN}[OK]${NC} Queue connectivity working"
    else
        echo -e "${RED}[FAILED]${NC} Queue connectivity failed: $QUEUE_TEST"
        return 1
    fi

    echo -e "${GREEN}[SUCCESS]${NC} Worker $worker_name is healthy!"
    echo
    return 0
}

# Check each worker
echo -e "${GREEN}[STEP 2]${NC} Performing health checks..."
echo

HEALTHY_WORKERS=0
TOTAL_WORKERS=0

while IFS=$'\t' read -r instance_id instance_type instance_ip worker_name; do
    if [ -n "$instance_id" ]; then
        TOTAL_WORKERS=$((TOTAL_WORKERS + 1))
        if check_worker_health "$instance_id" "$instance_type" "$instance_ip" "$worker_name"; then
            HEALTHY_WORKERS=$((HEALTHY_WORKERS + 1))
        fi
        echo "----------------------------------------"
    fi
done <<< "$DOCKER_WORKERS"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Health Check Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[SUMMARY]${NC}"
echo "Total workers: $TOTAL_WORKERS"
echo "Healthy workers: $HEALTHY_WORKERS"
echo "Failed workers: $((TOTAL_WORKERS - HEALTHY_WORKERS))"

if [ "$HEALTHY_WORKERS" -eq "$TOTAL_WORKERS" ] && [ "$TOTAL_WORKERS" -gt 0 ]; then
    echo -e "${GREEN}[STATUS]${NC} All workers are healthy! 🎉"
    echo
    echo -e "${GREEN}[NEXT STEPS]${NC}"
    echo "1. Test transcription: ./scripts/step-235-test-docker-workflow.sh"
    echo "2. Monitor workers: docker logs -f whisper-gpu-worker"
    exit 0
elif [ "$HEALTHY_WORKERS" -gt 0 ]; then
    echo -e "${YELLOW}[STATUS]${NC} Some workers are healthy, some have issues"
    exit 1
else
    echo -e "${RED}[STATUS]${NC} No healthy workers found"
    echo
    echo -e "${YELLOW}[TROUBLESHOOTING]${NC}"
    echo "1. Check instance logs: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'sudo tail -f /var/log/docker-worker-setup.log'"
    echo "2. Check container logs: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'docker logs whisper-gpu-worker'"
    echo "3. Restart container: ssh -i ${KEY_NAME}.pem ubuntu@<IP> 'docker restart whisper-gpu-worker'"
    exit 1
fi