# Audio Transcription System

A scalable audio transcription system using AWS SQS, EC2 Spot instances, and OpenAI's Whisper model for high-quality transcription.

## Features

- **Scalable**: Automatically processes audio files using EC2 Spot instances
- **Cost-Effective**: Uses spot instances with automatic shutdown on idle
- **Reliable**: SQS queue with dead letter queue for failed jobs
- **High Quality**: Uses OpenAI's Whisper large-v3 model
- **GPU Accelerated**: Runs on g4dn.xlarge instances with NVIDIA T4 GPUs

## Quick Start

For a complete setup guide, see [SETUP_WORKFLOW.md](SETUP_WORKFLOW.md)

1. **Clone and Configure**
```bash
git clone <repository-url>
cd transcription-sqs-spot-s3
./scripts/step-000-setup-configuration.sh
```

2. **Run Setup Scripts (in order)**
```bash
./scripts/step-010-setup-iam-permissions.sh
./scripts/step-020-create-sqs-resources.sh
./scripts/step-025-setup-ec2-configuration.sh
./scripts/step-030-launch-spot-worker.sh  # Launch worker when ready
```

3. **Send Transcription Jobs**
```bash
python3 scripts/send_to_queue.py \
  --s3_input_path "s3://your-bucket/audio.mp3" \
  --s3_output_path "s3://your-bucket/transcript.json"
```

## Configuration

All configuration is managed through a single `.env` file created from `.env.template`.
Never commit the `.env` file to version control.


