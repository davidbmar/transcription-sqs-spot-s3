# Deployment Path Architecture - Choose Your Adventure

## 🎯 Overview
This system provides two deployment paths after common setup:
- **Path A**: Traditional EC2 + Direct Install (Original)
- **Path B**: Docker Containers on EC2 GPU (New)

## 📊 Script Numbering Architecture

### Common Foundation (000-029) - Required for Both Paths
```
step-000-setup-configuration.sh          # Create .env file
step-001-validate-configuration.sh       # Verify config
step-010-setup-iam-permissions.sh        # IAM roles/policies
step-011-validate-iam-permissions.sh     # Verify IAM
step-020-create-sqs-resources.sh         # SQS queues
step-021-validate-sqs-resources.sh       # Verify SQS
step-025-choose-deployment-path.sh       # NEW - Path selector
```

### Path A: Traditional EC2 (100-199)
```
step-100-setup-ec2-configuration.sh      # (was 025)
step-101-validate-ec2-configuration.sh   # (was 026)
step-110-deploy-worker-code.sh           # (was 030)
step-111-validate-worker-code.sh         # (was 031)
step-120-launch-spot-worker.sh           # (was 040)
step-125-check-worker-health.sh          # (was 045)
step-130-update-system-fixes.sh          # (was 050)
step-135-test-complete-workflow.sh       # (was 055)
```

### Path B: Docker on EC2 (200-299)
```
step-200-setup-docker-prerequisites.sh   # Docker/ECR setup
step-201-validate-docker-setup.sh        # Verify Docker ready
step-210-build-worker-image.sh           # Build WhisperX image
step-211-push-to-ecr.sh                  # Push to registry
step-220-launch-docker-worker.sh         # Launch GPU instance
step-225-check-docker-health.sh          # Health checks
step-230-update-docker-workers.sh        # Rolling updates
step-235-test-docker-workflow.sh         # End-to-end test
```

### Shared Utilities (900-999)
```
step-999-terminate-workers.sh            # Works for both paths
step-999-destroy-all-resources.sh        # Complete teardown
```

## 🚀 User Experience

### New User Flow:
```bash
# 1. Clone and setup basics
git clone <repo>
cd transcription-sqs-spot-s3
./scripts/step-000-setup-configuration.sh

# 2. Run common setup
for script in scripts/step-0{00..24}*.sh; do
    [[ -f "$script" ]] && ./"$script"
done

# 3. Choose your path
./scripts/step-025-choose-deployment-path.sh

# This will prompt:
┌─────────────────────────────────────────────┐
│         Choose Deployment Path              │
├─────────────────────────────────────────────┤
│ A) Traditional EC2 with Direct Install      │
│    - Proven, stable approach               │
│    - Direct GPU access                     │
│    - Manual dependency management          │
│                                            │
│ B) Docker Containers on EC2 GPU [NEW]      │
│    - Consistent environments               │
│    - Easy updates and rollbacks          │
│    - Better resource isolation            │
└─────────────────────────────────────────────┤
│ Select (A/B):                              │
└─────────────────────────────────────────────┘
```

### Path Selection Creates:
```bash
# .deployment-path file
echo "DEPLOYMENT_PATH=docker" >> .deployment-path

# Symlinks for convenience
ln -s scripts/step-220-launch-docker-worker.sh scripts/launch-worker.sh
ln -s scripts/step-225-check-docker-health.sh scripts/check-health.sh
```

## 📁 Directory Structure

```
scripts/
├── common/                    # Shared utilities
│   ├── load-config.sh
│   ├── aws-helpers.sh
│   └── logging.sh
├── traditional/              # Path A specific
│   ├── install-whisperx.sh
│   └── gpu-setup.sh
├── docker/                   # Path B specific
│   ├── install-nvidia-docker.sh
│   └── container-management.sh
└── step-XXX-*.sh            # All numbered scripts
```

## 🔄 Migration Path

For users wanting to switch from Traditional to Docker:
```bash
# Special migration script
./scripts/step-290-migrate-traditional-to-docker.sh

# This will:
1. Snapshot current configuration
2. Build Docker image with same deps
3. Test on single instance
4. Provide rollback instructions
```

## 📊 Comparison Helper

`step-025-choose-deployment-path.sh` will also create:
```
DEPLOYMENT_COMPARISON.md
├── Performance metrics
├── Cost analysis  
├── Operational complexity
└── Feature comparison
```

## 🎨 Visual Path Guide

```
                    ┌─────────────┐
                    │ Common Setup│
                    │  (000-024)  │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   Choose    │
                    │    Path     │
                    │    (025)    │
                    └──┬──────┬───┘
                       │      │
        ┌──────────────┘      └──────────────┐
        │                                    │
┌───────▼────────┐                  ┌────────▼───────┐
│  Traditional   │                  │     Docker     │
│   (100-199)    │                  │   (200-299)    │
└────────────────┘                  └────────────────┘
        │                                    │
        └──────────────┬─────────────────────┘
                       │
                ┌──────▼──────┐
                │   Production │
                │   Workloads  │
                └─────────────┘
```

## 🔧 Implementation Benefits

1. **Clear Separation**: No confusion about which scripts to run
2. **Easy Testing**: Can run both paths in parallel
3. **Gradual Migration**: Start with traditional, move to Docker when ready
4. **Documentation**: Each path has its own README
5. **Rollback Friendly**: Paths don't interfere with each other

## 📝 Path-Specific Documentation

### Created by step-025:
- `PATH_A_TRADITIONAL.md` - Traditional deployment guide
- `PATH_B_DOCKER.md` - Docker deployment guide
- `MIGRATION_GUIDE.md` - How to switch between paths