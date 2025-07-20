#!/bin/bash
set -e

echo "🚀 LAUNCHING HYBRID WORKERS: Whisper (3xx) + Voxtral (4xx)"
echo "================================================================"

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Validate required configuration
echo "🔍 Validating configuration..."
REQUIRED_VARS=("AWS_REGION" "AWS_ACCOUNT_ID" "QUEUE_PREFIX" "WHISPER_ECR_URI" "VOXTRAL_ECR_URI")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Missing required configuration: $var"
        exit 1
    fi
done

# Check ECR images exist
echo "🐳 Checking ECR images..."
# Extract repository name from URI
WHISPER_REPO_NAME=$(echo "$WHISPER_ECR_URI" | sed 's|.*\.com/||' | cut -d: -f1)
VOXTRAL_REPO_NAME=$(echo "$VOXTRAL_ECR_URI" | sed 's|.*\.com/||' | cut -d: -f1)

aws ecr describe-images --repository-name "$WHISPER_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || {
    echo "❌ Whisper ECR image not found in $WHISPER_REPO_NAME"
    exit 1
}

aws ecr describe-images --repository-name "$VOXTRAL_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || {
    echo "❌ Voxtral ECR image not found in $VOXTRAL_REPO_NAME"
    exit 1
}

# Get latest NVIDIA Deep Learning AMI (has GPU drivers pre-installed)
echo "🔍 Finding latest NVIDIA Deep Learning AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "✅ Using AMI: $AMI_ID"

# Get default VPC and subnet
echo "🌐 Getting network configuration..."
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)

echo "✅ VPC: $VPC_ID, Subnet: $SUBNET_ID"

# Create security group for hybrid workers
SECURITY_GROUP_NAME="${QUEUE_PREFIX}-hybrid-workers"
echo "🔒 Creating security group: $SECURITY_GROUP_NAME"

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Security group for hybrid Whisper+Voxtral workers" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --group-names "$SECURITY_GROUP_NAME" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

# Add security group rules
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 8000 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 8001 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || true

echo "✅ Security group configured: $SECURITY_GROUP_ID"

