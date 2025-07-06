# CLAUDE.md - AI Development Guidelines

Critical instructions for Claude AI when working on this codebase.

## 🚨 CRITICAL: No Hardcoded Values

**NEVER hardcode configuration values.** All config MUST come from `.env` file.

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

1. `step-000-setup-configuration.sh` + `step-001-validate-configuration.sh`
2. `step-010-setup-iam-permissions.sh` + `step-011-validate-iam-permissions.sh`
3. `step-020-create-sqs-resources.sh` + `step-021-validate-sqs-resources.sh`
4. `step-025-setup-ec2-configuration.sh` + `step-026-validate-ec2-configuration.sh`
5. `step-030-launch-spot-worker.sh` (when ready)
6. `step-999-cleanup-resources.sh` (cleanup)

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

## Architecture

- **SQS**: Job queuing with dead letter handling
- **S3**: Audio storage + lightweight metrics
- **EC2 Spot**: GPU-accelerated transcription workers  
- **IAM**: Least-privilege roles and policies

## Key Files

- `.env` - All configuration (never commit)
- `.env.template` - Example values (commit)
- `.setup-status` - Track setup progress
- `CLAUDE.md` - This file (AI instructions)