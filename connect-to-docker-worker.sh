#!/bin/bash
echo "🔗 Connecting to Docker worker..."
echo "Instance ID: i-0bbca2b79aa95f773"
echo "Public IP: 18.220.250.104"
echo ""
echo "Commands to run:"
echo "  • Check setup: sudo tail -f /var/log/docker-worker-setup.log"
echo "  • Check worker: docker logs -f $(docker ps -q --filter 'ancestor=821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest')"
echo "  • Health check: curl http://localhost:8080/health"
echo "  • Health logs: sudo tail -f /var/log/health-check.log"
echo ""
ssh -i "transcription-worker-key-dev.pem" ubuntu@18.220.250.104
