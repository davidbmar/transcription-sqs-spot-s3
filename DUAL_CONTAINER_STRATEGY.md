# Dual Container Strategy: Whisper (3xx) + Voxtral (4xx)

## Architecture Overview

```
                    EC2 Host Instance (g4dn.xlarge)
                           |
           ┌─────────────────────────────────────┐
           │         Host File System            │
           │  /shared-audio/                     │
           │  ├── input.mp3    (from S3)        │
           │  ├── transcript.txt (output)       │
           │  └── analysis.json  (output)       │
           └─────────────┬───────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │Container1│   │Container2│   │   SQS    │
   │Whisper   │   │Voxtral   │   │ Worker   │
   │(3xx path)│   │(4xx path)│   │Orchestr. │
   │Port 8001 │   │Port 8000 │   │Port 8080 │
   └──────────┘   └──────────┘   └──────────┘
         │               │               │
         └───── Same GPU (Tesla T4) ─────┘
```

## Implementation Strategy

### Step 1: Deploy Both Container Types
```bash
# On same EC2 instance
./scripts/step-320-launch-docker-workers.sh    # Whisper container (port 8001)
./scripts/step-420-voxtral-launch-gpu-instances.sh  # Voxtral container (port 8000)
```

### Step 2: Shared Volume Architecture
```yaml
# docker-compose.yml for dual deployment
version: '3.8'
services:
  whisper-worker:
    image: ${ECR_REPO}/whisper-gpu:latest
    ports:
      - "8001:8000"  # Map to different host port
    volumes:
      - ./shared-audio:/shared-audio
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['0']
              capabilities: [gpu]
    environment:
      - CUDA_VISIBLE_DEVICES=0
      
  voxtral-worker:
    image: ${ECR_REPO}/voxtral-gpu:latest  
    ports:
      - "8000:8000"  # Keep original port
    volumes:
      - ./shared-audio:/shared-audio
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['0']  # Same GPU
              capabilities: [gpu]
    environment:
      - CUDA_VISIBLE_DEVICES=0
      
  orchestrator:
    image: ${ECR_REPO}/hybrid-orchestrator:latest
    ports:
      - "8080:8080"
    volumes:
      - ./shared-audio:/shared-audio
    depends_on:
      - whisper-worker
      - voxtral-worker
    environment:
      - WHISPER_ENDPOINT=http://whisper-worker:8000
      - VOXTRAL_ENDPOINT=http://voxtral-worker:8000
```

### Step 3: SQS Message Processing Flow

```python
# Enhanced SQS worker (orchestrator container)
async def process_sqs_message(message):
    """Process SQS message with both models"""
    
    # 1. Parse SQS message
    job_data = json.loads(message.body)
    s3_input_path = job_data['s3_input_path']
    s3_output_path = job_data['s3_output_path']
    
    # 2. Download audio from S3 to shared volume
    local_audio_path = f"/shared-audio/{job_data['job_id']}.mp3"
    download_from_s3(s3_input_path, local_audio_path)
    
    # 3. Launch both processes in parallel
    whisper_task = transcribe_with_whisper(local_audio_path)
    voxtral_task = analyze_with_voxtral(local_audio_path)
    
    # 4. Collect results as they complete
    whisper_result = await whisper_task  # ~3 seconds
    voxtral_result = await voxtral_task  # ~25 seconds
    
    # 5. Combine and upload results
    combined_result = {
        "transcript": whisper_result,
        "analysis": voxtral_result,
        "processing_time": {
            "whisper": whisper_result["processing_time"],
            "voxtral": voxtral_result["processing_time"],
            "total": max(whisper_result["processing_time"], voxtral_result["processing_time"])
        }
    }
    
    # 6. Upload to S3
    upload_to_s3(combined_result, s3_output_path)
    
    # 7. Cleanup
    os.remove(local_audio_path)
```

## Deployment Sequence