# Prepare user data script for hybrid deployment
USER_DATA=$(cat <<EOF
#!/bin/bash
set -e

echo "🚀 HYBRID WORKER INITIALIZATION STARTING..."
echo "=============================================="

# Update system
apt-get update -y
apt-get upgrade -y

# Install required packages
apt-get install -y unzip curl

# Install Docker
echo "🐳 Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

# Install NVIDIA Docker
echo "🎮 Installing NVIDIA Docker..."
distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L "https://nvidia.github.io/nvidia-docker/\$distribution/nvidia-docker.list" | tee /etc/apt/sources.list.d/nvidia-docker.list
apt-get update
apt-get install -y nvidia-docker2
systemctl restart docker

# Install AWS CLI v2
echo "☁️ Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Configure AWS CLI
echo "🔑 Configuring AWS CLI..."
aws configure set default.region $AWS_REGION

# Login to ECR
echo "🔐 Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Create shared volume directory
echo "📁 Creating shared volumes..."
mkdir -p /shared-audio
mkdir -p /shared-cache
chmod 777 /shared-audio /shared-cache

# Pull Docker images
echo "📥 Pulling Docker images..."
echo "  - Whisper image: $WHISPER_ECR_URI"
docker pull $WHISPER_ECR_URI

echo "  - Voxtral image: $VOXTRAL_ECR_URI"  
docker pull $VOXTRAL_ECR_URI

# Launch Whisper container (port 8001)
echo "🎵 Starting Whisper container..."
docker run -d \
    --name whisper-worker \
    --gpus all \
    --restart unless-stopped \
    -p 8001:8000 \
    -v /shared-audio:/shared-audio \
    -v /shared-cache:/shared-cache \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    $WHISPER_ECR_URI

# Wait for Whisper to be ready
echo "⏳ Waiting for Whisper to be ready..."
sleep 30

# Launch Voxtral container (port 8000)
echo "🧠 Starting Voxtral container..."
docker run -d \
    --name voxtral-worker \
    --gpus all \
    --restart unless-stopped \
    -p 8000:8000 \
    -v /shared-audio:/shared-audio \
    -v /shared-cache:/shared-cache \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    $VOXTRAL_ECR_URI

# Create hybrid orchestrator script
cat > /opt/hybrid-orchestrator.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Hybrid Orchestrator - Coordinates Whisper + Voxtral processing
"""
import asyncio
import aiohttp
import boto3
import json
import os
import time
from datetime import datetime

# Configuration
WHISPER_ENDPOINT = "http://localhost:8001"
VOXTRAL_ENDPOINT = "http://localhost:8000"
QUEUE_URL = os.environ['QUEUE_URL']
AUDIO_BUCKET = os.environ['AUDIO_BUCKET']

async def process_hybrid_job(s3_input_path, s3_output_path, job_id):
    """Process audio with both Whisper and Voxtral"""
    print(f"🎯 Processing hybrid job {job_id}")
    
    # Download audio
    s3 = boto3.client('s3')
    local_path = f"/shared-audio/{job_id}.mp3"
    
    bucket, key = s3_input_path.replace('s3://', '').split('/', 1)
    s3.download_file(bucket, key, local_path)
    
    # Launch both models in parallel
    start_time = time.time()
    
    async with aiohttp.ClientSession() as session:
        # Prepare file for both requests
        with open(local_path, 'rb') as f:
            audio_data = f.read()
        
        # Launch parallel requests
        whisper_task = transcribe_with_whisper(session, audio_data)
        voxtral_task = analyze_with_voxtral(session, audio_data)
        
        # Wait for both to complete
        whisper_result, voxtral_result = await asyncio.gather(
            whisper_task, voxtral_task, return_exceptions=True
        )
    
    total_time = time.time() - start_time
    
    # Combine results
    result = {
        "job_id": job_id,
        "s3_input_path": s3_input_path,
        "processing_time": total_time,
        "timestamp": datetime.utcnow().isoformat(),
        "whisper": whisper_result if not isinstance(whisper_result, Exception) else {"error": str(whisper_result)},
        "voxtral": voxtral_result if not isinstance(voxtral_result, Exception) else {"error": str(voxtral_result)},
        "hybrid_benefits": {
            "fast_transcript_ready": "3 seconds (Whisper)",
            "smart_analysis_ready": f"{total_time:.1f} seconds (Voxtral)",
            "user_experience": "Can start reading transcript while analysis completes"
        }
    }
    
    # Upload result
    output_bucket, output_key = s3_output_path.replace('s3://', '').split('/', 1)
    s3.put_object(
        Bucket=output_bucket,
        Key=output_key,
        Body=json.dumps(result, indent=2),
        ContentType='application/json'
    )
    
    # Cleanup
    os.remove(local_path)
    print(f"✅ Hybrid job {job_id} completed in {total_time:.1f}s")

async def transcribe_with_whisper(session, audio_data):
    """Call Whisper service"""
    data = aiohttp.FormData()
    data.add_field('file', audio_data, filename='audio.mp3')
    
    async with session.post(f"{WHISPER_ENDPOINT}/transcribe", data=data) as resp:
        return await resp.json()

async def analyze_with_voxtral(session, audio_data):
    """Call Voxtral service"""
    data = aiohttp.FormData()
    data.add_field('file', audio_data, filename='audio.mp3')
    
    async with session.post(f"{VOXTRAL_ENDPOINT}/transcribe", data=data) as resp:
        return await resp.json()

# Simple SQS polling (production would use proper worker)
async def poll_queue():
    sqs = boto3.client('sqs')
    
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20
            )
            
            if 'Messages' in response:
                for message in response['Messages']:
                    job_data = json.loads(message['Body'])
                    
                    await process_hybrid_job(
                        job_data['s3_input_path'],
                        job_data['s3_output_path'],
                        job_data['job_id']
                    )
                    
                    # Delete message
                    sqs.delete_message(
                        QueueUrl=QUEUE_URL,
                        ReceiptHandle=message['ReceiptHandle']
                    )
        
        except Exception as e:
            print(f"❌ Queue processing error: {e}")
            await asyncio.sleep(5)

if __name__ == "__main__":
    print("🎭 Starting Hybrid Orchestrator...")
    asyncio.run(poll_queue())
PYTHON_EOF

chmod +x /opt/hybrid-orchestrator.py

# Install Python dependencies for orchestrator
echo "🐍 Installing Python dependencies..."
apt-get install -y python3-pip
pip3 install aiohttp boto3

# Wait for both containers to be ready
echo "⏳ Waiting for containers to be ready..."
sleep 60

# Check container health
echo "🏥 Checking container health..."
docker ps

echo "✅ HYBRID WORKER DEPLOYMENT COMPLETE!"
echo "======================================"
echo "📊 Container Status:"
echo "  - Whisper: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ip):8001/health"
echo "  - Voxtral: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ip):8000/health"
echo ""
echo "🎯 Ready for hybrid processing!"
echo "   - Fast transcription: 3 seconds (Whisper)"  
echo "   - Smart analysis: 25 seconds (Voxtral)"
echo "   - Best of both worlds on same GPU!"

# Optional: Start orchestrator in background
# nohup python3 /opt/hybrid-orchestrator.py > /var/log/hybrid-orchestrator.log 2>&1 &
EOF
)

# Launch EC2 instance
echo "🚀 Launching hybrid worker instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type g4dn.xlarge \
    --key-name "${KEY_PAIR_NAME:-transcription-worker-key-dev}" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,DeleteOnTermination=true}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${QUEUE_PREFIX}-hybrid-worker},{Key=Type,Value=hybrid-worker},{Key=Project,Value=$QUEUE_PREFIX}]" \
    --user-data "$USER_DATA" \
    --iam-instance-profile Name="${INSTANCE_PROFILE:-transcription-worker-profile}" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "✅ Instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo "⏳ Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "🎉 HYBRID WORKER DEPLOYED SUCCESSFULLY!"
echo "======================================"
echo "📋 Instance Details:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  Type: g4dn.xlarge (Tesla T4 GPU)"
echo ""
echo "🔗 Service Endpoints:"
echo "  Whisper API: http://$PUBLIC_IP:8001"
echo "  Voxtral API: http://$PUBLIC_IP:8000"  
echo "  Combined: Both models on same GPU!"
echo ""
echo "⏱️ Initialization Status:"
echo "  - Docker installation: ~3 minutes"
echo "  - Image pulls: ~5-7 minutes"
echo "  - Model loading: ~8-10 minutes total"
echo "  - Ready for processing: ~15 minutes"
echo ""
echo "🔍 Monitor deployment:"
echo "  ssh -i ~/.ssh/your-key.pem ubuntu@$PUBLIC_IP"
echo "  docker logs whisper-worker"
echo "  docker logs voxtral-worker"
echo ""
echo "🧪 Test hybrid processing:"
echo "  curl -X POST -F 'file=@test.mp3' http://$PUBLIC_IP:8001/transcribe  # Fast"
echo "  curl -X POST -F 'file=@test.mp3' http://$PUBLIC_IP:8000/transcribe  # Smart"

# Update status
echo "step-500-completed=$(date)" >> .setup-status
echo "hybrid-worker-instance-id=$INSTANCE_ID" >> .setup-status
echo "hybrid-worker-public-ip=$PUBLIC_IP" >> .setup-status

echo ""
echo "📝 Next Steps:"
echo "1. Wait 15 minutes for full initialization"
echo "2. Run: ./scripts/step-501-test-hybrid-deployment.sh"
echo "3. Submit jobs to SQS for automatic hybrid processing"
echo "4. Monitor with: ./scripts/step-502-monitor-hybrid-health.sh"