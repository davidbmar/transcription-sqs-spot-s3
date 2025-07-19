#!/bin/bash

# step-402-voxtral-validate-ecr-configuration.sh - Validate Real Voxtral ECR setup

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🔍 Real Voxtral ECR Validation${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Function to check status
check_status() {
    local description="$1"
    local command="$2"
    local help_text="$3"
    
    echo -n "  $description... "
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        if [ -n "$help_text" ]; then
            echo -e "    ${YELLOW}Help:${NC} $help_text"
        fi
        return 1
    fi
}

VALIDATION_FAILED=0

echo -e "${GREEN}[STEP 1]${NC} Validating Real Voxtral configuration..."

# Check 1: Real Voxtral ECR configuration exists
check_status "Real Voxtral ECR repository URI configured" \
    "[ -n \"$REAL_VOXTRAL_ECR_REPOSITORY_URI\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

check_status "Real Voxtral ECR repo name configured" \
    "[ -n \"$REAL_VOXTRAL_ECR_REPO_NAME\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

check_status "Voxtral model ID configured" \
    "[ -n \"$VOXTRAL_MODEL_ID\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

echo -e "${GREEN}[STEP 2]${NC} Validating AWS permissions..."

# Check 2: AWS CLI configured
check_status "AWS CLI configured" \
    "aws sts get-caller-identity" \
    "Run aws configure" || VALIDATION_FAILED=1

# Check 3: ECR permissions
check_status "ECR list repositories permission" \
    "aws ecr describe-repositories --region \"$AWS_REGION\"" \
    "Check IAM permissions for ECR access" || VALIDATION_FAILED=1

echo -e "${GREEN}[STEP 3]${NC} Validating Real Voxtral ECR repository..."

# Check 4: ECR repository exists
check_status "Real Voxtral ECR repository exists" \
    "aws ecr describe-repositories --region \"$AWS_REGION\" --repository-names \"$REAL_VOXTRAL_ECR_REPO_NAME\"" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

# Check 5: Docker CLI available
check_status "Docker CLI available" \
    "command -v docker" \
    "Install Docker CLI" || VALIDATION_FAILED=1

# Check 6: Docker daemon running
check_status "Docker daemon running" \
    "docker info" \
    "Start Docker daemon or check permissions" || VALIDATION_FAILED=1

echo -e "${GREEN}[STEP 4]${NC} Validating Real Voxtral directory structure..."

# Check 7: Real Voxtral directory exists
check_status "Real Voxtral Docker directory exists" \
    "[ -d \"docker/real-voxtral\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

# Check 8: Helper scripts exist
check_status "Real Voxtral ECR login script exists" \
    "[ -f \"scripts/real-voxtral-ecr-login.sh\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

check_status "Real Voxtral build script exists" \
    "[ -f \"scripts/build-real-voxtral-gpu.sh\" ]" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

echo -e "${GREEN}[STEP 5]${NC} Validating setup status..."

# Check 9: Setup status updated
check_status "Step 401 marked complete" \
    "grep -q 'step-401-completed=' .setup-status" \
    "Run ./scripts/step-401-voxtral-setup-ecr-repository.sh" || VALIDATION_FAILED=1

echo -e "${GREEN}[STEP 6]${NC} Testing ECR authentication..."

# Check 10: ECR login test
echo -n "  ECR authentication test... "
if aws ecr get-login-password --region "$AWS_REGION" | head -1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo -e "    ${YELLOW}Help:${NC} Check AWS credentials and ECR permissions"
    VALIDATION_FAILED=1
fi

# Update status tracking
if [ $VALIDATION_FAILED -eq 0 ]; then
    echo "step-402-completed=$(date)" >> .setup-status
fi

echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ Real Voxtral ECR Validation Complete${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
    echo -e "${GREEN}[NEXT STEPS]${NC}"
    echo "1. Create Voxtral Dockerfile:"
    echo "   Edit docker/real-voxtral/Dockerfile"
    echo
    echo "2. Build Real Voxtral GPU image:"
    echo "   ./scripts/step-410-voxtral-build-gpu-docker-image.sh"
    echo
    echo -e "${YELLOW}[CONFIGURATION SUMMARY]${NC}"
    echo "ECR Repository: $REAL_VOXTRAL_ECR_REPOSITORY_URI"
    echo "Repository Name: $REAL_VOXTRAL_ECR_REPO_NAME"
    echo "Model ID: $VOXTRAL_MODEL_ID"
    echo "Docker Directory: docker/real-voxtral/"
else
    echo -e "${RED}❌ Real Voxtral ECR Validation Failed${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
    echo -e "${RED}[ERRORS FOUND]${NC}"
    echo "Please fix the issues above before proceeding."
    exit 1
fi