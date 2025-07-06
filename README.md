# 🎙️ Audio Transcription System

Scalable, production-ready audio transcription using AWS SQS, EC2 Spot instances, and WhisperX. Supports both GPU acceleration and CPU fallback with automatic format conversion.

## ✨ Features

- **🚀 High Performance**: GPU acceleration with NVIDIA T4 GPUs (CPU fallback available)
- **💰 Cost-Effective**: EC2 Spot instances with automatic cost optimization
- **🔄 Reliable**: SQS queues with dead letter handling and retry logic
- **📊 Comprehensive**: Detailed logging, health monitoring, and metrics
- **🎵 Multi-Format**: Supports MP3, WAV, WebM, and other audio formats
- **⚡ Production Ready**: Battle-tested with validation scripts and monitoring

## 🏗️ Architecture

```
Audio Files (S3) → SQS Queue → EC2 Spot Workers (GPU) → Transcripts (S3)
                       ↓
                    DLQ (failed jobs)
```

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured with appropriate permissions
- Git installed
- Access to an AWS account

### Setup (5 minutes)

```bash
# 1. Clone and navigate
git clone https://github.com/davidbmar/transcription-sqs-spot-s3.git
cd transcription-sqs-spot-s3

# 2. Configure system
./scripts/step-000-setup-configuration.sh
./scripts/step-001-validate-configuration.sh

# 3. Setup IAM permissions  
./scripts/step-010-setup-iam-permissions.sh
./scripts/step-011-validate-iam-permissions.sh

# 4. Create AWS resources
./scripts/step-020-create-sqs-resources.sh
./scripts/step-021-validate-sqs-resources.sh

# 5. Configure EC2 instances
./scripts/step-025-setup-ec2-configuration.sh
./scripts/step-026-validate-ec2-configuration.sh

# 6. Launch worker
./scripts/step-030-launch-spot-worker.sh

# 7. Check worker health
./scripts/step-035-check-worker-health.sh
```

## 🎯 Usage

### Basic Transcription

```bash
# Send a transcription job
python3 scripts/send_to_queue.py \
  --s3_input_path "s3://your-bucket/audio.mp3" \
  --s3_output_path "s3://your-bucket/transcript.json"
```

### Monitoring

```bash
# Check worker health
./scripts/step-035-check-worker-health.sh

# Monitor queue depth
aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages
```

### Integration with Other Systems

**Python Integration:**
```python
import boto3
import json
import uuid

def send_transcription_job(s3_input_path, s3_output_path):
    sqs = boto3.client('sqs', region_name='us-east-2')
    
    job_data = {
        "job_id": str(uuid.uuid4()),
        "s3_input_path": s3_input_path,
        "s3_output_path": s3_output_path,
        "estimated_duration_seconds": 300,
        "priority": 1,
        "retry_count": 0
    }
    
    sqs.send_message(
        QueueUrl='your-queue-url',
        MessageBody=json.dumps(job_data)
    )
    
    return job_data["job_id"]
```

## 📋 Script Reference

| Script | Purpose |
|--------|---------|
| `step-000-setup-configuration.sh` | Create `.env` configuration file |
| `step-010-setup-iam-permissions.sh` | Configure IAM roles and policies |
| `step-020-create-sqs-resources.sh` | Create SQS queues and DLQ |
| `step-025-setup-ec2-configuration.sh` | Configure EC2 security groups and keys |
| `step-030-launch-spot-worker.sh` | Launch transcription worker instances |
| `step-035-check-worker-health.sh` | Monitor worker health and status |
| `step-999-terminate-workers-or-selective-cleanup.sh` | Cleanup workers only |
| `step-999-destroy-all-resources-complete-teardown.sh` | Complete system teardown |

## 🏃‍♂️ Output Format

Transcriptions are saved as structured JSON:

```json
{
  "job_id": "uuid",
  "s3_input_path": "s3://bucket/audio.mp3",
  "s3_output_path": "s3://bucket/transcript.json",
  "processing_time_seconds": 14.9,
  "worker_id": "worker-uuid",
  "transcript": {
    "segments": [
      {
        "start": 1.162,
        "end": 9.489,
        "text": "Transcribed speech content...",
        "words": [
          {
            "word": "Transcribed",
            "start": 1.162,
            "end": 1.5,
            "score": 0.95
          }
        ]
      }
    ],
    "language": "en"
  }
}
```

## 🔧 Configuration

All configuration is managed through the `.env` file. Never commit this file to git.

**Key Settings:**
- `AWS_REGION`: AWS region for resources
- `INSTANCE_TYPE`: EC2 instance type (default: g4dn.xlarge)
- `SPOT_PRICE`: Maximum spot price
- `AUDIO_BUCKET`: S3 bucket for audio files
- `METRICS_BUCKET`: S3 bucket for metrics and outputs

## 🚨 Cost Management

### Estimated Costs (us-east-2):
- **g4dn.xlarge spot**: ~$0.15-0.30/hour
- **SQS**: $0.40 per million requests
- **S3**: Standard storage rates

### Cost Controls:
- Workers auto-shutdown when idle (configurable)
- Spot instances for cost optimization
- Resource cleanup scripts provided

## 🧹 Cleanup

```bash
# Terminate workers only (preserve queues/buckets)
./scripts/step-999-terminate-workers-or-selective-cleanup.sh --workers-only

# Complete teardown (⚠️ deletes everything)
./scripts/step-999-destroy-all-resources-complete-teardown.sh --all
```

## 🐛 Troubleshooting

### Common Issues:

**Worker Not Starting:**
```bash
# Check worker health
./scripts/step-035-check-worker-health.sh

# Check cloud-init logs
ssh -i key.pem ubuntu@worker-ip 'sudo tail -50 /var/log/cloud-init-output.log'
```

**GPU Not Working:**
- System automatically falls back to CPU mode
- Check logs for NVIDIA driver installation status
- CPU-only mode is fully functional

**Permission Errors:**
```bash
# Re-run IAM setup
./scripts/step-010-setup-iam-permissions.sh
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Test with validation scripts
4. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.

## 🔗 Links

- [GitHub Repository](https://github.com/davidbmar/transcription-sqs-spot-s3)
- [Issues & Support](https://github.com/davidbmar/transcription-sqs-spot-s3/issues)
- [WhisperX Documentation](https://github.com/m-bain/whisperX)