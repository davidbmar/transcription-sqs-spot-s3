# CLAUDE.md - AI Development Guidelines

🤖 **Critical instructions for Claude AI when working on this codebase.**

## 🚨 CRITICAL: No Hardcoded Values

**NEVER hardcode configuration values.** All config MUST come from `.env` file.

## 🏗️ System Architecture Overview

```
Audio Files (S3) → SQS Queue → EC2 Workers (GPU) → Transcripts (S3)
                      ↓
                   DLQ (failed jobs)
```

### Core Components:
- **SQS Queue**: Manages transcription jobs with visibility timeout and retry logic
- **Dead Letter Queue**: Handles failed jobs after max retries (default: 3)
- **EC2 Workers**: GPU-enabled workers (g4dn.xlarge) with CPU fallback
- **S3 Buckets**: Store audio inputs, transcripts, and lightweight metrics
- **Auto-scaling**: Queue-driven worker launching with cost optimization
- **Enhanced Logging**: Comprehensive debugging throughout the pipeline
- **Docker Support**: ECR-based containerized deployment path
- **Dual Deployment**: Traditional EC2 direct install vs Docker containerized

### 🛤️ Deployment Paths:
- **Path 100 (Traditional)**: Direct EC2 installation with DLAMI and spot instances  
- **Path 200 (Docker GPU)**: Containerized deployment with ECR and GPU optimization
- **Path 300 (Fast API)**: Real-time HTTP API using Whisper (renamed from misleading "Voxtral")
- **Path 400 (Real Voxtral)**: Actual Mistral Voxtral-Mini-3B-2507 model deployment
- **Path 500 (Hybrid)**: Best of both worlds - Whisper + Voxtral on same GPU

### 📊 Performance Benchmarks:
- **Docker GPU (Path 200)**: 16.4x real-time speed (60min podcast in 3min 40sec)
- **Fast API (Path 300)**: 13x real-time speed with HTTP API
- **Real Voxtral (Path 400)**: 1.2x real-time speed, 4.7B parameter model with native audio understanding
- **Hybrid (Path 500)**: Fast transcription (3s) + Smart analysis (25s) on same GPU
- **Traditional (Path 100)**: Variable based on instance configuration and setup

## 🔧 Configuration Patterns

### Bash Scripts:
```bash
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi
```

### Python Scripts:
```python
def load_config():
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

CONFIG = load_config()
```

## 📋 Required Script Execution Order

### 🚀 Initial Setup (First Time Only):
1. **Configuration**: `step-000-setup-configuration.sh` + `step-001-validate-configuration.sh`
2. **IAM Setup**: `step-010-setup-iam-permissions.sh` + `step-011-validate-iam-permissions.sh`
3. **SQS Resources**: `step-020-create-sqs-resources.sh` + `step-021-validate-sqs-resources.sh`
4. **Deploy Path**: Ready for deployment path selection

### 🛤️ Deployment Path Selection:
5. **Choose Path**: `step-060-choose-deployment-path.sh`

### 🚀 Path 100: DLAMI Deployment (Traditional):
6. **EC2 Configuration**: `step-101-setup-ec2-configuration.sh` + `step-102-validate-ec2-configuration.sh`
7. **Deploy Code**: `step-110-deploy-worker-code.sh` + `step-111-validate-worker-code.sh`
8. **Launch DLAMI Workers**: `scripts/launch-dlami-ondemand-worker.sh`
9. **Health Check**: `step-125-check-worker-health.sh`
10. **System Fixes**: `step-130-update-system-fixes.sh`
11. **End-to-End Test**: `step-135-test-complete-workflow.sh`

### 🐳 Path 200: Docker GPU Deployment (Production-Ready):
6. **Docker Prerequisites**: `step-200-docker-setup-ecr-repository.sh` + `step-201-docker-validate-ecr-configuration.sh`
7. **Build GPU Image**: `step-210-docker-build-gpu-worker-image.sh` + `step-211-docker-push-image-to-ecr.sh`
8. **Launch GPU Workers**: `step-220-docker-launch-gpu-workers.sh`
9. **Health Monitoring**: `step-225-docker-monitor-worker-health.sh`
10. **Test Workflow**: `step-235-docker-test-transcription-workflow.sh` (short audio)
11. **Benchmark Podcast**: `step-240-docker-benchmark-podcast-transcription.sh` (60min audio)

