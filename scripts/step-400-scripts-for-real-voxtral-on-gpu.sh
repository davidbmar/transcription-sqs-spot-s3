#!/bin/bash

# step-400-scripts-for-real-voxtral-on-gpu.sh - Overview of 400-series scripts for Real Voxtral GPU deployment

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🎯 Real Voxtral GPU Scripts (400 Series)${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${CYAN}This series deploys Mistral's ACTUAL Voxtral model on GPU instances.${NC}"
echo -e "${CYAN}Real-time transcription API using VoxtralForConditionalGeneration.${NC}"
echo
echo -e "${YELLOW}📋 What Makes This Different:${NC}"
echo -e "${GREEN}  • 200-series:${NC} SQS-based background job processing (Whisper)"
echo -e "${GREEN}  • 300-series:${NC} Real-time HTTP API (Whisper disguised as Voxtral)"
echo -e "${GREEN}  • 400-series:${NC} Real-time HTTP API using ACTUAL Voxtral model"
echo
echo -e "${YELLOW}🎯 Real Voxtral Features:${NC}"
echo "   - Mistral's Voxtral-Mini-3B-2507 model (4.7B parameters)"
echo "   - Native audio understanding (not just transcription)"
echo "   - 8 languages supported with auto-detection"
echo "   - 32k token context length"
echo "   - Optimized for Tesla T4 GPU deployment"
echo
echo -e "${YELLOW}📋 Script Execution Order:${NC}"
echo
echo -e "${GREEN}1. Initial Setup:${NC}"
echo "   ./scripts/step-401-voxtral-setup-ecr-repository.sh"
echo "   📝 - Create ECR repository for Real Voxtral Docker images"
echo
echo "   ./scripts/step-402-voxtral-validate-ecr-configuration.sh"
echo "   📝 - Validate ECR setup and permissions"
echo
echo "   ./scripts/step-405-voxtral-setup-model-cache.sh"
echo "   📝 - Setup S3 model caching for faster deployments (optional but recommended)"
echo
echo -e "${GREEN}2. Docker Image Build:${NC}"
echo "   ./scripts/step-410-voxtral-build-gpu-docker-image.sh"
echo "   📝 - Build Voxtral Docker image with vLLM and audio support"
echo
echo "   ./scripts/step-411-voxtral-push-image-to-ecr.sh"
echo "   📝 - Push Real Voxtral image to ECR"
echo
echo -e "${GREEN}3. GPU Instance Launch:${NC}"
echo "   ./scripts/step-420-voxtral-launch-gpu-instances.sh"
echo "   📝 - Launch GPU instances for Real Voxtral processing"
echo
echo -e "${GREEN}4. Access & Health Monitoring:${NC}"
echo "   ./scripts/step-425-voxtral-add-current-ip-to-security-group.sh"
echo "   📝 - Add your current IP to EC2 security group for SSH access"
echo
echo "   ./scripts/step-426-voxtral-check-gpu-health.sh"
echo "   📝 - Monitor Real Voxtral container health"
echo
echo "   ./scripts/step-427-voxtral-monitor-model-loading.sh"
echo "   📝 - Monitor model loading with detailed timing (for benchmarking)"
echo
echo "   ./scripts/step-430-voxtral-test-transcription.sh"
echo "   📝 - Test Real Voxtral with audio files"
echo
echo "   ./scripts/step-435-voxtral-benchmark-vs-whisper.sh"
echo "   📝 - Compare Voxtral performance vs Whisper"
echo
echo -e "${YELLOW}🔧 Technical Requirements:${NC}"
echo "   - GPU: Tesla T4 or better (tested on g4dn.xlarge)"
echo "   - Memory: ~12GB disk space for model download"
echo "   - Dependencies: vLLM[audio], transformers from source"
echo "   - Model: mistralai/Voxtral-Mini-3B-2507 (4.7B params)"
echo
echo -e "${YELLOW}📝 Performance Notes:${NC}"
echo "   - Initial load: ~7-8 minutes (caches after first load)"
echo "   - Subsequent loads: ~1-2 minutes"
echo "   - Model uses bfloat16 precision on GPU"
echo "   - Supports up to 30 minutes of audio per request"
echo
echo -e "${YELLOW}🚀 Getting Started:${NC}"
echo "   1. Start with step-401 to create the ECR repository for Real Voxtral"
echo "   2. Run step-405 to cache the model to S3 (recommended for faster deployments)"
echo
echo -e "${YELLOW}📝 Notes:${NC}"
echo "   - This is REAL Voxtral, not Whisper"
echo "   - Requires Hugging Face model access"
echo "   - Tested and working on Tesla T4 GPU"
echo "   - Production-ready real-time transcription API"
echo
echo -e "${BLUE}======================================${NC}"