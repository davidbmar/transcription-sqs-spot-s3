# 🎙️ Audio Transcription System

Scalable, production-ready audio transcription using AWS SQS, EC2 instances, and WhisperX. Supports both GPU acceleration and CPU fallback with automatic format conversion. **Now with Docker deployment support!**

## ✨ Features

- **🚀 High Performance**: GPU acceleration with NVIDIA T4 GPUs (CPU fallback available)
- **🐳 Docker Support**: Containerized deployment with ECR integration
- **💰 Cost-Effective**: EC2 Spot instances with automatic cost optimization
- **🔄 Reliable**: SQS queues with dead letter handling and retry logic
- **📊 Comprehensive**: Detailed logging, health monitoring, and metrics
- **🎵 Multi-Format**: Supports MP3, WAV, WebM, and other audio formats
- **⚡ Production Ready**: Battle-tested with validation scripts and monitoring
- **🧪 Benchmarking**: Complete GPU vs CPU performance testing suite
- **🔧 Auto-Shutdown**: Configurable idle timeouts for cost control
- **🎯 Dual Deployment**: Choose between traditional EC2 or Docker deployment

## 🏗️ Architecture

```
Audio Files (S3) → SQS Queue → EC2 Workers (GPU) → Transcripts (S3)
                       ↓
                    DLQ (failed jobs)
```

### 🛤️ Deployment Paths

The system supports **two deployment methods**:

**Path A: Traditional EC2** (100-series scripts)
- Direct installation on EC2 instances
- Faster startup, lower resource overhead
- Proven stability for production workloads

**Path B: Docker** (200-series scripts)
- Containerized deployment with ECR
- Easier scaling and environment consistency
- Better isolation and dependency management

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured with appropriate permissions
- Git installed
- Access to an AWS account
- Docker installed (for Docker deployment path)

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

# 5. 🛤️ CHOOSE DEPLOYMENT PATH
./scripts/step-060-choose-deployment-path.sh
```

### Path A: Traditional EC2 Deployment

```bash
# After step-060, if you chose Traditional (A):
./scripts/step-100-setup-ec2-configuration.sh
./scripts/step-110-deploy-worker-code.sh
./scripts/step-120-launch-spot-worker.sh
./scripts/step-125-check-worker-health.sh
```

### Path B: Docker Deployment

```bash
# After step-060, if you chose Docker (B):
./scripts/step-200-setup-docker-prerequisites.sh
./scripts/step-201-validate-docker-setup.sh
./scripts/step-210-build-worker-image.sh
./scripts/step-211-push-to-ecr.sh
./scripts/step-220-launch-docker-worker.sh
./scripts/step-225-check-docker-health.sh
```

## 🎯 Usage

### Basic Transcription

```bash
# Send a transcription job
python3 scripts/send_to_queue.py \
  --s3_input_path "s3://your-bucket/audio.mp3" \
  --s3_output_path "s3://your-bucket/transcript.json"
```

### Performance Benchmarking

```bash
# Run comprehensive GPU vs CPU benchmark
python3 scripts/benchmark-gpu-cpu-complete.py

# Test auto-shutdown (2-minute timeout)
./scripts/test-gpu-autoshutdown.sh

# Launch CPU-only worker for comparison
./scripts/launch-spot-worker-cpu.sh
```

### Docker-Specific Commands

```bash
# Build and test Docker image locally
./scripts/step-210-build-worker-image.sh

# Push to ECR
./scripts/step-211-push-to-ecr.sh

# Launch Docker worker
./scripts/step-220-launch-docker-worker.sh

# Check Docker health
curl http://worker-ip:8080/health
```

### Monitoring

```bash
# Check worker health (both deployment paths)
./scripts/step-125-check-worker-health.sh  # Traditional
./scripts/step-225-check-docker-health.sh  # Docker

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