### ⚡ Path 300: Fast API Deployment (Real-time HTTP):
6. **ECR Setup**: `step-301-fast-api-setup-ecr-repository.sh` + `step-302-fast-api-validate-ecr-configuration.sh`
7. **Build Image**: `step-310-fast-api-build-gpu-docker-image.sh` + `step-311-fast-api-push-image-to-ecr.sh`
8. **Launch Workers**: `step-320-fast-api-launch-gpu-workers.sh`
9. **Health Check**: `step-325-fast-api-fix-ssh-access.sh` + `step-326-fast-api-check-gpu-health.sh`
10. **Test API**: `step-330-fast-api-test-transcription.sh`

### 🎯 Path 400: Real Voxtral Deployment (Mistral's Actual Model):
6. **ECR Setup**: `step-401-voxtral-setup-ecr-repository.sh` + `step-402-voxtral-validate-ecr-configuration.sh`
7. **Build Image**: `step-410-voxtral-build-gpu-docker-image.sh` + `step-411-voxtral-push-image-to-ecr.sh`
8. **Launch GPU**: `step-420-voxtral-launch-gpu-instances.sh` (100GB disk)
9. **Health & SSH**: `step-425-voxtral-fix-ssh-access.sh` + `step-426-voxtral-check-gpu-health.sh`
10. **Test & Benchmark**: `step-430-voxtral-test-transcription.sh` + `step-435-voxtral-benchmark-vs-whisper.sh`

### 🎭 Path 500: Hybrid Deployment (Best of Both Worlds):
6. **Prerequisites**: Both Path 300 and 400 Docker images built and pushed to ECR
7. **Launch Hybrid**: `step-500-launch-hybrid-workers.sh` (Whisper + Voxtral on same GPU)
8. **Test Deployment**: `step-501-test-hybrid-deployment.sh` (parallel processing validation)
9. **Monitor Health**: `step-502-monitor-hybrid-health.sh` (dual container monitoring)
10. **Scale Workers**: `step-503-scale-hybrid-workers.sh` (intelligent scaling based on queue depth)

### 🔧 System Operations (Both Paths):
10. **Process Jobs**: Submit via `send_to_queue.py` or direct SQS integration
11. **Monitor Health**: Path-specific health check scripts

### 🧹 Cleanup:
12. **Workers Only**: `step-999-terminate-workers-or-selective-cleanup.sh --workers-only`
13. **Complete Teardown**: `step-999-destroy-all-resources-complete-teardown.sh --all`

## 🔬 Worker Architecture & Features

### GPU + CPU Fallback System:
- **Primary**: NVIDIA T4 GPU acceleration with WhisperX
- **Fallback**: CPU-only mode with optimized compute types (float32)
- **Smart Detection**: Automatic CUDA compatibility testing
- **Graceful Handling**: Comprehensive error recovery
- **Docker Support**: CUDA 11.8 containers with GPU passthrough
- **Container Health**: HTTP health checks on port 8080

### 🐳 Docker Features:
- **Base Image**: `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04`
- **Size**: ~5.6GB compressed in ECR
- **GPU Support**: Automatic GPU detection with CPU fallback
- **Health Monitoring**: HTTP endpoint for container health
- **Auto-restart**: Container restart policies for reliability
- **Environment Isolation**: Consistent runtime environment

### Enhanced Logging Features:
```bash
# Device detection logs
🔧 DEVICE DETECTION:
  - Requested device: cuda
  - CUDA available: True/False
  - Selected device: cuda/cpu

# NVIDIA installation logs  
🔧 NVIDIA DRIVER INSTALLATION
✅ NVIDIA drivers installed successfully
❌ NVIDIA driver installation failed, continuing with CPU-only mode

# Worker startup logs
🚀 STARTING TRANSCRIPTION WORKER
✅ MODEL LOADED: WhisperX base successfully loaded
🎉 SUCCESS: Job uuid completed successfully!
```

