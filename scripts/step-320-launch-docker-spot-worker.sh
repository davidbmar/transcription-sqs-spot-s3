#!/bin/bash
set -e

echo "============================================"
echo "🚀 Step 220: Launch Docker Worker on EC2"
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

# Check if previous steps completed
if ! grep -q "step-320-completed" .setup-status 2>/dev/null; then
    echo "❌ Error: step-211-push-to-ecr.sh must be run first."
    exit 1
fi

echo "🐳 Launching GPU-enabled EC2 instance with Docker worker..."
echo ""

# Create user data script for Docker worker
echo "📄 Creating user data script..."
cat > /tmp/docker-worker-userdata.sh << 'EOF'
#!/bin/bash
set -e

echo "🚀 STARTING DOCKER WORKER SETUP"
echo "================================="
echo ""

# Log everything
exec > >(tee -a /var/log/docker-worker-setup.log)
exec 2>&1

# Update system
echo "📦 Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install Docker
echo "🐳 Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

# Install AWS CLI v2
echo "☁️  Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
apt-get install -y unzip
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# Install NVIDIA Docker support
echo "🔧 Installing NVIDIA Docker support..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list

apt-get update
apt-get install -y nvidia-docker2
systemctl restart docker

# Install NVIDIA drivers
echo "🎮 Installing NVIDIA drivers..."
apt-get install -y nvidia-driver-470
modprobe nvidia

# Test NVIDIA setup
echo "🧪 Testing NVIDIA setup..."
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "✅ NVIDIA drivers installed successfully"
    nvidia-smi
else
    echo "⚠️  NVIDIA drivers not detected, will use CPU-only mode"
fi

# Test Docker with GPU
echo "🐳 Testing Docker GPU support..."
if docker run --rm --gpus all nvidia/cuda:11.8-base-ubuntu22.04 nvidia-smi 2>/dev/null; then
    echo "✅ Docker GPU support working"
else
    echo "⚠️  Docker GPU support not working, will use CPU-only mode"
fi

# Login to ECR
echo "🔐 Logging into ECR..."
aws ecr get-login-password --region REGION_PLACEHOLDER | docker login --username AWS --password-stdin ECR_URI_PLACEHOLDER

# Pull worker image
echo "📦 Pulling worker image..."
docker pull ECR_URI_PLACEHOLDER:latest

# Create health check script
echo "🏥 Creating health check script..."
cat > /home/ubuntu/health-check.sh << 'HEALTH_EOF'
#!/bin/bash
# Check if worker container is running and healthy
CONTAINER_ID=$(docker ps -q --filter "ancestor=ECR_URI_PLACEHOLDER:latest")
if [ -z "$CONTAINER_ID" ]; then
    echo "❌ Worker container not running"
    exit 1
fi

# Check container health
HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_ID" 2>/dev/null || echo "no-health")
if [ "$HEALTH_STATUS" = "healthy" ] || [ "$HEALTH_STATUS" = "no-health" ]; then
    echo "✅ Worker container is healthy"
    exit 0
else
    echo "⚠️  Worker container health: $HEALTH_STATUS"
    exit 1
fi
HEALTH_EOF

chmod +x /home/ubuntu/health-check.sh

# Create worker startup script
echo "🎵 Creating worker startup script..."
cat > /home/ubuntu/start-worker.sh << 'WORKER_EOF'
#!/bin/bash
set -e

echo "🚀 Starting WhisperX Docker Worker"
echo "================================="

# Stop any existing workers
docker stop $(docker ps -q --filter "ancestor=ECR_URI_PLACEHOLDER:latest") 2>/dev/null || true
docker rm $(docker ps -aq --filter "ancestor=ECR_URI_PLACEHOLDER:latest") 2>/dev/null || true

# Start worker with GPU support
CONTAINER_NAME="whisper-worker-$(date +%s)"
echo "🐳 Starting container: $CONTAINER_NAME"

if command -v nvidia-smi >/dev/null 2>&1; then
    echo "🎮 Using GPU acceleration"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --gpus all \
        --restart unless-stopped \
        -e AWS_REGION="REGION_PLACEHOLDER" \
        -e QUEUE_URL="QUEUE_URL_PLACEHOLDER" \
        -e AWS_ACCESS_KEY_ID="AWS_ACCESS_KEY_ID_PLACEHOLDER" \
        -e AWS_SECRET_ACCESS_KEY="AWS_SECRET_ACCESS_KEY_PLACEHOLDER" \
        -e AUDIO_BUCKET="AUDIO_BUCKET_PLACEHOLDER" \
        -e METRICS_BUCKET="METRICS_BUCKET_PLACEHOLDER" \
        -p 8080:8080 \
        ECR_URI_PLACEHOLDER:latest
