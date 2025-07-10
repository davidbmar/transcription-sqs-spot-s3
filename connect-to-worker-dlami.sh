#!/bin/bash
echo "🔗 Connecting to WhisperX worker (DLAMI)..."
echo "Instance ID: i-091b589163edb83cb"
echo "Public IP: 18.222.252.103"
echo ""
echo "Useful commands:"
echo "  • GPU test: nvidia-smi"
echo "  • Worker status: sudo systemctl status transcription-worker"
echo "  • Worker logs: sudo journalctl -u transcription-worker -f"
echo "  • Setup log: sudo tail -f /var/log/worker-setup.log"
echo ""
ssh -i "transcription-worker-key-dev.pem" ubuntu@18.222.252.103
