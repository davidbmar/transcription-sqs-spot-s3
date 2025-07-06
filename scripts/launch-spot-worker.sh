#!/bin/bash

# launch-spot-worker.sh - Launch EC2 Spot Instance for Transcription Worker

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Configuration from .env file
REGION=${AWS_REGION}
INSTANCE_TYPE=${INSTANCE_TYPE}
AMI_ID=${AMI_ID}
SUBNET_ID=${SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
S3_BUCKET=${AUDIO_BUCKET}  # Use AUDIO_BUCKET from .env
SPOT_PRICE=${SPOT_PRICE}

# Required parameters check
if [ -z "$QUEUE_URL" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: QUEUE_URL and S3_BUCKET environment variables are required"
    echo "Usage: QUEUE_URL=<queue-url> S3_BUCKET=<bucket> ./launch-spot-worker.sh"
    exit 1
fi

# Create user data script
cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y docker.io python3-pip awscli git

# Install NVIDIA drivers and Docker GPU support
apt-get install -y nvidia-driver-525 nvidia-docker2
systemctl restart docker

# Install Python packages
pip3 install boto3 torch torchaudio transformers

# Create working directory
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Clone or download the transcription worker code
# (In production, you'd download from S3 or a Git repo)
cat > transcription_worker.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import os
import sys
import argparse
import json
import boto3
import logging
import time
import uuid
import signal
import subprocess
from datetime import datetime
from typing import Dict
from urllib.parse import urlparse

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class SimpleTranscriptionWorker:
    def __init__(self, queue_url, s3_bucket, region="us-east-1"):
        self.queue_url = queue_url
        self.s3_bucket = s3_bucket
        self.region = region
        self.worker_id = f"worker-{uuid.uuid4()}"
        self.s3 = boto3.client('s3', region_name=region)
        self.sqs = boto3.client('sqs', region_name=region)
        self.shutdown_requested = False
        self.idle_start = None
        self.idle_threshold = 300  # 5 minutes
        
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
    def signal_handler(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.shutdown_requested = True
        
    def should_continue_running(self):
        if self.shutdown_requested:
            return False
            
        # Check queue depth
        try:
            attrs = self.sqs.get_queue_attributes(
                QueueUrl=self.queue_url,
                AttributeNames=['ApproximateNumberOfMessages']
            )
            queue_size = int(attrs['Attributes']['ApproximateNumberOfMessages'])
            
            if queue_size == 0:
                if self.idle_start is None:
                    self.idle_start = time.time()
                elif time.time() - self.idle_start > self.idle_threshold:
                    logger.info("Idle timeout reached, shutting down")
                    return False
            else:
                self.idle_start = None
                
        except Exception as e:
            logger.error(f"Error checking queue: {e}")
            
        return True
        
    def download_audio(self, s3_path):
        parsed = urlparse(s3_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        filename = os.path.basename(key)
        local_path = f"/tmp/{self.worker_id}_{filename}"
        
        logger.info(f"Downloading {s3_path} to {local_path}")
        self.s3.download_file(bucket, key, local_path)
        return local_path
        
    def upload_transcript(self, local_path, s3_path):
        parsed = urlparse(s3_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        
        logger.info(f"Uploading transcript to {s3_path}")
        self.s3.upload_file(local_path, bucket, key)
        
    def transcribe_with_whisper(self, audio_path):
        """Simple transcription using whisper Docker container"""
        output_dir = "/tmp/whisper_output"
        os.makedirs(output_dir, exist_ok=True)
        
        # Use whisper via Docker
        cmd = [
            "docker", "run", "--rm", "--gpus", "all",
            "-v", f"{audio_path}:/audio:ro",
            "-v", f"{output_dir}:/output",
            "openai/whisper:latest",
            "--model", "large-v3",
            "--output_format", "json",
            "--output_dir", "/output",
            "/audio"
        ]
        
        logger.info(f"Running whisper transcription: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            raise Exception(f"Whisper failed: {result.stderr}")
            
        # Find the output JSON file
        import glob
        json_files = glob.glob(f"{output_dir}/*.json")
        if not json_files:
            raise Exception("No JSON output found from whisper")
            
        with open(json_files[0], 'r') as f:
            return json.load(f)
            
    def process_job(self, message):
        try:
            body = json.loads(message['Body'])
            job_id = body['job_id']
            s3_input_path = body['s3_input_path']
            s3_output_path = body['s3_output_path']
            
            logger.info(f"Processing job {job_id}")
            
            # Download audio
            local_audio = self.download_audio(s3_input_path)
            
            # Transcribe
            transcript = self.transcribe_with_whisper(local_audio)
            
            # Create output
            output_data = {
                "job_id": job_id,
                "s3_input_path": s3_input_path,
                "s3_output_path": s3_output_path,
                "processed_at": datetime.utcnow().isoformat() + "Z",
                "worker_id": self.worker_id,
                "transcript": transcript
            }
            
            # Save and upload
            local_output = f"/tmp/{job_id}_transcript.json"
            with open(local_output, 'w') as f:
                json.dump(output_data, f, indent=2)
                
            self.upload_transcript(local_output, s3_output_path)
            
            # Cleanup
            os.remove(local_audio)
            os.remove(local_output)
            
            logger.info(f"Job {job_id} completed successfully")
            return True
            
        except Exception as e:
            logger.error(f"Error processing job: {e}")
            return False
            
    def run(self):
        logger.info(f"Worker {self.worker_id} starting...")
        
        while self.should_continue_running():
            try:
                response = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    MaxNumberOfMessages=1,
                    WaitTimeSeconds=20,
                    VisibilityTimeout=1800
                )
                
                if 'Messages' in response:
                    for message in response['Messages']:
                        success = self.process_job(message)
                        
                        if success:
                            self.sqs.delete_message(
                                QueueUrl=self.queue_url,
                                ReceiptHandle=message['ReceiptHandle']
                            )
                            
            except Exception as e:
                logger.error(f"Error in worker loop: {e}")
                time.sleep(5)
                
        logger.info("Worker shutting down...")
        # DISABLED: Automatic shutdown temporarily disabled
        # subprocess.run(["sudo", "shutdown", "-h", "now"], check=False)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue-url", required=True)
    parser.add_argument("--s3-bucket", required=True)
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()
    
    worker = SimpleTranscriptionWorker(args.queue_url, args.s3_bucket, args.region)
    worker.run()
PYTHON_EOF

# Make it executable
chmod +x transcription_worker.py

# Start the worker
python3 transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$S3_BUCKET" --region "$REGION"
EOF

# Create the spot instance request
echo "Launching spot instance..."
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI ID: $AMI_ID"
echo "  Spot Price: $SPOT_PRICE"
echo "  Queue URL: $QUEUE_URL"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Region: $REGION"

# Encode user data
USER_DATA=$(base64 -w 0 < /tmp/user-data.sh)

# Create launch template
LAUNCH_TEMPLATE_NAME="transcription-worker-$(date +%s)"

aws ec2 create-launch-template \
    --region "$REGION" \
    --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
    --launch-template-data "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"KeyName\": \"$KEY_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$USER_DATA\",
        \"IamInstanceProfile\": {
            \"Name\": \"transcription-worker-profile\"
        },
        \"TagSpecifications\": [{
            \"ResourceType\": \"instance\",
            \"Tags\": [
                {\"Key\": \"Name\", \"Value\": \"transcription-worker\"},
                {\"Key\": \"Type\", \"Value\": \"whisper-worker\"},
                {\"Key\": \"Environment\", \"Value\": \"production\"}
            ]
        }]
    }"

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

echo "Spot instance request created: $SPOT_REQUEST"

# Wait for spot request to be fulfilled
echo "Waiting for spot instance to be launched..."
aws ec2 wait spot-instance-request-fulfilled \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Spot instance launched: $INSTANCE_ID"

# Tag the instance
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=Name,Value=transcription-worker \
           Key=Type,Value=whisper-worker \
           Key=Environment,Value=production

echo "Instance tagged and ready!"
echo "Instance ID: $INSTANCE_ID"
echo "You can check the instance status with:"
echo "  aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID"

# Cleanup
rm -f /tmp/user-data.sh