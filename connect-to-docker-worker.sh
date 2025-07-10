#!/bin/bash
echo "🔗 Connecting to Docker worker..."
echo "Instance ID: i-080ba12a4c66925e0"
echo "Public IP: 18.191.183.158"
echo ""
echo "Commands to run:"
echo "  • Check setup: sudo tail -f /var/log/docker-worker-setup.log"
echo "  • Check worker: docker logs -f $(docker ps -q --filter 'ancestor=821850226835.dkr.ecr.us-east-2.amazonaws.com/dbm-aud-tr-dev-whisper-transcriber:latest')"
echo "  • Health check: curl http://localhost:8080/health"
echo "  • Health logs: sudo tail -f /var/log/health-check.log"
echo ""
ssh -i "transcription-worker-key-dev.pem" ubuntu@18.191.183.158
