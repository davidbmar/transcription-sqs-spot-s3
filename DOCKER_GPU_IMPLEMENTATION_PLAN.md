# Docker GPU Implementation Plan - MVP Approach

## 🎯 Mission Statement
Create a minimal, testable, and incrementally buildable system for running Docker containers with GPU support on EC2 spot instances. Each step must be independently verifiable and provide immediate value.

## 📋 Executive Summary
Transform the existing EC2-based transcription system to use Docker containers while maintaining GPU acceleration. This plan provides step-by-step scripts that can be executed sequentially, with each step providing a working MVP component.

---

## 🏗️ Phase 1: Foundation (Days 1-2)

### ✅ Step 100: Verify Prerequisites
**Script**: `step-100-verify-docker-prerequisites.sh`
**Purpose**: Ensure base system is ready for Docker implementation
**MVP Output**: Green/red status report of all prerequisites

```bash
# Verifies:
- AWS CLI configured and working
- Existing .env file present
- SQS queues accessible
- S3 buckets accessible
- EC2 permissions valid
- SSH key available

# Success Criteria:
- All checks pass with clear status messages
- Creates .docker-status tracking file
```

### ✅ Step 101: Create Minimal Docker Test
**Script**: `step-101-create-minimal-docker-test.sh`
**Purpose**: Verify Docker basics work before GPU complexity
**MVP Output**: Simple "Hello from Docker" container running locally

```bash
# Creates:
docker/test/
├── Dockerfile.minimal
└── test-minimal.sh

# Dockerfile content:
FROM ubuntu:22.04
CMD echo "Hello from Docker - $(date)"

# Success Criteria:
- Docker image builds successfully
- Container runs and outputs message
- Logs captured to docker/test/logs/
```

### ✅ Step 102: Test GPU Detection Script
**Script**: `step-102-create-gpu-detection-docker.sh`
**Purpose**: Create container that detects GPU availability
**MVP Output**: Container that reports GPU status

```bash
# Creates:
docker/gpu-test/
├── Dockerfile.gpu-detect
├── detect-gpu.py
└── test-gpu-detection.sh

# Success Criteria:
- Container attempts GPU detection
- Clear output: "GPU Available: Yes/No"
- Works on both GPU and non-GPU systems
```

---

## 🐳 Phase 2: Docker Infrastructure (Days 3-4)

### ✅ Step 110: Setup ECR Repository
**Script**: `step-110-setup-ecr-repository.sh`
**Purpose**: Create private Docker registry in AWS
**MVP Output**: ECR repository ready for image storage

```bash
# Actions:
- Creates ECR repository: whisper-docker-{ENV}
- Sets lifecycle policies (keep last 10 images)
- Outputs registry URL to .env
- Tests docker login to ECR

# Success Criteria:
- ECR repository created
- Docker authenticated to ECR
- Test push/pull works
```

### ✅ Step 111: Build Base WhisperX Image
**Script**: `step-111-build-base-whisperx-image.sh`
**Purpose**: Create minimal WhisperX container without GPU
**MVP Output**: CPU-only WhisperX container for testing

```bash
# Creates:
docker/whisperx-base/
├── Dockerfile.cpu
├── requirements.txt
├── transcribe-test.py
└── test-audio.mp3 (10 second sample)

# Success Criteria:
- Image builds with WhisperX installed
- Can transcribe test audio file
- Outputs: "WhisperX CPU test successful"
```

### ✅ Step 112: Add SQS Integration
**Script**: `step-112-add-sqs-to-docker.sh`
**Purpose**: Enable container to read from SQS
**MVP Output**: Container that polls SQS and logs messages

```bash
# Updates:
docker/whisperx-sqs/
├── Dockerfile.sqs
├── sqs_poller.py
└── test-sqs-integration.sh

# Success Criteria:
- Container connects to SQS
- Receives test message
- Logs: "Received job: {job_id}"
- Graceful shutdown on SIGTERM
```

---

## 🖥️ Phase 3: GPU Integration (Days 5-6)

### ✅ Step 120: Create GPU-Enabled Dockerfile
**Script**: `step-120-create-gpu-dockerfile.sh`
**Purpose**: Build WhisperX image with NVIDIA GPU support
**MVP Output**: GPU-capable WhisperX container

