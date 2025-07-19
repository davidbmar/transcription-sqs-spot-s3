#!/bin/bash

# step-302-fast-api-validate-ecr-configuration.sh - Validate Fast API ECR setup

set -e

# Colors for output  
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🎤 Validate Fast API ECR Configuration${NC}" 
echo -e "${BLUE}======================================${NC}"
echo

VALIDATION_PASSED=1

# Function to check status
check_status() {
    local name=$1
    local condition=$2
    local fix_hint=$3
    
    if eval "$condition"; then
        echo -e "${GREEN}✓${NC} $name"
    else
        echo -e "${RED}✗${NC} $name"
        if [ -n "$fix_hint" ]; then
            echo -e "  ${YELLOW}Fix:${NC} $fix_hint"
        fi
        VALIDATION_PASSED=0
    fi
}

# Check configuration variables
check_status "FAST_API_ECR_REPOSITORY_URI configured" \
    "[ -n '$FAST_API_ECR_REPOSITORY_URI' ]" \
    "Run ./scripts/step-301-fast-api-setup-ecr-repository.sh"

check_status "FAST_API_ECR_REPO_NAME configured" \
    "[ -n '$FAST_API_ECR_REPO_NAME' ]" \
    "Run ./scripts/step-301-fast-api-setup-ecr-repository.sh"

# Check ECR repository exists
if [ -n "$FAST_API_ECR_REPO_NAME" ]; then
    check_status "ECR repository exists" \
        "aws ecr describe-repositories --repository-names '$FAST_API_ECR_REPO_NAME' --region '$AWS_REGION' >/dev/null 2>&1" \
        "Repository may have been deleted"
fi

# Check AWS CLI access
check_status "AWS CLI configured" \
    "aws sts get-caller-identity --region '$AWS_REGION' >/dev/null 2>&1" \
    "Configure AWS credentials"

# Check Docker
check_status "Docker available locally" \
    "command -v docker >/dev/null 2>&1" \
    "Install Docker or build on EC2 instance"

# Check helper scripts
check_status "Fast API ECR login script exists" \
    "[ -f 'scripts/fast-api-ecr-login.sh' ]" \
    "Run ./scripts/step-301-fast-api-setup-ecr-repository.sh"

check_status "Fast API build script exists" \
    "[ -f 'scripts/build-fast-api-gpu.sh' ]" \
    "Run ./scripts/step-301-fast-api-setup-ecr-repository.sh"

# Check Dockerfile exists
check_status "Fast API Dockerfile exists" \
    "[ -f 'docker/fast-api/Dockerfile' ]" \
    "Create docker/fast-api/Dockerfile"

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}✓ Fast API ECR validation PASSED${NC}"
    echo
    echo -e "${GREEN}[NEXT STEPS]${NC}"
    echo "1. Build Fast API image:"
    echo "   ./scripts/step-310-fast-api-build-gpu-docker-image.sh"
    echo
    echo "2. Push to ECR:"
    echo "   ./scripts/step-311-fast-api-push-image-to-ecr.sh"
else
    echo -e "${RED}✗ Fast API ECR validation FAILED${NC}"
    echo
    echo "Please fix the issues above before proceeding."
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))