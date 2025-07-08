#!/bin/bash

# launch-benchmark-worker.sh - Launch GPU instance specifically for benchmarking all transcriber strategies

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Configuration
REGION=${AWS_REGION}
INSTANCE_TYPE=${INSTANCE_TYPE}
AMI_ID="ami-0efd9a34b86a437e7"  # Standard Ubuntu 22.04 LTS
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
SPOT_PRICE=${SPOT_PRICE}
METRICS_BUCKET=${METRICS_BUCKET}

echo "🚀 LAUNCHING BENCHMARK GPU WORKER"
echo "Using GPU instance for comprehensive transcriber testing"

# Create user data script for benchmark testing
cat > /tmp/user-data-benchmark.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "🧪 BENCHMARK GPU WORKER SETUP"
echo "=========================================="
echo "Timestamp: $(date)"

# Update system
echo "📦 Installing system packages..."
apt-get update
apt-get install -y wget curl git ffmpeg python3-pip awscli

# Install NVIDIA drivers
echo "🎮 Installing NVIDIA drivers..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

echo "⏳ Waiting for NVIDIA drivers to initialize..."
sleep 30

# Install PyTorch with CUDA 12.1
echo "🔥 Installing PyTorch 2.5.1+cu121..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install all transcriber dependencies
echo "📚 Installing transcription libraries..."
pip3 install boto3 openai-whisper
pip3 install git+https://github.com/m-bain/whisperx.git
pip3 install faster-whisper

# Additional dependencies
pip3 install click librosa soundfile pydub

# Test GPU setup
echo "🧪 Testing GPU setup..."
python3 -c "
import torch
import whisper
try:
    import whisperx
    import faster_whisper
    print('✅ All transcriber libraries installed successfully')
    print(f'PyTorch version: {torch.__version__}')
    print(f'CUDA available: {torch.cuda.is_available()}')
    if torch.cuda.is_available():
        print(f'GPU name: {torch.cuda.get_device_name(0)}')
        print('🚀 Ready for benchmarking!')
except ImportError as e:
    print(f'❌ Import error: {e}')
" > /var/log/benchmark-setup.log 2>&1

# Create working directory
mkdir -p /opt/benchmark-test
cd /opt/benchmark-test

# Download benchmark code and test audio
echo "📥 Downloading benchmark code..."
wget -O transcriber_faster_whisper.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber_faster_whisper.py
wget -O transcriber_whisperx.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber_whisperx.py
wget -O transcriber_base_whisper.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/src/transcriber_base_whisper.py
wget -O benchmark-all-strategies.py https://raw.githubusercontent.com/davidbmar/transcription-sqs-spot-s3/main/scripts/benchmark-all-strategies.py

# Create .env file for benchmark script
cat > .env << ENVEOF
AWS_REGION=$REGION
METRICS_BUCKET=$METRICS_BUCKET
AUDIO_BUCKET=$AUDIO_BUCKET
ENVEOF

# Download test audio from S3
echo "📥 Downloading 81-minute podcast test file..."
mkdir -p integration-test-new
aws s3 cp s3://$AUDIO_BUCKET/integration-test-new/mfm-episode-723.mp3 integration-test-new/mfm-episode-723.mp3

echo "🧪 Starting comprehensive benchmark..."
echo "This will test FasterWhisper, WhisperX, and Base Whisper"
echo "Expected runtime: 60-90 minutes for all three tests"

# Run the benchmark
chmod +x benchmark-all-strategies.py
nohup python3 benchmark-all-strategies.py --upload-s3 > /var/log/benchmark-test.log 2>&1 &

echo "🎉 Benchmark started! Check /var/log/benchmark-test.log for progress"
echo "Results will be uploaded to S3 when complete"
EOF

# Create the spot instance request
echo "Launching benchmark GPU spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID"
echo "  Spot Price: $SPOT_PRICE"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data-benchmark.sh)

# Request spot instance
SPOT_REQUEST=$(aws ec2 request-spot-instances \
    --region "$REGION" \
    --spot-price "$SPOT_PRICE" \
    --instance-count 1 \
    --launch-specification "{
        \"ImageId\": \"$AMI_ID\",
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

echo "Benchmark spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for benchmark spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Benchmark spot instance launched: $INSTANCE_ID"

# Generate unique name with timestamp
BENCHMARK_NAME="benchmark-$(date +%m%d-%H%M)-$(echo $INSTANCE_ID | cut -c-8)"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=$BENCHMARK_NAME \
           Key=Type,Value=benchmark-worker \
           Key=Purpose,Value=transcriber-comparison

echo "🎉 Benchmark instance ready!"
echo "Instance ID: $INSTANCE_ID"
echo "Instance Name: $BENCHMARK_NAME"
echo ""
echo "📊 Benchmark Progress:"
echo "  Expected Duration: 60-90 minutes"
echo "  Testing: FasterWhisper, WhisperX, Base Whisper"
echo "  Test Audio: 81-minute podcast (65MB)"
echo ""
echo "🔍 Monitor Progress:"
echo "  SSH: ssh -i ${KEY_NAME}.pem ubuntu@<instance-ip>"
echo "  Logs: tail -f /var/log/benchmark-test.log"
echo "  Setup: tail -f /var/log/benchmark-setup.log"
echo ""
echo "📍 Get Instance IP:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"
echo ""
echo "📈 Results Location:"
echo "  S3 Bucket: s3://$METRICS_BUCKET/benchmarks/reports/"
echo "  Local CLI: ./transcription-monitor status"

# Cleanup
rm -f /tmp/user-data-benchmark.sh

echo ""
echo "🚀 Benchmark is running! Results will be available in S3 when complete."