# Docker GPU Deployment Guide

## 🚀 Production-Ready GPU Transcription with Docker

This deployment path provides a containerized, GPU-accelerated transcription system optimized for production workloads.

### 📊 Performance Highlights
- **16.4x real-time speed** (60-minute podcast in 3 minutes 40 seconds)
- **Sub-second processing** for short audio clips
- **Production tested** with 68MB+ audio files
- **GPU acceleration** with automatic CPU fallback

## 🎯 Quick Start

### Prerequisites
- AWS account with appropriate permissions
- Completed initial setup (steps 000-060)
- Docker-compatible instance types selected

### 🔄 Complete Deployment Sequence

```bash
# 1. Setup Docker prerequisites and ECR repository
./scripts/step-200-docker-setup-ecr-repository.sh
./scripts/step-201-docker-validate-ecr-configuration.sh

# 2. Build and push GPU-optimized Docker image
./scripts/step-210-docker-build-gpu-worker-image.sh  
./scripts/step-211-docker-push-image-to-ecr.sh

# 3. Launch Docker GPU workers
./scripts/step-220-docker-launch-gpu-workers.sh

# 4. Monitor and test deployment
./scripts/step-225-docker-monitor-worker-health.sh
./scripts/step-235-docker-test-transcription-workflow.sh

# 5. Benchmark with real podcast (optional)
./scripts/step-240-docker-benchmark-podcast-transcription.sh
```

## 🛠️ What Each Script Does

### Step 200: Docker Setup
- **File**: `step-200-docker-setup-ecr-repository.sh`
- **Purpose**: Creates ECR repository, configures Docker environment
- **Output**: ECR repository URI, updated `.env` configuration
- **Time**: ~2-3 minutes

### Step 201: Validate Configuration  
- **File**: `step-201-docker-validate-ecr-configuration.sh`
- **Purpose**: Validates ECR setup and Docker prerequisites
- **Checks**: Repository exists, permissions, configuration validity
- **Time**: ~1 minute

### Step 210: Build Docker Image
- **File**: `step-210-docker-build-gpu-worker-image.sh`
- **Purpose**: Builds GPU-optimized Docker image with Whisper
- **Features**: CUDA 11.8, cuDNN 8, Python 3.10, GPU fallback
- **Size**: ~5.6GB (includes GPU libraries)
- **Time**: ~10-15 minutes (first build)

### Step 211: Push to ECR
- **File**: `step-211-docker-push-image-to-ecr.sh`  
- **Purpose**: Uploads Docker image to ECR for deployment
- **Output**: ECR image URI for worker launch
- **Time**: ~5-10 minutes (depends on upload speed)

### Step 220: Launch GPU Workers
- **File**: `step-220-docker-launch-gpu-workers.sh`
- **Purpose**: Launches GPU instances with containerized workers
- **Instance**: g4dn.xlarge (recommended) with NVIDIA T4 GPU
- **Features**: Auto-scaling, health monitoring, GPU optimization
- **Time**: ~3-5 minutes for instance launch + container startup

### Step 225: Health Monitoring
- **File**: `step-225-docker-monitor-worker-health.sh`
- **Purpose**: Comprehensive health checks for Docker GPU workers
- **Checks**: SSH, Docker, GPU, container, worker process, SQS connectivity
- **Output**: Detailed status report with troubleshooting info

### Step 235: Test Workflow
- **File**: `step-235-docker-test-transcription-workflow.sh`
- **Purpose**: End-to-end test with short audio file
- **Audio**: 5-second test file (validates basic functionality)
- **Time**: ~30 seconds total processing

### Step 240: Podcast Benchmark  
- **File**: `step-240-docker-benchmark-podcast-transcription.sh`
- **Purpose**: Production benchmark with 60-minute podcast
- **Audio**: Real podcast episode (~68MB)
- **Expected**: 3-4 minutes processing time
- **Output**: Performance metrics and transcript quality analysis

## 🔧 Technical Details