### Core Setup (All Paths)
| Script | Purpose |
|--------|---------|
| `step-000-setup-configuration.sh` | Create `.env` configuration file |
| `step-010-setup-iam-permissions.sh` | Configure IAM roles and policies |
| `step-020-create-sqs-resources.sh` | Create SQS queues and DLQ |
| `step-060-choose-deployment-path.sh` | **Choose between Traditional or Docker** |

### Traditional EC2 Path (100-series)
| Script | Purpose |
|--------|---------|
| `step-100-setup-ec2-configuration.sh` | Configure EC2 instances |
| `step-110-deploy-worker-code.sh` | Deploy worker code to S3 |
| `step-120-launch-spot-worker.sh` | Launch GPU transcription workers |
| `step-125-check-worker-health.sh` | Monitor worker health |
| `step-130-update-system-fixes.sh` | Apply system fixes and dependency updates |
| `step-135-test-complete-workflow.sh` | End-to-end workflow validation |
| `step-140-benchmark-podcast-transcription.sh` | Real-world podcast performance benchmarking |

### Docker Path (200-series)
| Script | Purpose |
|--------|---------|
| `step-200-setup-docker-prerequisites.sh` | Setup Docker and ECR |
| `step-201-validate-docker-setup.sh` | Validate Docker environment |
| `step-210-build-worker-image.sh` | Build Docker image with WhisperX |
| `step-211-push-to-ecr.sh` | Push image to Amazon ECR |
| `step-220-launch-docker-worker.sh` | Launch Docker worker on EC2 |
| `step-225-check-docker-health.sh` | Monitor Docker container health |

### Utilities & Cleanup
| Script | Purpose |
|--------|---------|
| `benchmark-gpu-cpu-complete.py` | Comprehensive GPU vs CPU performance testing |
| `test-gpu-autoshutdown.sh` | Test worker auto-shutdown functionality |
| `launch-spot-worker-cpu.sh` | Launch CPU-only worker for benchmarking |
| `step-999-terminate-workers-or-selective-cleanup.sh` | Cleanup workers only |
| `step-999-destroy-all-resources-complete-teardown.sh` | Complete system teardown |

## 🐳 Docker Deployment Benefits

### Why Choose Docker?
- **🔧 Consistency**: Same environment across development and production
- **📦 Portability**: Easy to move between AWS regions or cloud providers
- **🚀 Scaling**: Better support for auto-scaling and orchestration
- **🛡️ Security**: Container isolation and smaller attack surface
- **🔄 Updates**: Faster deployments and rollbacks

### Docker Image Details
- **Base**: `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04`
- **Size**: ~5.6GB (compressed in ECR)
- **GPU Support**: CUDA 11.8 with automatic CPU fallback
- **Health Check**: HTTP endpoint on port 8080
- **Auto-restart**: Container restarts on failure

## 🏃‍♂️ Output Format

Transcriptions are saved as structured JSON:

```json
{
  "job_id": "uuid",
  "s3_input_path": "s3://bucket/audio.mp3",
  "s3_output_path": "s3://bucket/transcript.json",
  "processing_time_seconds": 14.9,
  "worker_id": "worker-uuid",
  "deployment_method": "docker",
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
- `ECR_REPOSITORY_URI`: Docker image repository (Docker path only)

## ⚡ GPU vs CPU Performance

The system includes comprehensive benchmarking tools to measure GPU acceleration benefits:

**Typical Results (g4dn.xlarge Tesla T4):**
- **GPU Mode**: ~10-15 seconds per 60-second audio file
- **CPU Mode**: ~60-120 seconds per 60-second audio file  
- **Speedup**: 4-8x faster with GPU acceleration
- **Docker Overhead**: Minimal (<5%) performance impact
- **Real-world Test**: 60-minute podcast transcribed in 4.2 minutes (14.3x real-time)

**Benchmark Results:**
```bash
# Run comprehensive podcast benchmark
./scripts/step-140-benchmark-podcast-transcription.sh