```bash
# Creates:
docker/whisperx-gpu/
├── Dockerfile.gpu
├── test-gpu-transcription.py
└── benchmark-gpu.sh

# Base: nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
# Success Criteria:
- Image builds with CUDA support
- nvidia-smi works inside container
- WhisperX loads with GPU acceleration
```

### ✅ Step 121: Create EC2 GPU Test Instance
**Script**: `step-121-launch-gpu-test-instance.sh`
**Purpose**: Launch single g4dn.xlarge for Docker GPU testing
**MVP Output**: Running EC2 instance with SSH access

```bash
# Actions:
- Launches g4dn.xlarge spot instance
- Basic Ubuntu 22.04 AMI
- Security group for SSH only
- Outputs instance ID and IP

# Success Criteria:
- Instance running
- SSH access works
- nvidia-smi shows GPU
- Saves instance details to .docker-gpu-test
```

### ✅ Step 122: Install Docker with GPU Support
**Script**: `step-122-install-docker-gpu-remote.sh`
**Purpose**: Configure Docker and NVIDIA runtime on EC2
**MVP Output**: Docker running with GPU support on EC2

```bash
# Remote installation via SSH:
- Docker Engine
- NVIDIA Container Toolkit
- Configures Docker daemon for GPU
- Tests GPU access in container

# Success Criteria:
- docker run --rm --gpus all nvidia/cuda:11.8.0-base nvidia-smi
- Shows GPU inside container
- Logs all installation steps
```

---

## 🚀 Phase 4: Production-Ready Components (Days 7-8)

### ✅ Step 130: Create Complete Worker Container
**Script**: `step-130-create-worker-container.sh`
**Purpose**: Full transcription worker with all features
**MVP Output**: Production-ready worker container

```bash
# Creates:
docker/whisperx-worker/
├── Dockerfile.worker
├── worker/
│   ├── __init__.py
│   ├── transcription_worker.py
│   ├── transcriber.py
│   ├── queue_handler.py
│   └── logger.py
├── config/
│   └── worker-config.yaml
└── scripts/
    ├── entrypoint.sh
    └── health-check.sh

# Features:
- SQS polling with exponential backoff
- S3 upload/download
- Structured JSON logging
- Health check endpoint (port 8080)
- Graceful shutdown
- GPU/CPU auto-detection

# Success Criteria:
- Processes test job end-to-end
- Uploads transcript to S3
- Proper error handling
- Health endpoint responds
```

### ✅ Step 131: Create Monitoring Stack
**Script**: `step-131-create-monitoring-stack.sh`
**Purpose**: Add logging and monitoring capabilities
**MVP Output**: CloudWatch logs and basic metrics

```bash
# Creates:
docker/monitoring/
├── docker-compose.monitoring.yml
├── cloudwatch-config.json
└── log-aggregator.py

# Features:
- CloudWatch logs integration
- Basic metrics (jobs/hour, errors)
- Log aggregation from containers
- Performance tracking

# Success Criteria:
- Logs appear in CloudWatch
- Can query logs by job ID
- Basic dashboard created
```

### ✅ Step 132: Create Auto-Scaling User Data
**Script**: `step-132-create-autoscaling-userdata.sh`
**Purpose**: Complete EC2 user data for production workers
**MVP Output**: User data script that fully configures workers

```bash
# Creates:
scripts/docker-worker-userdata.sh

# Features:
- Installs all dependencies
- Pulls latest worker image
- Starts container with restarts
- Configures CloudWatch agent
- Sets up log rotation
- Implements idle shutdown

# Success Criteria:
- New instance fully configured in <5 minutes
- Worker processing jobs automatically
- Logs shipping to CloudWatch
- Idle timeout working
```

---

## 🔄 Phase 5: Testing & Validation (Days 9-10)

### ✅ Step 140: Create Integration Test Suite
**Script**: `step-140-create-integration-tests.sh`
**Purpose**: Automated testing of complete system
**MVP Output**: Test suite with clear pass/fail

