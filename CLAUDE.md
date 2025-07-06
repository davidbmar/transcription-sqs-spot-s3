# CLAUDE.md - AI Development Guidelines

🤖 **Critical instructions for Claude AI when working on this codebase.**

## 🚨 CRITICAL: No Hardcoded Values

**NEVER hardcode configuration values.** All config MUST come from `.env` file.

## 🏗️ System Architecture Overview

```
Audio Files (S3) → SQS Queue → EC2 Spot Workers (GPU) → Transcripts (S3)
                      ↓
                   DLQ (failed jobs)
```

### Core Components:
- **SQS Queue**: Manages transcription jobs with visibility timeout and retry logic
- **Dead Letter Queue**: Handles failed jobs after max retries (default: 3)
- **EC2 Spot Instances**: GPU-enabled workers (g4dn.xlarge) with CPU fallback
- **S3 Buckets**: Store audio inputs, transcripts, and lightweight metrics
- **Auto-scaling**: Queue-driven worker launching with cost optimization
- **Enhanced Logging**: Comprehensive debugging throughout the pipeline

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
4. **EC2 Config**: `step-025-setup-ec2-configuration.sh` + `step-026-validate-ec2-configuration.sh`

### ⚡ Worker Operations (Repeatable):
5. **Launch Workers**: `step-030-launch-spot-worker.sh`
6. **Health Check**: `step-035-check-worker-health.sh`
7. **Process Jobs**: Submit via `send_to_queue.py` or direct SQS integration

### 🧹 Cleanup:
8. **Workers Only**: `step-999-terminate-workers-or-selective-cleanup.sh --workers-only`
9. **Complete Teardown**: `step-999-destroy-all-resources-complete-teardown.sh --all`

## 🔬 Worker Architecture & Features

### GPU + CPU Fallback System:
- **Primary**: NVIDIA T4 GPU acceleration with WhisperX
- **Fallback**: CPU-only mode with optimized compute types (float32)
- **Smart Detection**: Automatic CUDA compatibility testing
- **Graceful Handling**: Comprehensive error recovery

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

## 📁 Key Files & Their Roles

### Configuration Management:
- **`.env`**: All configuration values (NEVER commit)
- **`.env.template`**: Example configuration (commit)
- **`.setup-status`**: Progress tracking for setup steps
- **`iam-config.env`**: IAM-specific configuration cache

### Core Worker Implementation:
- **`src/transcription_worker.py`**: Main worker loop and job processing
- **`src/transcriber.py`**: WhisperX integration with GPU/CPU fallback
- **`src/queue_metrics.py`**: S3-based metrics and queue monitoring
- **`scripts/launch-spot-worker.sh`**: EC2 user-data startup script

### Monitoring & Health:
- **`scripts/step-035-check-worker-health.sh`**: Comprehensive health monitoring
- **Cloud-init logs**: `/var/log/cloud-init-output.log` on workers
- **Worker logs**: Real-time job processing logs

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
5. ✅ **Worker Launch**: `step-030-launch-spot-worker.sh` successful
6. ✅ **Health Verification**: `step-035-check-worker-health.sh` shows operational
7. ✅ **Integration Test**: Submit test job and verify end-to-end processing

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