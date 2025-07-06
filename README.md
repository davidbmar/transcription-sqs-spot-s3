# Audio Transcription System

Scalable audio transcription using AWS SQS, EC2 Spot instances, and OpenAI's Whisper model.

## Features

- **GPU Accelerated**: NVIDIA T4 GPUs for fast transcription
- **Cost-Effective**: Spot instances with automatic idle shutdown
- **Reliable**: SQS queues with dead letter handling
- **Production Ready**: Comprehensive validation and testing

## Quick Setup

```bash
git clone https://github.com/davidbmar/transcription-sqs-spot-s3.git
cd transcription-sqs-spot-s3

# 1. Configure system
./scripts/step-000-setup-configuration.sh
./scripts/step-001-validate-configuration.sh

# 2. Setup IAM permissions  
./scripts/step-010-setup-iam-permissions.sh
./scripts/step-011-validate-iam-permissions.sh

# 3. Create AWS resources
./scripts/step-020-create-sqs-resources.sh
./scripts/step-021-validate-sqs-resources.sh

# 4. Configure EC2 instances
./scripts/step-025-setup-ec2-configuration.sh
./scripts/step-026-validate-ec2-configuration.sh

# 5. Test complete workflow
./scripts/step-041-test-complete-workflow.sh

# 6. Launch worker when ready
./scripts/step-030-launch-spot-worker.sh
```

## Usage

```bash
# Send transcription job
python3 scripts/send_to_queue.py \
  --s3_input_path "s3://bucket/audio.mp3" \
  --s3_output_path "s3://bucket/transcript.json"

# Monitor queue
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages

# Cleanup when done
./scripts/step-999-cleanup-resources.sh --workers-only  # or --all
```

## Configuration

Uses `.env` file for all settings. Never commit `.env` to git.