else
    echo "💻 Using CPU-only mode"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -e AWS_REGION="REGION_PLACEHOLDER" \
        -e QUEUE_URL="QUEUE_URL_PLACEHOLDER" \
        -e AWS_ACCESS_KEY_ID="AWS_ACCESS_KEY_ID_PLACEHOLDER" \
        -e AWS_SECRET_ACCESS_KEY="AWS_SECRET_ACCESS_KEY_PLACEHOLDER" \
        -e AUDIO_BUCKET="AUDIO_BUCKET_PLACEHOLDER" \
        -e METRICS_BUCKET="METRICS_BUCKET_PLACEHOLDER" \
        -p 8080:8080 \
        ECR_URI_PLACEHOLDER:latest
fi

echo "✅ Worker started successfully!"
echo "   Container: $CONTAINER_NAME"
echo "   Health check: curl http://localhost:8080/health"
echo "   Logs: docker logs -f $CONTAINER_NAME"
WORKER_EOF

chmod +x /home/ubuntu/start-worker.sh

# Create idle timeout script
echo "⏰ Creating idle timeout script..."
cat > /home/ubuntu/idle-timeout.sh << 'IDLE_EOF'
#!/bin/bash
# Shut down instance if no jobs processed for X minutes
IDLE_TIMEOUT_MINUTES=IDLE_TIMEOUT_PLACEHOLDER

while true; do
    # Check if worker is processing jobs (placeholder logic)
    # In a real implementation, this would check queue metrics or worker logs
    sleep 300  # Check every 5 minutes
    
    # Simple idle detection - if no recent docker logs activity
    RECENT_LOGS=$(docker logs --since="5m" $(docker ps -q --filter "ancestor=ECR_URI_PLACEHOLDER:latest") 2>/dev/null | grep -c "Processing job" || echo "0")
    
    if [ "$RECENT_LOGS" -eq 0 ]; then
        echo "⏰ No recent job activity, shutting down instance..."
        sudo shutdown -h now
        break
    fi
done &
IDLE_EOF

chmod +x /home/ubuntu/idle-timeout.sh

# Set up cron job for health monitoring
echo "📊 Setting up health monitoring..."
crontab -l 2>/dev/null > /tmp/current_cron || echo "" > /tmp/current_cron
echo "*/5 * * * * /home/ubuntu/health-check.sh >> /var/log/health-check.log 2>&1" >> /tmp/current_cron
crontab /tmp/current_cron

# Start the worker
echo "🚀 Starting worker..."
/home/ubuntu/start-worker.sh

# Start idle timeout monitoring
echo "⏰ Starting idle timeout monitoring..."
/home/ubuntu/idle-timeout.sh

echo "✅ DOCKER WORKER SETUP COMPLETED!"
echo "================================="
echo "Instance is ready for transcription work."
EOF

# Replace placeholders with actual values
sed -i "s|REGION_PLACEHOLDER|$AWS_REGION|g" /tmp/docker-worker-userdata.sh
sed -i "s|ECR_URI_PLACEHOLDER|$ECR_REPOSITORY_URI|g" /tmp/docker-worker-userdata.sh
sed -i "s|QUEUE_URL_PLACEHOLDER|$QUEUE_URL|g" /tmp/docker-worker-userdata.sh
sed -i "s|AWS_ACCESS_KEY_ID_PLACEHOLDER|$AWS_ACCESS_KEY_ID|g" /tmp/docker-worker-userdata.sh
sed -i "s|AWS_SECRET_ACCESS_KEY_PLACEHOLDER|$AWS_SECRET_ACCESS_KEY|g" /tmp/docker-worker-userdata.sh
sed -i "s|AUDIO_BUCKET_PLACEHOLDER|$AUDIO_BUCKET|g" /tmp/docker-worker-userdata.sh
sed -i "s|METRICS_BUCKET_PLACEHOLDER|$METRICS_BUCKET|g" /tmp/docker-worker-userdata.sh
sed -i "s|IDLE_TIMEOUT_PLACEHOLDER|$IDLE_TIMEOUT_MINUTES|g" /tmp/docker-worker-userdata.sh

echo "✅ Created user data script with configuration"

# Launch spot instance
echo ""
echo "🚀 Launching spot instance..."
echo "  • Instance Type: $INSTANCE_TYPE"
echo "  • AMI: $AMI_ID"
echo "  • Max Price: $SPOT_PRICE"
echo "  • Key Name: $KEY_NAME"
echo ""

