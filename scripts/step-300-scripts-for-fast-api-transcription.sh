#!/bin/bash

# step-300-scripts-for-fast-api-transcription.sh - Overview of 300-series scripts for Fast Real-time Transcription API

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🚀 Fast API Transcription Scripts (300 Series)${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${CYAN}This series sets up a real-time transcription API with instant response.${NC}"
echo -e "${CYAN}NO SQS queues - direct HTTP API calls with immediate results.${NC}"
echo
echo -e "${YELLOW}📋 Key Differences from 200-series:${NC}"
echo -e "${GREEN}  • 200-series:${NC} SQS-based background job processing"
echo -e "${GREEN}  • 300-series:${NC} Real-time HTTP API with instant response"
echo -e "${GREEN}  • 200-series:${NC} Jobs queued, processed asynchronously" 
echo -e "${GREEN}  • 300-series:${NC} Upload → immediate transcription → response"
echo
echo -e "${YELLOW}📋 Script Execution Order:${NC}"
echo
echo -e "${GREEN}1. Initial Setup:${NC}"
echo "   ./scripts/step-301-fast-api-setup-ecr-repository.sh"
echo "   📝 - Create ECR repository for Fast API Docker images"
echo
echo "   ./scripts/step-302-fast-api-validate-ecr-configuration.sh"
echo "   📝 - Validate ECR setup and permissions"
echo
echo -e "${GREEN}2. Docker Image Build:${NC}"
echo "   ./scripts/step-310-fast-api-build-gpu-docker-image.sh"
echo "   📝 - Build Fast API Docker image with GPU support"
echo
echo "   ./scripts/step-311-fast-api-push-image-to-ecr.sh"
echo "   📝 - Push Fast API image to ECR"
echo
echo -e "${GREEN}3. GPU Instance Launch:${NC}"
echo "   ./scripts/step-320-fast-api-launch-gpu-instances.sh"
echo "   📝 - Launch GPU instances for real-time transcription API"
echo
echo -e "${GREEN}4. Health & Testing:${NC}"
echo "   ./scripts/step-325-fast-api-fix-ssh-access.sh"
echo "   📝 - Fix SSH access to API instances (if needed)"
echo
echo "   ./scripts/step-326-fast-api-check-gpu-health.sh"
echo "   📝 - Monitor API container health"
echo
echo "   ./scripts/step-330-fast-api-test-transcription.sh"
echo "   📝 - Test real-time transcription with sample audio"
echo
echo -e "${YELLOW}🚀 API Features:${NC}"
echo "   - Real-time transcription (no queues)"
echo "   - File upload support"
echo "   - S3 input/output support"
echo "   - URL-based audio input"
echo "   - 13x real-time processing speed on GPU"
echo "   - Interactive API documentation"
echo
echo -e "${YELLOW}📝 Use Cases:${NC}"
echo "   - Interactive applications needing instant results"
echo "   - Testing and development"
echo "   - Small-scale transcription needs"
echo "   - Applications that can't use SQS/background jobs"
echo
echo -e "${YELLOW}🚀 Getting Started:${NC}"
echo "   Start with step-301 to create the ECR repository for Fast API"
echo
echo -e "${YELLOW}📝 Notes:${NC}"
echo "   - Requires GPU instances (g4dn.xlarge or better)"
echo "   - Uses WhisperX model for transcription"
echo "   - Runs independently from SQS-based 200-series"
echo "   - Optimized for speed and immediate response"
echo
echo -e "${BLUE}======================================${NC}"