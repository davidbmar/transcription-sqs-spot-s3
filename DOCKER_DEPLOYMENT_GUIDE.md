# 🐳 Docker Deployment Guide

Complete guide for deploying the WhisperX transcription system using Docker containers.

## 📋 Overview

The Docker deployment path (200-series scripts) provides:
- **Containerized Workers**: Consistent runtime environment
- **ECR Integration**: Amazon Elastic Container Registry for image storage
- **GPU Support**: NVIDIA CUDA 11.8 with automatic CPU fallback
- **Health Monitoring**: HTTP endpoints for container health checks
- **Auto-restart**: Container restart policies for reliability

## 🏗️ Architecture

```
Docker Image (ECR) → EC2 Instance → Docker Container → WhisperX Worker
      ↓                    ↓              ↓
   5.6GB Image         GPU Support    Port 8080 Health
```

## 🚀 Quick Start

### Prerequisites
- Docker installed locally
- AWS CLI configured
- Core setup (steps 000-025) completed

### Step-by-Step Deployment

```bash
# 1. Choose Docker deployment path
./scripts/step-060-choose-deployment-path.sh  # Select (B) Docker

# 2. Setup Docker and ECR
./scripts/step-200-setup-docker-prerequisites.sh
./scripts/step-201-validate-docker-setup.sh

# 3. Build and push Docker image
./scripts/step-210-build-worker-image.sh
./scripts/step-211-push-to-ecr.sh

# 4. Launch Docker worker
./scripts/step-220-launch-docker-worker.sh

# 5. Monitor health
./scripts/step-225-check-docker-health.sh
curl http://worker-ip:8080/health
```

## 📦 Docker Image Details

### Base Image
- **Image**: `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04`
- **Size**: ~11GB uncompressed, ~5.6GB compressed in ECR
- **CUDA**: Version 11.8 with cuDNN 8 support
- **Python**: 3.10 with WhisperX dependencies

### Key Components
- **WhisperX**: GPU-accelerated transcription engine
- **PyTorch**: CUDA-enabled for GPU acceleration
- **AWS SDK**: For S3 and SQS integration
- **ffmpeg**: Audio format conversion
- **Health Server**: HTTP endpoint on port 8080

### Environment Variables
```bash
# Required environment variables for container
AWS_REGION                # AWS region
QUEUE_URL                 # SQS queue URL
AWS_ACCESS_KEY_ID         # AWS credentials
AWS_SECRET_ACCESS_KEY     # AWS credentials
AUDIO_BUCKET              # S3 bucket for audio files
METRICS_BUCKET            # S3 bucket for metrics
```

## 🔧 Configuration

### ECR Repository
```bash
# Repository naming convention
ECR_REPO_NAME="${QUEUE_PREFIX}-whisper-transcriber"
ECR_REPOSITORY_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"

# Example
# dbm-aud-tr-dev-whisper-transcriber
# 821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber
```

### Docker Run Command
```bash
# Complete Docker run command with all options
docker run -d \
    --name "whisper-worker-$(date +%s)" \
    --gpus all \
    --restart unless-stopped \
    -e AWS_REGION="$AWS_REGION" \
    -e QUEUE_URL="$QUEUE_URL" \
    -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    -e AUDIO_BUCKET="$AUDIO_BUCKET" \
    -e METRICS_BUCKET="$METRICS_BUCKET" \
    -p 8080:8080 \
    "$ECR_REPOSITORY_URI:latest"
```

## 🏥 Health Monitoring

### Health Check Endpoint
```bash
# Check container health
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

### Docker Health Checks
```bash
# Check container status
docker ps

# View container logs
docker logs -f container-name

# Execute commands in container
docker exec -it container-name bash

# Check GPU inside container
docker exec container-name nvidia-smi
```

## 🔍 Troubleshooting

### Common Issues

#### Container Not Starting
```bash
# Check container logs
docker logs container-name

# Check if image exists
docker images | grep whisper

# Check Docker daemon
sudo systemctl status docker

# Check GPU support
docker run --rm --gpus all nvidia/cuda:11.8-base-ubuntu22.04 nvidia-smi
```

#### Health Check Failing
```bash
# Check if port is accessible
curl -v http://worker-ip:8080/health

# Check container port mapping
docker port container-name

# Check security group rules
aws ec2 describe-security-groups --group-ids $SECURITY_GROUP_ID
```

#### GPU Not Working
```bash
# Check NVIDIA drivers on host
nvidia-smi

# Check Docker GPU support
docker run --rm --gpus all nvidia/cuda:11.8-base-ubuntu22.04 nvidia-smi

# Check container GPU access
docker exec container-name nvidia-smi

# Falls back to CPU automatically if GPU unavailable
```

#### ECR Push/Pull Issues
```bash
# Re-authenticate with ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY_URI

# Check ECR permissions
aws ecr describe-repositories --repository-names $ECR_REPO_NAME

