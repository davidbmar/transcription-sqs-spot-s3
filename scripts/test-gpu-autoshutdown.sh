#!/bin/bash

# test-gpu-autoshutdown.sh - Test GPU Worker Auto-Shutdown (2 minute timeout)
# This tests that the worker properly shuts down when idle

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

echo "🧪 TESTING GPU WORKER AUTO-SHUTDOWN (2 MINUTE TIMEOUT)"
echo "This will launch a GPU worker that shuts down after 2 minutes of no activity"

# Create test user data with SHORT timeout for testing
cat > /tmp/user-data-test-shutdown.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "🧪 TEST GPU WORKER SETUP (2 MIN SHUTDOWN)"
echo "=========================================="
echo "Timestamp: $(date)"

# Quick system update
apt-get update
apt-get install -y wget curl git ffmpeg python3-pip awscli

# Install NVIDIA drivers
echo "🎮 Installing NVIDIA drivers..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall
sleep 30

# Install PyTorch with CUDA
echo "🔥 Installing PyTorch..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install transcription dependencies
echo "📚 Installing dependencies..."
pip3 install boto3 openai-whisper
pip3 install git+https://github.com/m-bain/whisperx.git

# Test GPU
echo "🧪 Testing GPU..."
if nvidia-smi; then
    echo "✅ GPU working!" | tee /var/log/test-result.log
    GPU_MODE=""
else
    echo "❌ GPU failed!" | tee /var/log/test-result.log  
    GPU_MODE="--cpu-only"
fi

# Download worker files
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker
wget -O transcription_worker.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcription_worker.py
wget -O queue_metrics.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/queue_metrics.py
wget -O transcriber.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber.py

# Start worker with 2 MINUTE timeout for testing
echo "🚀 STARTING WORKER WITH 2 MINUTE AUTO-SHUTDOWN TEST" | tee -a /var/log/test-result.log
echo "Worker will auto-shutdown after 2 minutes of no queue activity" | tee -a /var/log/test-result.log

nohup python3 transcription_worker.py \
    --queue-url "$QUEUE_URL" \
    --s3-bucket "$METRICS_BUCKET" \
    --region "$REGION" \
    --model base \
    --idle-timeout 2 \
    $GPU_MODE > /var/log/transcription-worker.log 2>&1 &

echo "✅ Test worker started! Will shutdown in 2 minutes if no jobs." | tee -a /var/log/test-result.log
EOF

# Launch test instance
USER_DATA=$(base64 -w 0 < /tmp/user-data-test-shutdown.sh)

SPOT_REQUEST=$(aws ec2 request-spot-instances \
    --region "$AWS_REGION" \
    --spot-price "$SPOT_PRICE" \
    --instance-count 1 \
    --launch-specification "{
        \"ImageId\": \"ami-0efd9a34b86a437e7\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"KeyName\": \"$KEY_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$USER_DATA\",
        \"IamInstanceProfile\": {
            \"Name\": \"transcription-worker-profile\"
        }
    }" \
    --query 'SpotInstanceRequests[0].SpotInstanceRequestId' \
    --output text)

echo "Test GPU instance request: $SPOT_REQUEST"

# Wait for launch
aws ec2 wait spot-instance-request-fulfilled \
    --region "$AWS_REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$AWS_REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "🧪 Test instance launched: $INSTANCE_ID"

# Tag it
aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=test-gpu-autoshutdown \
           Key=Type,Value=test \
           Key=AutoShutdown,Value=2min

echo ""
echo "🧪 AUTO-SHUTDOWN TEST ACTIVE"
echo "================================"
echo "Instance ID: $INSTANCE_ID"
echo "Test: Worker should auto-shutdown after 2 minutes of no queue activity"
echo ""
echo "To monitor the test:"
echo "  # Watch instance state (should go from 'running' to 'shutting-down' in ~5 minutes)"
echo "  watch 'aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query \"Reservations[0].Instances[0].State.Name\" --output text'"
echo ""
echo "  # Get instance IP to check logs:"
echo "  aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"
echo ""
echo "Expected timeline:"
echo "  0-3 min: Instance starting, installing dependencies"
echo "  3-5 min: Worker starts, begins idle timer"  
echo "  5-7 min: Worker detects 2 minutes idle, initiates shutdown"
echo "  7-8 min: Instance state becomes 'shutting-down'"

# Cleanup
rm -f /tmp/user-data-test-shutdown.sh