### Docker Image Specifications
- **Base**: `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04`
- **Python**: 3.10 (Ubuntu 22.04 default)
- **GPU**: CUDA 11.8 + cuDNN 8 for stability
- **Libraries**: OpenAI Whisper, PyTorch 2.0.0+cu118, boto3
- **Worker**: `quick_worker.py` optimized for containerized deployment

### GPU Configuration
- **Instance Types**: g4dn.xlarge (recommended), g4dn.2xlarge for higher throughput
- **GPU**: NVIDIA T4 with 16GB GPU memory
- **Drivers**: Included in container (isolated from host)
- **Fallback**: Automatic CPU fallback if GPU unavailable

### Container Features
- **Health Checks**: HTTP endpoint on port 8080
- **Auto-restart**: Container restart policies for reliability
- **Logging**: Comprehensive logging with timestamps
- **Environment**: Isolated runtime with consistent dependencies

## 📁 File Structure

```
scripts/
├── step-199-docker-deployment-section-start.sh    # Info script
├── step-200-docker-setup-ecr-repository.sh        # ECR setup
├── step-201-docker-validate-ecr-configuration.sh  # Validation
├── step-210-docker-build-gpu-worker-image.sh      # Build image
├── step-211-docker-push-image-to-ecr.sh          # Push to ECR
├── step-220-docker-launch-gpu-workers.sh         # Launch workers
├── step-225-docker-monitor-worker-health.sh      # Health checks
├── step-235-docker-test-transcription-workflow.sh # Test
└── step-240-docker-benchmark-podcast-transcription.sh # Benchmark

docker/
├── gpu-worker/
│   ├── Dockerfile                     # GPU-optimized container
│   └── entrypoint.sh                 # Container startup script
└── worker/
    └── health-check.py               # Health monitoring

src/
├── quick_worker.py                   # Main worker (Docker optimized)
├── transcription_worker.py          # Traditional worker
└── transcriber.py                   # Core transcription logic
```

## 🎯 Use Cases

### Production Workloads
- **High-volume** podcast transcription
- **Enterprise** audio processing pipelines  
- **Scalable** transcription services
- **Cost-effective** batch processing

### Development & Testing
- **Consistent** development environments
- **Reproducible** deployments across teams
- **Easy scaling** for load testing
- **Isolated** dependency management

## 🔍 Troubleshooting

### Common Issues

**Docker build fails with "No space left on device"**
```bash
# Clean up Docker cache
docker system prune -a
# Retry build
./scripts/step-210-docker-build-gpu-worker-image.sh
```

**Container fails to start with GPU errors**
```bash
# Check GPU availability on instance
nvidia-smi
# Review container logs
docker logs container-name
```

**Worker not processing jobs**
```bash
# Check worker health
./scripts/step-225-docker-monitor-worker-health.sh
# Verify SQS queue connectivity
aws sqs get-queue-attributes --queue-url $QUEUE_URL
```

### Performance Optimization

**For higher throughput:**
- Use `g4dn.2xlarge` or larger instances
- Increase container resource limits
- Adjust worker idle timeout settings
- Consider multiple workers per instance

**For cost optimization:**
- Use spot instances for batch workloads
- Implement auto-scaling based on queue depth
- Optimize container startup time with cached images

## 📊 Monitoring & Metrics

### Performance Monitoring
- Processing time per job
- GPU utilization metrics
- Queue depth monitoring
- Container health status

### Cost Monitoring  
- Instance running time
- ECR storage costs
- Data transfer costs
- Spot instance savings

## 🔐 Security Best Practices

- **IAM roles** for container access (no hardcoded credentials)
- **VPC security groups** restricting network access
- **ECR image scanning** for vulnerabilities
- **Container resource limits** preventing resource exhaustion

## 📚 Additional Resources

- **CLAUDE.md**: Complete development guidelines
- **AWS ECR Documentation**: Container registry setup
- **Docker GPU Documentation**: NVIDIA container toolkit
- **Whisper Documentation**: Model selection and optimization

---

**✅ Production Ready**: This deployment path has been tested with 60-minute podcasts achieving 16.4x real-time speed.

**🚀 Get Started**: Run `./scripts/step-200-docker-setup-ecr-repository.sh` to begin deployment.