### Audio Format Support:
- **Native**: MP3, WAV, FLAC, M4A
- **Conversion**: WebM → WAV via ffmpeg
- **Quality**: Maintains original audio fidelity
- **Error Handling**: Graceful format conversion failures

## 📝 Step-XXX Script Standards

### Naming Convention:
- **Setup**: `step-XXX-action-description.sh`
- **Validation**: `step-XXX+1-validate-description.sh`
- **Sequential**: Numbers indicate execution order

### Requirements:
- ✅ **Environment Variables**: Use `.env` exclusively
- ✅ **Error Handling**: Comprehensive exit codes and messages
- ✅ **Status Tracking**: Update `.setup-status` file
- ✅ **User Feedback**: Clear progress indicators and next steps
- ✅ **Validation**: Each setup step has corresponding validation

### Example Template:
```bash
#!/bin/bash
set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found."
    exit 1
fi

# Your script logic here...

# Update status tracking
echo "step-XXX-completed=$(date)" >> .setup-status
```

## 🚫 Never Hardcode These Values:

- ❌ AWS regions, account IDs, resource names
- ❌ Queue URLs, bucket names, ARNs  
- ❌ Instance types, AMI IDs, subnet IDs
- ❌ API endpoints, credentials, secrets
- ❌ File paths, directory names

## ✅ Configuration Best Practices:

```python
# ❌ Bad - Hardcoded
queue_url = "https://sqs.us-east-2.amazonaws.com/123456/my-queue"
bucket_name = "my-audio-bucket"

# ✅ Good - From config with validation
queue_url = CONFIG.get('QUEUE_URL')
bucket_name = CONFIG.get('AUDIO_BUCKET')

if not queue_url or not bucket_name:
    raise ValueError("Required configuration missing. Run step-000-setup-configuration.sh")
```

## 🐳 Docker Configuration Patterns

### Docker Environment Variables:
```bash
# Docker containers receive environment variables from EC2 user-data
docker run -d \
    --name whisper-worker \
    --gpus all \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    -p 8080:8080 \
    "$ECR_REPOSITORY_URI:latest"
```

### ECR Configuration:
```bash
# ECR repository naming follows queue prefix
ECR_REPO_NAME="${QUEUE_PREFIX}-whisper-transcriber"
ECR_REPOSITORY_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"
```

### Docker Health Checks:
```bash
# Health check endpoint for container monitoring
curl http://worker-ip:8080/health

# Expected response
{
  "status": "healthy",
  "timestamp": "2025-07-09T05:30:00Z",
  "uptime": 300,
  "gpu_available": true,
  "worker_running": true,
  "container_id": "hostname"
}
```

## 📁 Key Files & Their Roles

### Configuration Management:
- **`.env`**: All configuration values (NEVER commit)
- **`.env.template`**: Example configuration (commit)
- **`.setup-status`**: Progress tracking for setup steps
- **`iam-config.env`**: IAM-specific configuration cache
- **`.deployment-path`**: Current deployment path selection

### Core Worker Implementation:
- **`src/transcription_worker.py`**: Main worker loop and job processing
- **`src/transcriber.py`**: WhisperX integration with GPU/CPU fallback
- **`src/queue_metrics.py`**: S3-based metrics and queue monitoring
- **`scripts/launch-spot-worker.sh`**: EC2 user-data startup script (Traditional)
- **`docker/worker/Dockerfile`**: Docker image definition
- **`docker/worker/entrypoint.sh`**: Container startup script
- **`docker/worker/health-check.py`**: HTTP health check server