# Create launch specification
cat > /tmp/spot-launch-spec.json << EOF
{
    "ImageId": "$AMI_ID",
    "InstanceType": "$INSTANCE_TYPE",
    "KeyName": "$KEY_NAME",
    "SecurityGroupIds": ["$SECURITY_GROUP_ID"],
    "SubnetId": "$SUBNET_ID",
    "IamInstanceProfile": {
        "Name": "transcription-worker-profile"
    },
    "UserData": "$(base64 -w 0 /tmp/docker-worker-userdata.sh)"
}
EOF

# Launch on-demand instance (more reliable for GPU with driver issues)
echo "⚠️  Using On-Demand instance for GPU reliability (spot instances don't work well with NVIDIA driver reboots)"
INSTANCE_RESULT=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile Name="transcription-worker-profile" \
    --user-data file:///tmp/docker-worker-userdata.sh \
    --instance-initiated-shutdown-behavior terminate \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

INSTANCE_ID="$INSTANCE_RESULT"
echo "📋 On-Demand instance launched:"
echo "  • Instance ID: $INSTANCE_ID"
echo ""

# Wait for instance to be running
echo ""
echo "⏳ Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Tag the instance
echo "🏷️  Tagging instance..."
aws ec2 create-tags --resources "$INSTANCE_ID" --tags \
    Key=Name,Value="Docker-WhisperX-Worker-$(date +%Y%m%d-%H%M%S)" \
    Key=Type,Value="whisper-worker" \
    Key=DeploymentMethod,Value="docker" \
    Key=Environment,Value="$ENVIRONMENT" \
    --region "$AWS_REGION"

# Get current machine IP and update security group for health check access
echo ""
echo "🔍 Finding current machine IP address..."
CURRENT_IP=$(curl -s http://checkip.amazonaws.com)
echo "   Current IP: $CURRENT_IP"

echo "🔐 Updating security group to allow health check access..."
if aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 8080 \
    --cidr "$CURRENT_IP/32" \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "✅ Security group updated - port 8080 accessible from $CURRENT_IP"
else
    echo "ℹ️  Security group rule may already exist or failed to add"
fi

# Get instance details
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0]')

PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.PublicIpAddress // "N/A"')
PRIVATE_IP=$(echo "$INSTANCE_INFO" | jq -r '.PrivateIpAddress')
AZ=$(echo "$INSTANCE_INFO" | jq -r '.Placement.AvailabilityZone')

echo "✅ Instance is running!"
echo ""
echo "📊 Instance Details:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • Public IP: $PUBLIC_IP"
echo "  • Private IP: $PRIVATE_IP"
echo "  • Availability Zone: $AZ"
echo "  • Instance Type: $INSTANCE_TYPE"
echo ""

# Create connection script
echo "📄 Creating connection script..."
cat > connect-to-docker-worker.sh << EOF
#!/bin/bash
echo "🔗 Connecting to Docker worker..."
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "Commands to run:"
echo "  • Check setup: sudo tail -f /var/log/docker-worker-setup.log"
echo "  • Check worker: docker logs -f \$(docker ps -q --filter 'ancestor=$ECR_REPOSITORY_URI:latest')"
echo "  • Health check: curl http://localhost:8080/health"
echo "  • Health logs: sudo tail -f /var/log/health-check.log"
echo ""
ssh -i "$KEY_NAME.pem" ubuntu@$PUBLIC_IP
EOF

chmod +x connect-to-docker-worker.sh

echo "✅ Created connection script: ./connect-to-docker-worker.sh"

# Clean up temporary files
rm -f /tmp/docker-worker-userdata.sh /tmp/spot-launch-spec.json

echo ""
echo "🎉 Docker worker launch completed!"
echo ""
echo "📊 Summary:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • Public IP: $PUBLIC_IP"
echo "  • Docker Image: $ECR_REPOSITORY_URI:latest"
echo "  • Health Check: http://$PUBLIC_IP:8080/health"
echo ""
echo "📋 Next steps:"
echo "  1. Wait 5-10 minutes for Docker setup to complete"
echo "  2. Connect: ./connect-to-docker-worker.sh"
echo "  3. Monitor: ./scripts/step-225-check-docker-health.sh"
echo "  4. Submit jobs: python3 send_to_queue.py"
echo ""
echo "🔍 Monitor setup progress:"
echo "  ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'sudo tail -f /var/log/docker-worker-setup.log'"
echo ""

# Update setup status
echo "step-320-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
echo "docker-worker-instance-id=$INSTANCE_ID" >> .setup-status
echo "docker-worker-public-ip=$PUBLIC_IP" >> .setup-status