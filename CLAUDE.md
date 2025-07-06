# CLAUDE.md - AI Development Guidelines

Critical instructions for Claude AI when working on this codebase.

## 🚨 CRITICAL: No Hardcoded Values

**NEVER hardcode configuration values.** All config MUST come from `.env` file.

## System Architecture Overview

```
Audio Files (S3) → SQS Queue → EC2 Spot Workers (GPU) → Transcripts (S3)
                      ↓
                   DLQ (failed jobs)
```

### Core Components:
- **SQS Queue**: Manages transcription jobs with visibility timeout and retry logic
- **Dead Letter Queue**: Handles failed jobs after max retries (default: 3)
- **EC2 Spot Instances**: GPU-enabled workers (g4dn.xlarge) running WhisperX
- **S3 Buckets**: Store audio inputs, transcripts, and lightweight metrics
- **Auto-scaling**: Based on queue depth and pending work minutes

## Configuration Pattern

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

## Required Script Execution Order

### Initial Setup (First Time Only):
1. `step-000-setup-configuration.sh` + `step-001-validate-configuration.sh`
2. `step-010-setup-iam-permissions.sh` + `step-011-validate-iam-permissions.sh`
3. `step-020-create-sqs-resources.sh` + `step-021-validate-sqs-resources.sh`
4. `step-025-setup-ec2-configuration.sh` + `step-026-validate-ec2-configuration.sh`

### Worker Launch (Repeatable):
5. `step-030-launch-spot-worker.sh` - Launch GPU spot instances
   - Can be run multiple times to scale up workers
   - Workers auto-terminate when idle (default: 300s)
   - Check `.setup-status` for worker instance IDs

### Testing & Cleanup:
6. `step-041-test-complete-workflow.sh` - End-to-end test
7. `step-999-terminate-workers-or-selective-cleanup.sh` - Selective cleanup (workers only or all)
8. `step-999-destroy-all-resources-complete-teardown.sh` - Complete system teardown

## Launching Spot Instances

To launch transcription workers:
```bash
# Ensure all setup steps (000-026) are complete
./step-030-launch-spot-worker.sh

# Launch multiple workers for scaling
./step-030-launch-spot-worker.sh  # Run multiple times
```

### Worker Behavior:
- Auto-starts transcription service on boot
- Polls SQS queue for jobs
- Downloads audio from S3
- Transcribes using WhisperX (GPU-accelerated)
- Uploads results to S3
- Auto-terminates when idle

### Monitoring Workers:
```bash
# Check running instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=transcription-worker" "Name=instance-state-name,Values=running"

# View worker logs (SSH into instance)
sudo journalctl -u transcription-worker -f
```

## Step-XXX Format Requirements

- **All new scripts** must follow `step-XXX-description.sh` naming
- **Add validation script** after each setup step (`step-XXX+1-validate-xxx.sh`)
- **Use .env variables** exclusively - no hardcoded values
- **Include error handling** and helpful error messages
- **Update .setup-status** to track completion

## Never Hardcode These:

- AWS regions, account IDs, resource names
- Queue URLs, bucket names, ARNs
- Instance types, AMI IDs, subnet IDs
- Any environment-specific values

## Example - Good vs Bad:

```python
# Bad - Hardcoded
queue_url = "https://sqs.us-east-2.amazonaws.com/123456/my-queue"

# Good - From config
queue_url = CONFIG.get('QUEUE_URL')
if not queue_url:
    raise ValueError("QUEUE_URL not configured. Run step-000-setup-configuration.sh")
```

## Key Files

### Configuration:
- `.env` - All configuration (never commit)
- `.env.template` - Example values (commit)
- `.setup-status` - Track setup progress
- `CLAUDE.md` - This file (AI instructions)

### Worker Implementation:
- `transcription_worker.py` - Main worker loop
- `transcriber.py` - WhisperX integration
- `queue_metrics.py` - S3-based metrics
- `user-data.sh` - EC2 startup script

## Production Deployment Checklist

1. **Configuration**: Run `step-001-validate-configuration.sh`
2. **IAM Permissions**: Verify roles and policies are created
3. **Resources**: Ensure SQS queues and S3 buckets exist
4. **Network**: Validate VPC, subnet, and security groups
5. **Launch Workers**: Run `step-030-launch-spot-worker.sh`
6. **Test**: Submit test job with `step-041-test-complete-workflow.sh`
7. **Monitor**: Check CloudWatch logs and S3 metrics

## Troubleshooting

### Worker Not Processing Jobs:
1. Check SQS queue has messages
2. Verify IAM permissions
3. Review worker logs: `sudo journalctl -u transcription-worker`
4. Ensure GPU is available: `nvidia-smi`

### High Costs:
1. Check idle timeout configuration
2. Review spot instance pricing
3. Monitor number of running instances
4. Consider smaller instance types for light workloads