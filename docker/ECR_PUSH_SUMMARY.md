# ECR Push Summary

## Image Details
- **Repository**: 821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber
- **Tag**: latest
- **Size**: 5603MB
- **Pushed**: 2025-07-09T04:59:32.571000+00:00

## Quick Commands
```bash
# Pull image
docker pull 821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest

# Run locally
docker run --gpus all -p 8080:8080 821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest

# Deploy on EC2
./docker/worker/deploy.sh
```

## Next Steps
1. Launch GPU-enabled EC2 instance
2. Run: `./scripts/step-220-launch-docker-worker.sh`
3. Monitor: `./scripts/step-225-check-docker-health.sh`

Generated: Wed Jul  9 04:59:35 UTC 2025
