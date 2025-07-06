# Audio Transcription System - Complete Setup Workflow

This guide walks you through setting up the entire transcription system from a fresh GitHub checkout.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Python 3.8+ installed
- Git installed
- AWS account with permissions to create IAM roles, EC2 instances, SQS queues, and S3 buckets

## Setup Steps (Run in Order)

### Step 1: Clone Repository
```bash
git clone <repository-url>
cd transcription-sqs-spot-s3
```

### Step 2: Initial Configuration
```bash
./scripts/step-000-setup-configuration.sh
```
This interactive script will:
- Create a `.env` file from the template
- Ask for your AWS configuration (region, account ID, etc.)
- Set up environment-specific resource names

### Step 3: IAM Permissions Setup
```bash
./scripts/step-010-setup-iam-permissions.sh
```
This will create:
- IAM policies for user operations
- EC2 instance role and profile for workers
- All necessary permissions for SQS, S3, and EC2

### Step 4: Create SQS and S3 Resources
```bash
./scripts/step-020-create-sqs-resources.sh
```
This creates:
- Main SQS queue for transcription jobs
- Dead Letter Queue (DLQ) for failed jobs
- S3 bucket for metrics
- Updates `.env` with queue URLs

### Step 5: EC2 Configuration
```bash
./scripts/step-025-setup-ec2-configuration.sh
```
This configures:
- VPC and subnet selection
- Security group for worker instances
- SSH key pair (saved as `transcription-worker-key-{env}.pem`)
- Latest Deep Learning AMI ID

### Step 6: Launch Spot Worker (Optional - Run When Needed)
```bash
./scripts/step-030-launch-spot-worker.sh
```
This will:
- Launch a GPU-enabled spot instance
- Install all dependencies automatically
- Start the transcription worker
- Begin monitoring the SQS queue

## Using the System

### 1. Upload Audio Files to S3
First, upload your audio files to your S3 bucket:
```bash
aws s3 cp your-audio.mp3 s3://your-audio-bucket/input/your-audio.mp3
```

### 2. Send Transcription Job
```bash
python3 scripts/send_to_queue.py \
  --s3_input_path "s3://your-audio-bucket/input/your-audio.mp3" \
  --s3_output_path "s3://your-audio-bucket/output/your-audio-transcript.json" \
  --estimated_duration_seconds 300
```

### 3. Monitor Progress
Check queue status:
```bash
aws sqs get-queue-attributes \
  --queue-url $(grep QUEUE_URL .env | cut -d'"' -f2) \
  --attribute-names ApproximateNumberOfMessages
```

Check worker instances:
```bash
aws ec2 describe-instances \
  --region $(grep AWS_REGION .env | cut -d'"' -f2) \
  --filters "Name=tag:Type,Values=whisper-worker" "Name=instance-state-name,Values=running"
```

### 4. Get Results
The transcript will be saved to the S3 output path you specified:
```bash
aws s3 cp s3://your-audio-bucket/output/your-audio-transcript.json transcript.json
```

## Cleanup (When Done)

### Terminate All Workers
```bash
./scripts/step-999-cleanup-resources.sh --workers-only
```

### Complete Cleanup (Removes Everything)
```bash
./scripts/step-999-cleanup-resources.sh --all
```

## Troubleshooting

### Check Worker Logs
Once an instance is running, SSH in and check logs:
```bash
ssh -i transcription-worker-key-{env}.pem ubuntu@<instance-ip>
sudo journalctl -u cloud-final -f
```

### Check Queue for Stuck Messages
```bash
python3 scripts/check_queue_status.py
```

### Common Issues

1. **Instance won't launch**: Check your AWS service quotas for g4dn.xlarge instances
2. **Worker not processing**: Ensure the instance profile has correct permissions
3. **Transcripts not appearing**: Check worker logs and S3 bucket permissions

## Cost Optimization

- Workers automatically shut down after 5 minutes of idle time (configurable)
- Use the cleanup script to terminate instances when not needed
- Monitor your AWS bill regularly

## Security Notes

- Keep your `.env` file secure and never commit it to git
- The SSH key (`transcription-worker-key-*.pem`) should be kept secure
- Review and restrict security group rules for production use