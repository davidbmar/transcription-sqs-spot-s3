# Audio Transcription System - Next Steps

## Configuration Completed ✅

Your configuration has been saved to `.env`.

## Next Steps

### 1. Set up IAM permissions (step-010)
```bash
./scripts/step-010-setup-iam-permissions.sh
```

### 2. Create SQS queues and S3 buckets (step-020)
```bash
# Source the configuration first
source .env

# Run the setup script
./scripts/step-020-create-sqs-resources.sh
```

### 3. Test sending a message
```bash
python3 scripts/send_to_queue.py \
  --queue_url "$QUEUE_URL" \
  --s3_input_path "s3://bucket/audio.mp3" \
  --s3_output_path "s3://bucket/transcript.json" \
  --estimated_duration_seconds 300
```

### 4. Launch a worker
```bash
./scripts/launch-spot-worker.sh
```

### 5. Set up auto-scaling (optional)
- For Lambda-based scaling: Deploy `scripts/scaling_lambda.py`
- For cron-based scaling: Add `scripts/scaling_cron.sh` to crontab

## Configuration Files Created

- `.env` - Main configuration file
- `.setup-status` - Setup progress tracker

## Important Notes

- Always source `.env` before running scripts
- The QUEUE_URL will be set after running step-020
- Update security group and key pair if launching EC2 instances
