# CLAUDE.md - Important Instructions for Claude AI

This file contains critical instructions for Claude AI when working on this codebase.

## 🚨 CRITICAL: No Hardcoded Values

**NEVER hardcode configuration values in any scripts or code files.**

All configuration values MUST come from:
1. The `.env` file (primary source)
2. Environment variables (secondary source)
3. Command-line arguments (for overrides only)

## Configuration Management

### Configuration File Location
- **Single config file**: `.env` (contains all configuration)
- **Template file**: `.env.template` (checked into git with fake/example values)

### Setup Process
1. **Template**: `.env.template` contains example/fake values and is checked into git
2. **Configuration**: Run `./scripts/step-000-setup-configuration.sh` to create `.env` from template
3. **Security**: `.env` is in `.gitignore` so real secrets are never committed

### How to Load Configuration

#### In Bash Scripts:
```bash
# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi
```

#### In Python Scripts:
```python
from pathlib import Path

def load_config():
    config = {}
    config_file = Path(".env")
    if config_file.exists():
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    key = key.replace('export ', '').strip()
                    value = value.strip().strip('"')
                    config[key] = value
    return config

CONFIG = load_config()
```

### Common Configuration Variables

These should NEVER be hardcoded:
- `AWS_REGION` - AWS region
- `QUEUE_URL` - SQS queue URL
- `QUEUE_NAME` - SQS queue name
- `METRICS_BUCKET` - S3 bucket for metrics
- `AUDIO_BUCKET` - S3 bucket for audio files
- `INSTANCE_TYPE` - EC2 instance type
- `SPOT_PRICE` - Maximum spot price
- `WHISPER_MODEL` - Whisper model to use
- `IDLE_TIMEOUT_MINUTES` - Worker idle timeout

## Script Execution Order

Scripts must be run in this order:
1. `step-000-setup-configuration.sh` - Interactive configuration setup
2. `step-010-setup-iam-permissions.sh` - IAM roles and policies
3. `step-020-create-sqs-resources.sh` - SQS queues and S3 buckets

## Code Quality Standards

### When Creating New Scripts:
1. Always check for and load `.env`
2. Use environment variables with CONFIG values as defaults
3. Allow command-line overrides where appropriate
4. Document which configuration values are used

### Example Pattern:
```python
# Bad - Hardcoded
queue_url = "https://sqs.us-east-2.amazonaws.com/123456/my-queue"

# Good - From config
queue_url = CONFIG.get('QUEUE_URL', os.environ.get('QUEUE_URL', ''))
if not queue_url:
    raise ValueError("QUEUE_URL not configured. Run step-000-setup-configuration.sh")
```

## Testing Commands

After configuration, always test with dynamic values:
```bash
# Source configuration
source .env

# Use variables
python3 scripts/send_to_queue.py \
  --queue_url "$QUEUE_URL" \
  --region "$AWS_REGION"
```

## Architecture Notes

The system uses:
- SQS for job queuing (configured via step-020)
- S3 for storage and lightweight metrics
- EC2 Spot Instances for compute
- Configuration-driven deployment

## Remember

1. **Check for config file existence** before using values
2. **Provide helpful error messages** when config is missing
3. **Document configuration dependencies** in script headers
4. **Use consistent variable names** matching the config file
5. **Test with multiple environments** (dev/staging/prod)

## Current Configuration Status

To check if configuration is complete:
```bash
if [ -f ".env" ] && [ -f ".setup-status" ]; then
    echo "Configuration exists"
    source .env
    echo "Environment: $ENVIRONMENT"
    echo "Region: $AWS_REGION"
else
    echo "Configuration missing - run step-000-setup-configuration.sh"
fi
```

## Critical Requirements

### All Scripts Must Use .env Variables
- **Setup scripts** (step-010, step-020) must source `.env` for all configuration
- **Worker scripts** must use `.env` variables for queue URLs, bucket names, etc.
- **Cleanup script** (step-999) must use `.env` variables to properly destroy all resources
- **Launch scripts** must use `.env` variables for EC2 configuration

### No Hardcoded Values Anywhere
- Resource names, ARNs, URLs must come from `.env`
- AWS regions, account IDs must come from `.env`
- Instance types, AMI IDs must come from `.env`
- This ensures proper cleanup and prevents resource leaks