### Phase 1: Setup Infrastructure
```bash
# 1. Run standard setup
./scripts/step-000-setup-configuration.sh
./scripts/step-020-create-sqs-resources.sh

# 2. Build both Docker images
./scripts/step-310-docker-build-whisper-image.sh
./scripts/step-410-docker-build-voxtral-image.sh

# 3. Push to ECR
./scripts/step-311-docker-push-whisper-to-ecr.sh  
./scripts/step-411-docker-push-voxtral-to-ecr.sh
```

### Phase 2: Launch Hybrid Workers
```bash
# New script: step-500-launch-hybrid-workers.sh
#!/bin/bash

# Launch EC2 instance with both containers
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type g4dn.xlarge \
  --user-data "$(cat <<'EOF'
#!/bin/bash

# Install Docker and nvidia-docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Pull both images
docker pull $WHISPER_ECR_URI
docker pull $VOXTRAL_ECR_URI

# Create shared volume
mkdir -p /shared-audio

# Launch Whisper container
docker run -d \
  --name whisper-worker \
  --gpus all \
  -p 8001:8000 \
  -v /shared-audio:/shared-audio \
  -e CUDA_VISIBLE_DEVICES=0 \
  $WHISPER_ECR_URI

# Launch Voxtral container  
docker run -d \
  --name voxtral-worker \
  --gpus all \
  -p 8000:8000 \
  -v /shared-audio:/shared-audio \
  -e CUDA_VISIBLE_DEVICES=0 \
  $VOXTRAL_ECR_URI

# Launch orchestrator
docker run -d \
  --name hybrid-orchestrator \
  -p 8080:8080 \
  -v /shared-audio:/shared-audio \
  -e WHISPER_ENDPOINT=http://localhost:8001 \
  -e VOXTRAL_ENDPOINT=http://localhost:8000 \
  -e QUEUE_URL=$QUEUE_URL \
  $ORCHESTRATOR_ECR_URI
EOF
)"
```

## Expected Performance

### Memory Usage
```
Total GPU Memory: 15GB
├── Whisper:      2.8GB (19%)
├── Voxtral:      9.6GB (64%) 
├── Buffer:       0.5GB (3%)
└── Available:    2.1GB (14%)
```

### Processing Time
```
Sequential (current):
├── Download: 2s
├── Whisper:  3s
├── Voxtral:  25s
└── Upload:   1s
Total: 31s

Parallel (new):
├── Download: 2s
├── Both models: max(3s, 25s) = 25s
└── Upload: 1s  
Total: 28s (10% faster + better results)
```

### API Endpoints
```bash
# Health checks
curl http://worker-ip:8001/health  # Whisper
curl http://worker-ip:8000/health  # Voxtral
curl http://worker-ip:8080/health  # Orchestrator

# Direct access
curl -X POST -F "file=@audio.mp3" http://worker-ip:8001/transcribe  # Fast
curl -X POST -F "file=@audio.mp3" http://worker-ip:8000/transcribe  # Smart

# Hybrid processing
curl -X POST -F "file=@audio.mp3" http://worker-ip:8080/hybrid  # Both
```

## Benefits

1. **Speed**: Users get transcription in 3s, analysis follows
2. **Quality**: Best transcription (Whisper) + best analysis (Voxtral)  
3. **Resource Efficiency**: Same GPU, parallel processing
4. **Fallback**: If one model fails, other still works
5. **Compatibility**: Existing SQS workflow still works
6. **Scalability**: Can adjust models independently

## File Flow Example

```bash
# SQS Message arrives
{
  "job_id": "job_123",
  "s3_input_path": "s3://bucket/audio.mp3", 
  "s3_output_path": "s3://bucket/results/job_123.json"
}

# Host filesystem during processing
/shared-audio/
├── job_123.mp3          # Downloaded from S3
├── job_123_whisper.json # Whisper result  
├── job_123_voxtral.json # Voxtral result
└── job_123_final.json   # Combined result → uploaded to S3
```

This architecture gives you the **best of both worlds** - fast transcription AND intelligent analysis, running on the same hardware efficiently!