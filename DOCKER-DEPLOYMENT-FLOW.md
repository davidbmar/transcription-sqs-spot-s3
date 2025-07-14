# Docker GPU Deployment Flow (Path 200)

This document outlines the complete deployment flow for the Docker GPU path.

## Prerequisites
- AWS account with appropriate permissions
- AWS CLI configured
- Git repository cloned

## Step-by-Step Deployment

### Phase 1: Initial Setup (0xx Series)
These steps are common to all deployment paths:

1. **Configure Environment**
   ```bash
   ./scripts/step-000-setup-configuration.sh
   ./scripts/step-001-validate-configuration.sh
   ```

2. **Setup IAM Permissions**
   ```bash
   ./scripts/step-010-setup-iam-permissions.sh
   ./scripts/step-011-validate-iam-permissions.sh
   ```

3. **Create SQS Resources**
   ```bash
   ./scripts/step-020-create-sqs-resources.sh
   ./scripts/step-021-validate-sqs-resources.sh
   ```

4. **Choose Deployment Path**
   ```bash
   ./scripts/step-060-choose-deployment-path.sh
   # Select option 2 for Docker GPU deployment
   ```

### Phase 2: Docker-Specific Setup (2xx Series)

5. **Setup ECR Repository**
   ```bash
   ./scripts/step-200-docker-setup-ecr-repository.sh
   ./scripts/step-201-docker-validate-ecr-configuration.sh
   ```

6. **Setup EC2 Network and Security**
   ```bash
   ./scripts/step-202-docker-setup-ec2-network-and-security.sh
   ./scripts/step-203-docker-validate-ec2-network-and-security.sh
   ```
   This creates:
   - Security groups for Docker workers
   - EC2 key pairs
   - VPC/subnet configuration

7. **Build Docker Image**
   ```bash
   ./scripts/step-210-docker-build-gpu-worker-image.sh
   ```

8. **Push Image to ECR**
   ```bash
   ./scripts/step-211-docker-push-image-to-ecr.sh
   ```

9. **Launch Docker GPU Workers**
   ```bash
   ./scripts/step-220-docker-launch-gpu-workers.sh
   ```

10. **Monitor Worker Health**
    ```bash
    ./scripts/step-225-docker-monitor-worker-health.sh
    ```

### Phase 3: Testing & Validation

11. **Test Transcription Workflow**
    ```bash
    ./scripts/step-235-docker-test-transcription-workflow.sh
    ```

12. **Benchmark Performance** (Optional)
    ```bash
    ./scripts/step-240-docker-benchmark-podcast-transcription.sh
    ```

## Quick Links

- **Check worker health**: `./scripts/check-health.sh`
- **Launch additional workers**: `./scripts/launch-worker.sh`
- **Send jobs to queue**: `./src/send_to_queue.py`

## Cleanup

- **Terminate workers only**:
  ```bash
  ./scripts/step-999-terminate-workers-or-selective-cleanup.sh --workers-only
  ```

- **Complete teardown**:
  ```bash
  ./scripts/step-999-destroy-all-resources-complete-teardown.sh --all
  ```

## Notes

- The Docker path provides consistent environments and easier scaling
- GPU support is automatic with CPU fallback
- All configuration is stored in `.env` file
- Workers auto-terminate after idle timeout