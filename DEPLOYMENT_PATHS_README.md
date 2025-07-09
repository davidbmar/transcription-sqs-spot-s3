# Deployment Paths - Choose Your Architecture

## Overview

After completing the common setup steps (000-021), you'll reach a decision point at **step-060** where you choose between two deployment architectures:

### 🛤️ Path A: Traditional EC2 Deployment
- **Steps**: 025-055 (existing sequence)
- **Architecture**: Direct installation on EC2 instances
- **Best for**: Teams wanting proven, simple approach

### 🐳 Path B: Docker Container Deployment  
- **Steps**: 200-235 (new sequence)
- **Architecture**: Docker containers on GPU-enabled EC2
- **Best for**: Teams wanting modern, scalable approach

## Script Flow

```
┌─────────────────────────────────┐
│   Common Setup (000-021)        │
│   - Configuration               │
│   - IAM Permissions             │
│   - SQS Queues                  │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│   step-060-choose-path.sh       │
│   DECISION POINT                │
└──────┬──────────────┬───────────┘
       │              │
       ▼              ▼
┌──────────────┐  ┌───────────────┐
│ Traditional  │  │    Docker     │
│ Path A       │  │    Path B     │
│ (025-055)    │  │  (200-235)    │
└──────────────┘  └───────────────┘
```

## Quick Start

```bash
# 1. Complete common setup
./scripts/step-000-setup-configuration.sh
./scripts/step-010-setup-iam-permissions.sh
./scripts/step-020-create-sqs-resources.sh

# 2. Choose your path
./scripts/step-060-choose-deployment-path.sh

# 3a. If you chose Traditional (A):
./scripts/step-025-setup-ec2-configuration.sh
# ... continue with steps 026-055

# 3b. If you chose Docker (B):
./scripts/step-200-setup-docker-prerequisites.sh
# ... continue with steps 201-235
```

## Path Comparison

| Feature | Traditional (A) | Docker (B) |
|---------|----------------|------------|
| Setup Complexity | Lower | Higher (first time) |
| Launch Speed | 3-5 minutes | 1-2 minutes |
| GPU Performance | Native | ~2-3% overhead |
| Dependency Management | Manual | Automated |
| Rollback Capability | Complex | Simple |
| Resource Isolation | Process-level | Container-level |
| Debugging | Direct SSH | Container logs |
| Best For | Simplicity | Scale & Automation |

## Switching Paths

You can switch between paths at any time:

```bash
# Re-run the choice script
./scripts/step-060-choose-deployment-path.sh

# Your existing SQS queues and S3 buckets work with both paths
```

## Helper Scripts

After choosing a path, convenience symlinks are created:

- `scripts/launch-worker.sh` → Points to your chosen path's launch script
- `scripts/check-health.sh` → Points to your chosen path's health check

This means you can always just run:
```bash
./scripts/launch-worker.sh
./scripts/check-health.sh
```

## Questions?

- Traditional path issues → See original README.md
- Docker path issues → See DOCKER_GPU_IMPLEMENTATION_PLAN.md
- Can't decide? → Try Traditional first (simpler), migrate to Docker later