# Expected performance: 
# - 60-minute podcast: ~4-8 minutes processing time
# - 7-15x real-time speedup with WhisperX + Tesla T4
```

*Results vary by audio complexity and content type.*

## 🚨 Cost Management

### Estimated Costs (us-east-2):
- **g4dn.xlarge spot**: ~$0.15-0.30/hour
- **g4dn.xlarge on-demand**: ~$0.526/hour (Docker path uses on-demand for reliability)
- **SQS**: $0.40 per million requests
- **S3**: Standard storage rates
- **ECR**: $0.10/GB/month for Docker images

### Cost Controls:
- Workers auto-shutdown when idle (60-minute default)
- Spot instances for traditional path
- On-demand instances for Docker path (more reliable for GPU drivers)
- Resource cleanup scripts provided
- Auto-shutdown testing with configurable timeouts

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
# Traditional path
./scripts/step-125-check-worker-health.sh

# Docker path
./scripts/step-225-check-docker-health.sh
curl http://worker-ip:8080/health

# Check cloud-init logs
ssh -i key.pem ubuntu@worker-ip 'sudo tail -50 /var/log/cloud-init-output.log'
```

**Docker-Specific Issues:**
```bash
# Check Docker container logs
ssh -i key.pem ubuntu@worker-ip 'docker logs -f container-name'

# Check Docker image pull
ssh -i key.pem ubuntu@worker-ip 'docker images'

# Test Docker GPU support
ssh -i key.pem ubuntu@worker-ip 'docker run --rm --gpus all nvidia/cuda:11.8-base-ubuntu22.04 nvidia-smi'
```

**GPU Not Working:**
- System automatically falls back to CPU mode
- Check logs for NVIDIA driver installation status
- CPU-only mode is fully functional
- Docker path uses on-demand instances for better GPU reliability

**Common GPU/Audio Issues (Now Auto-Fixed):**
```bash
# These issues are automatically resolved in new workers:

# cuDNN library path issue (auto-fixed)
Could not load library libcudnn_ops_infer.so.8
# → Fixed: Automatic cuDNN symlink creation in DLAMI launch script

# FFmpeg missing for WebM audio (auto-fixed)  
[Errno 2] No such file or directory: 'ffmpeg'
# → Fixed: Automatic ffmpeg installation in worker setup

# Manual fix for existing workers (if needed):
sudo ln -sf /usr/local/cuda-12.4/lib/libcudnn_ops_infer.so.8 /usr/local/lib/libcudnn_ops_infer.so.8
sudo apt-get update && sudo apt-get install -y ffmpeg
```

**Permission Errors:**
```bash
# Re-run IAM setup (includes ECR permissions)
./scripts/step-010-setup-iam-permissions.sh
```

### Path Selection Issues:
```bash
# Switch deployment paths
./scripts/step-060-choose-deployment-path.sh

# Check current path
cat .deployment-path
```

## 🔄 Migration Between Paths

You can switch between deployment methods:

```bash
# Switch from Traditional to Docker
./scripts/step-060-choose-deployment-path.sh  # Choose Docker (B)
./scripts/step-200-setup-docker-prerequisites.sh
# ... continue with Docker setup

# Switch from Docker to Traditional  
./scripts/step-060-choose-deployment-path.sh  # Choose Traditional (A)
./scripts/step-100-setup-ec2-configuration.sh
# ... continue with Traditional setup
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Test with validation scripts for both deployment paths
4. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.

## 🔗 Links

- [GitHub Repository](https://github.com/davidbmar/transcription-sqs-spot-s3)
- [Issues & Support](https://github.com/davidbmar/transcription-sqs-spot-s3/issues)
- [WhisperX Documentation](https://github.com/m-bain/whisperX)
- [Docker Hub - NVIDIA CUDA](https://hub.docker.com/r/nvidia/cuda)