### Monitoring & Health:
- **`scripts/step-125-check-worker-health.sh`**: Traditional health monitoring
- **`scripts/step-225-check-docker-health.sh`**: Docker health monitoring
- **Health endpoint**: `http://worker-ip:8080/health` (Docker only)
- **Cloud-init logs**: `/var/log/cloud-init-output.log` on workers
- **Worker logs**: Real-time job processing logs
- **Docker logs**: `docker logs container-name` for containerized workers

## 🔍 Health Monitoring Features

### Intelligent Status Detection:
```bash
# Enhanced health check capabilities
✅ SSH connectivity testing
🔧 Cloud-init status monitoring  
⚡ Worker process detection
📊 Recent job activity tracking
🏥 Operational status despite cloud-init delays
```

### Debugging Tools:
```bash
# Worker health check
./scripts/step-035-check-worker-health.sh

# Manual log inspection
ssh -i key.pem ubuntu@worker-ip 'sudo tail -50 /var/log/cloud-init-output.log'

# Process monitoring
ps aux | grep transcription_worker
```

## 🏭 Production Deployment Checklist

### Pre-Deployment:
1. ✅ **Configuration**: All `.env` values set and validated
2. ✅ **IAM Permissions**: Roles, policies, and instance profiles created
3. ✅ **AWS Resources**: SQS queues, S3 buckets, security groups ready
4. ✅ **Network Access**: VPC, subnets, and connectivity verified

### Deployment:
5. ✅ **Path Selection**: `step-060-choose-deployment-path.sh` completed
6. ✅ **Worker Launch**: Path-specific launch script successful
   - Traditional: `step-120-launch-spot-worker.sh`
   - Docker: `step-220-launch-docker-worker.sh`
7. ✅ **Health Verification**: Path-specific health check shows operational
   - Traditional: `step-125-check-worker-health.sh`
   - Docker: `step-225-check-docker-health.sh`
8. ✅ **Integration Test**: Submit test job and verify end-to-end processing

### Post-Deployment:
8. ✅ **Monitoring**: CloudWatch logs and S3 metrics tracking
9. ✅ **Cost Controls**: Idle timeout and spot pricing monitoring
10. ✅ **Backup Plans**: Worker replacement and scaling procedures

## 🐛 Common Troubleshooting Scenarios

### Worker Issues:
```bash
# Worker not processing jobs
1. Check queue: aws sqs get-queue-attributes --queue-url $QUEUE_URL
2. Verify IAM: Check worker role permissions
3. Review logs: sudo tail -f /var/log/cloud-init-output.log
4. Test GPU: nvidia-smi (if available)

# Docker-specific issues
1. Check container: docker ps -a
2. Container logs: docker logs container-name
3. Health check: curl http://worker-ip:8080/health
4. GPU in container: docker exec container-name nvidia-smi

# WhisperX errors
1. Check compute type: Look for float16/float32 messages
2. Verify device: Review device detection logs
3. Model loading: Check for memory/CUDA errors
```

### Cost Management:
```bash
# High cost alerts
1. Instance count: aws ec2 describe-instances --filters "Name=tag:Type,Values=whisper-worker"
2. Idle timeout: Review worker idle configuration
3. Spot pricing: Monitor spot instance pricing trends
4. Queue depth: Ensure workers scale down when idle
```

## 🔄 Integration Patterns for Other Systems

### Direct SQS Integration:
```python
import boto3
import json

def send_transcription_job(s3_input, s3_output):
    sqs = boto3.client('sqs')
    sqs.send_message(
        QueueUrl=CONFIG['QUEUE_URL'],
        MessageBody=json.dumps({
            "job_id": str(uuid.uuid4()),
            "s3_input_path": s3_input,
            "s3_output_path": s3_output,
            "priority": 1
        })
    )
```

### Webhook/API Integration:
- Workers can be extended to call webhooks on job completion
- REST API wrapper can be added for HTTP-based integration
- Status polling via S3 object existence checking

---

## 📚 Additional Resources

- **GitHub Issues**: Report bugs and feature requests
- **WhisperX Docs**: https://github.com/m-bain/whisperX
- **AWS Spot Instances**: Best practices and pricing
- **Production Scaling**: Multi-region and high-volume patterns