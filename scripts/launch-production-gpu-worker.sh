#!/bin/bash
# launch-production-gpu-worker.sh - Production-ready GPU worker with optimized setup

set -e
source .env

# Configuration
REGION=${AWS_REGION}
INSTANCE_TYPE=${INSTANCE_TYPE}
AMI_ID="ami-0efd9a34b86a437e7"
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
QUEUE_URL=${QUEUE_URL}
METRICS_BUCKET=${METRICS_BUCKET}
AUDIO_BUCKET=${AUDIO_BUCKET}
SPOT_PRICE=${SPOT_PRICE}

echo "🚀 LAUNCHING PRODUCTION GPU WORKER"
echo "Based on granular test findings - optimized for speed and reliability"

# Create production worker script
cat > /tmp/user-data-production.sh << EOF
#!/bin/bash
set -e

# Production logging
prod_log() {
    local message="\$1"
    local timestamp=\$(date '+%Y-%m-%d %H:%M:%S UTC')
    echo "[\$timestamp] \$message" | tee -a /var/log/production-worker.log
    
    # Upload logs for monitoring
    aws s3 cp /var/log/production-worker.log s3://${METRICS_BUCKET}/worker-logs/\$(curl -s http://169.254.169.254/latest/meta-data/instance-id)/production.log --region ${REGION} 2>/dev/null || true
}

prod_log "🚀 PRODUCTION WORKER STARTUP"
prod_log "Instance: \$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
prod_log "Hardware: \$(lspci | grep -i nvidia || echo 'No NVIDIA GPU detected')"

# Fast system setup
prod_log "📦 Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1
apt-get install -y wget curl git python3-pip awscli build-essential >/dev/null 2>&1

# GPU Setup Strategy: Fast approach based on test findings
prod_log "🔧 GPU SETUP: Fast installation strategy"

# Step 1: Install basic NVIDIA tools (these work quickly)
prod_log "⚡ Installing NVIDIA utilities (no DKMS)"
timeout 120 apt-get install -y nvidia-utils-535 nvidia-settings >/dev/null 2>&1 || {
    prod_log "⚠️ NVIDIA utils failed, continuing with CPU-only"
}

# Step 2: Try pre-compiled server driver with timeout
prod_log "🎯 Installing pre-compiled NVIDIA server driver"
timeout 300 apt-get install -y nvidia-driver-535-server >/dev/null 2>&1 || {
    prod_log "⚠️ Pre-compiled driver timed out, GPU setup incomplete"
    prod_log "📊 Will use CPU fallback for transcription"
}

# GPU Status Check
GPU_AVAILABLE=false
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        GPU_AVAILABLE=true
        prod_log "✅ GPU driver functional"
        nvidia-smi | head -10 >> /var/log/production-worker.log
    else
        prod_log "⚠️ nvidia-smi available but not functional - using CPU"
    fi
else
    prod_log "ℹ️ No GPU driver - using CPU transcription"
fi

# Python Setup - Optimized based on GPU availability
prod_log "🐍 Installing Python packages"
pip3 install --upgrade pip >/dev/null 2>&1

if [ "\$GPU_AVAILABLE" = true ]; then
    prod_log "🔥 Installing GPU-optimized packages"
    # Install PyTorch with CUDA
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 >/dev/null 2>&1
    # Install GPU transcription packages
    pip3 install faster-whisper whisperx >/dev/null 2>&1 || {
        prod_log "⚠️ GPU packages failed, falling back to CPU packages"
        pip3 install openai-whisper >/dev/null 2>&1
    }
else
    prod_log "💻 Installing CPU-optimized packages"
    # CPU-only PyTorch is smaller and faster to install
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu >/dev/null 2>&1
    pip3 install openai-whisper >/dev/null 2>&1
fi

# Common packages
pip3 install boto3 click soundfile >/dev/null 2>&1

# Create adaptive transcription worker
prod_log "🛠️ Creating adaptive transcription worker"
mkdir -p /opt/transcription-worker
cd /opt/transcription-worker

# Download worker code or create fallback
if aws s3 sync s3://${METRICS_BUCKET}/worker-code/latest/ . --region ${REGION} >/dev/null 2>&1; then
    prod_log "✅ Downloaded worker code from S3"
    # Use the main transcription worker from S3
    WORKER_SCRIPT="transcription_worker.py"
else
    prod_log "📝 Creating fallback transcription worker"
    WORKER_SCRIPT="production_transcription_worker.py"
    
    cat > production_transcription_worker.py << 'PYEOF'
