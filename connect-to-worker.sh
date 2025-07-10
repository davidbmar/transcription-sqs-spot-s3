#!/bin/bash
echo "🔗 Connecting to WhisperX worker..."
echo "Instance ID: i-03737064d4d91206e"
echo "Public IP: 52.14.196.67"
echo ""
echo "Useful commands:"
echo "  • GPU test: nvidia-smi"
echo "  • Worker status: sudo systemctl status transcription-worker"
echo "  • Worker logs: sudo journalctl -u transcription-worker -f"
echo "  • Setup log: sudo tail -f /var/log/worker-setup.log"
echo ""
ssh -i "transcription-worker-key-dev.pem" ubuntu@52.14.196.67