# Check IAM permissions
aws iam get-policy-version --policy-arn arn:aws:iam::ACCOUNT:policy/TranscriptionSystemUserPolicy --version-id v1
```

## 📊 Performance Comparison

### Docker vs Traditional
| Metric | Traditional EC2 | Docker |
|--------|----------------|---------|
| **Startup Time** | 5-8 minutes | 8-12 minutes |
| **Resource Overhead** | Minimal | +2-5% CPU/Memory |
| **Consistency** | Variable | Identical |
| **Scaling** | Manual | Container-ready |
| **Debugging** | SSH + logs | Docker logs |
| **Updates** | Re-deploy scripts | Push new image |

### GPU Performance
- **Docker GPU**: ~5-10% overhead compared to native
- **CPU Fallback**: Automatic, no performance penalty
- **Memory**: Slightly higher due to container overhead

## 💰 Cost Considerations

### ECR Costs
- **Storage**: $0.10/GB/month for images
- **Data Transfer**: Free within same region
- **5.6GB Image**: ~$0.56/month storage cost

### Instance Costs
- **On-Demand**: More expensive than spot (~$0.526/hour vs $0.15-0.30/hour)
- **Reliability**: Worth the cost for GPU driver stability
- **Auto-shutdown**: Same idle timeout features

## 🔄 CI/CD Integration

### Automated Builds
```bash
# Build new version
./scripts/step-210-build-worker-image.sh

# Push to ECR
./scripts/step-211-push-to-ecr.sh

# Deploy new version
./scripts/step-220-launch-docker-worker.sh
```

### Version Management
```bash
# Tag images with timestamps
docker tag $ECR_REPOSITORY_URI:latest $ECR_REPOSITORY_URI:$(date +%Y%m%d-%H%M%S)

# List all versions
aws ecr describe-images --repository-name $ECR_REPO_NAME

# Clean up old versions (lifecycle policy handles this automatically)
```

## 🚀 Scaling Strategies

### Multi-Worker Deployment
```bash
# Launch multiple workers
for i in {1..3}; do
    ./scripts/step-220-launch-docker-worker.sh
done
```

### Auto-Scaling Integration
- Container-ready for ECS/EKS
- Can be integrated with AWS Auto Scaling
- Health checks enable load balancer integration

## 🛡️ Security Features

### Container Isolation
- **Process Isolation**: Containers run in isolated namespaces
- **File System**: Read-only root filesystem where possible
- **Network**: Controlled port exposure
- **User**: Non-root user inside container

### ECR Security
- **Private Registry**: Images stored in private ECR
- **Access Control**: IAM-based access control
- **Scanning**: Vulnerability scanning enabled
- **Encryption**: Images encrypted at rest

## 🔗 Integration with Other Services

### ECS Integration
```bash
# Can be deployed to ECS with task definition
{
  "family": "whisper-transcriber",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "8192",
  "containerDefinitions": [
    {
      "name": "whisper-worker",
      "image": "$ECR_REPOSITORY_URI:latest",
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "AWS_REGION", "value": "$AWS_REGION"},
        {"name": "QUEUE_URL", "value": "$QUEUE_URL"}
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      }
    }
  ]
}
```

### Kubernetes Integration
```yaml
# Can be deployed to EKS with Kubernetes manifests
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whisper-transcriber
spec:
  replicas: 3
  selector:
    matchLabels:
      app: whisper-transcriber
  template:
    metadata:
      labels:
        app: whisper-transcriber
    spec:
      containers:
      - name: whisper-worker
        image: ECR_REPOSITORY_URI:latest
        ports:
        - containerPort: 8080
        env:
        - name: AWS_REGION
          value: "us-east-2"
        - name: QUEUE_URL
          value: "QUEUE_URL"
        resources:
          requests:
            nvidia.com/gpu: 1
          limits:
            nvidia.com/gpu: 1
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
```

## 📚 Additional Resources

- [Docker GPU Support Documentation](https://docs.docker.com/config/containers/resource_constraints/#gpu)
- [Amazon ECR User Guide](https://docs.aws.amazon.com/AmazonECR/latest/userguide/)
- [NVIDIA Docker Documentation](https://github.com/NVIDIA/nvidia-docker)
- [WhisperX GitHub Repository](https://github.com/m-bain/whisperX)

## 🎯 Best Practices

1. **Image Optimization**: Use multi-stage builds to minimize image size
2. **Health Checks**: Always implement health check endpoints
3. **Logging**: Use structured logging with JSON format
4. **Secrets**: Use AWS Secrets Manager for sensitive data
5. **Monitoring**: Implement CloudWatch metrics for containers
6. **Backup**: Keep multiple image versions for rollback
7. **Testing**: Test images locally before pushing to ECR
8. **Security**: Regularly scan images for vulnerabilities
9. **Documentation**: Keep deployment guides up to date
10. **Automation**: Use CI/CD pipelines for image builds and deployments