#!/usr/bin/env python3
import sys
import os
import json
import time
import boto3
import torch
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class AdaptiveTranscriber:
    def __init__(self):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.transcriber = None
        self.transcriber_type = "none"
        
        logger.info(f"🔧 Initializing transcriber on {self.device}")
        self._load_best_transcriber()
    
    def _load_best_transcriber(self):
        """Load the best available transcriber"""
        try:
            if self.device == "cuda":
                # Try FasterWhisper first (best GPU performance)
                from faster_whisper import WhisperModel
                self.transcriber = WhisperModel("large-v3", device=self.device, compute_type="float16")
                self.transcriber_type = "faster-whisper-gpu"
                logger.info("✅ FasterWhisper GPU transcriber loaded")
                return
        except Exception as e:
            logger.warning(f"FasterWhisper GPU failed: {e}")
        
        try:
            # Try CPU FasterWhisper
            from faster_whisper import WhisperModel
            self.transcriber = WhisperModel("large-v3", device="cpu", compute_type="float32")
            self.transcriber_type = "faster-whisper-cpu"
            logger.info("✅ FasterWhisper CPU transcriber loaded")
            return
        except Exception as e:
            logger.warning(f"FasterWhisper CPU failed: {e}")
        
        try:
            # Fallback to OpenAI Whisper
            import whisper
            self.transcriber = whisper.load_model("large-v3", device=self.device)
            self.transcriber_type = "openai-whisper"
            logger.info("✅ OpenAI Whisper transcriber loaded")
            return
        except Exception as e:
            logger.error(f"All transcribers failed: {e}")
            raise
    
    def transcribe(self, audio_path):
        """Transcribe audio with the loaded transcriber"""
        start_time = time.time()
        
        if self.transcriber_type.startswith("faster-whisper"):
            segments, info = self.transcriber.transcribe(audio_path, beam_size=5)
            
            result = {
                "text": "",
                "segments": [],
                "language": info.language,
                "duration": info.duration,
                "transcriber": self.transcriber_type
            }
            
            for segment in segments:
                seg_dict = {
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text
                }
                result["segments"].append(seg_dict)
                result["text"] += segment.text + " "
        
        else:  # OpenAI Whisper
            result = self.transcriber.transcribe(audio_path)
            result["transcriber"] = self.transcriber_type
        
        result["processing_time"] = time.time() - start_time
        result["device"] = self.device
        return result

def process_queue(queue_url, region):
    """Process SQS messages"""
    sqs = boto3.client('sqs', region_name=region)
    s3 = boto3.client('s3', region_name=region)
    transcriber = AdaptiveTranscriber()
    
    logger.info(f"🚀 Starting transcription worker")
    logger.info(f"Device: {transcriber.device}")
    logger.info(f"Transcriber: {transcriber.transcriber_type}")
    
    idle_count = 0
    
    while True:
        # Get message from SQS
        response = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=20)
        
        if 'Messages' not in response:
            idle_count += 1
            if idle_count > 180:  # 180 * 20s = 3600s = 60min idle
                logger.info("No messages for 60 minutes, shutting down to save costs")
                break
            continue
        
        idle_count = 0
        message = response['Messages'][0]
        receipt_handle = message['ReceiptHandle']
        
        try:
            body = json.loads(message['Body'])
            job_id = body['job_id']
            s3_input_path = body['s3_input_path']
            s3_output_path = body['s3_output_path']
            
            logger.info(f"📝 Processing job {job_id}")
            
            # Download audio
            input_bucket, input_key = s3_input_path.replace('s3://', '').split('/', 1)
            local_path = f"/tmp/{job_id}.audio"
            s3.download_file(input_bucket, input_key, local_path)
            
            # Transcribe
            result = transcriber.transcribe(local_path)
            
            # Add metadata
            result['job_id'] = job_id
            result['transcribed_at'] = datetime.utcnow().isoformat()
            result['worker_instance'] = os.uname().nodename
            
            # Upload result
            output_bucket, output_key = s3_output_path.replace('s3://', '').split('/', 1)
            s3.put_object(
                Bucket=output_bucket,
                Key=output_key,
                Body=json.dumps(result, indent=2),
                ContentType='application/json'
            )
            
            # Delete message
            sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            
            # Cleanup
            os.remove(local_path)
            
            logger.info(f"✅ Job {job_id} completed in {result['processing_time']:.1f}s")
            
        except Exception as e:
            logger.error(f"❌ Error processing job: {e}")

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--queue-url', required=True)
    parser.add_argument('--region', default='us-east-1')
    
    args = parser.parse_args()
    process_queue(args.queue_url, args.region)
PYEOF
fi

# Start the production worker
prod_log "🎯 Starting production transcription worker"
chmod +x \$WORKER_SCRIPT

nohup python3 \$WORKER_SCRIPT \
    --queue-url "${QUEUE_URL}" \
    --region "${REGION}" > /var/log/transcription-production.log 2>&1 &

WORKER_PID=\$!
sleep 2

# Check if worker process is still running
if ps -p \$WORKER_PID >/dev/null 2>&1; then
    prod_log "✅ PRODUCTION WORKER READY"
    prod_log "Worker process started with PID \$WORKER_PID, monitoring queue for jobs"
else
    prod_log "❌ WORKER PROCESS FAILED TO START"
    prod_log "📋 Error logs:"
    tail -10 /var/log/transcription-production.log 2>/dev/null | while read line; do
        prod_log "  \$line"
    done
fi

# Upload final status
aws s3 cp /var/log/production-worker.log s3://${METRICS_BUCKET}/worker-logs/\$(curl -s http://169.254.169.254/latest/meta-data/instance-id)/startup-complete.log --region ${REGION}
EOF

# Launch production instance
USER_DATA=$(base64 -w 0 < /tmp/user-data-production.sh)

echo "Launching production worker..."

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

aws ec2 wait spot-instance-request-fulfilled --region "$REGION" --spot-instance-request-ids "$SPOT_REQUEST"
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests --region "$REGION" --spot-instance-request-ids "$SPOT_REQUEST" --query 'SpotInstanceRequests[0].InstanceId' --output text)

aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags Key=Name,Value=production-gpu-worker Key=Type,Value=production-worker

echo "🚀 Production worker launched: $INSTANCE_ID"
echo "📊 Monitor: aws s3 cp s3://${METRICS_BUCKET}/worker-logs/$INSTANCE_ID/production.log -"
echo "🎯 Ready to process jobs from queue: $QUEUE_URL"

rm -f /tmp/user-data-production.sh