```bash
# Creates:
tests/docker-integration/
├── test-runner.sh
├── test-cases/
│   ├── 01-health-check.sh
│   ├── 02-sqs-processing.sh
│   ├── 03-gpu-transcription.sh
│   ├── 04-error-handling.sh
│   └── 05-scale-test.sh
└── test-data/
    └── sample-audio-files/

# Success Criteria:
- All tests executable independently
- Clear PASS/FAIL output
- Detailed logs for debugging
- Performance benchmarks included
```

### ✅ Step 141: Create Rollback Procedure
**Script**: `step-141-create-rollback-procedure.sh`
**Purpose**: Safe rollback to previous version
**MVP Output**: One-command rollback capability

```bash
# Creates:
scripts/docker-rollback.sh

# Features:
- Tags current version as 'previous'
- Stops current containers
- Starts previous version
- Validates health
- Automatic rollback on failure

# Success Criteria:
- Can rollback in <30 seconds
- No job loss during rollback
- Maintains GPU functionality
```

---

## 📊 Phase 6: Production Deployment (Days 11-12)

### ✅ Step 150: Create Blue-Green Deployment
**Script**: `step-150-create-blue-green-deployment.sh`
**Purpose**: Zero-downtime deployment process
**MVP Output**: Automated deployment with validation

```bash
# Creates:
scripts/deploy-docker-workers.sh

# Process:
1. Launch new workers (green)
2. Validate green workers healthy
3. Gradually shift traffic
4. Terminate old workers (blue)
5. Rollback on any failure

# Success Criteria:
- Zero downtime deployment
- Automatic health validation
- Traffic shifting works
- Rollback triggers on errors
```

### ✅ Step 151: Create Operation Runbook
**Script**: `step-151-generate-runbook.sh`
**Purpose**: Document all operational procedures
**MVP Output**: Complete operations guide

```bash
# Generates:
docs/DOCKER_OPERATIONS_RUNBOOK.md

# Sections:
- Daily health checks
- Troubleshooting guide
- Performance tuning
- Cost optimization
- Emergency procedures
- Monitoring alerts

# Success Criteria:
- New team member can operate system
- All common issues documented
- Clear escalation procedures
```

---

## 🎯 Success Metrics

### Each Step Must:
1. **Run Independently**: No dependencies on later steps
2. **Be Idempotent**: Can run multiple times safely
3. **Provide Clear Output**: Success/failure is obvious
4. **Log Everything**: Detailed logs in `logs/step-XXX/`
5. **Update Status**: Write to `.docker-implementation-status`
6. **Be Testable**: Include verification commands

### Overall Success:
- [ ] All scripts executable from fresh checkout
- [ ] Each phase provides working functionality
- [ ] GPU acceleration confirmed working
- [ ] Cost equal or better than current system
- [ ] Performance metrics documented
- [ ] Full rollback capability tested

---

## 🚦 Implementation Tracking

### Status File Format (.docker-implementation-status):
```
step-100-completed=2024-01-10T10:30:00Z
step-100-status=SUCCESS
step-100-notes=All prerequisites verified

step-101-completed=2024-01-10T11:00:00Z
step-101-status=SUCCESS
step-101-notes=Minimal Docker test working
```

### Daily Checklist:
- [ ] Run completed step validations
- [ ] Check CloudWatch logs
- [ ] Review cost metrics
- [ ] Update team on progress
- [ ] Commit status updates

---

## 📚 Additional Resources

### Required Documentation:
- AWS GPU Instance Types: https://aws.amazon.com/ec2/instance-types/g4/
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/
- WhisperX Documentation: https://github.com/m-bain/whisperX
- Docker Best Practices: https://docs.docker.com/develop/dev-best-practices/

### Support Channels:
- GitHub Issues: For bug reports
- Slack #transcription-docker: For questions
- Weekly sync meetings: Tuesdays 2pm

---

## ⚡ Quick Start for New Implementers

```bash
# 1. Clone repository
git clone <repo-url>
cd transcription-sqs-spot-s3

# 2. Start from beginning
./scripts/step-100-verify-docker-prerequisites.sh

# 3. Follow status
tail -f logs/step-100/output.log

# 4. Continue with next step when ready
./scripts/step-101-create-minimal-docker-test.sh
```

Remember: Each step builds on the previous, but can be tested independently. Take time to understand each component before moving forward.