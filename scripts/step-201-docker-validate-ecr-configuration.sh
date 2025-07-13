#!/bin/bash

# step-201-docker-validate-ecr-configuration.sh - Validate Docker prerequisites setup (PATH 200)

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
echo -e "${BLUE}Validate Docker Prerequisites Setup${NC}"
echo -e "${BLUE}======================================${NC}"
echo

VALIDATION_ERRORS=0

# Check ECR repository
echo -e "${GREEN}[CHECK 1]${NC} Validating ECR repository..."
if [ -z "$ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} ECR_REPOSITORY_URI not found in .env"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
else
    # Extract repository name from URI
    ECR_REPO_NAME=$(echo "$ECR_REPOSITORY_URI" | sed 's/.*\///g')
    
    if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} ECR repository exists: $ECR_REPO_NAME"
        
        # Check repository policy
        POLICY_EXISTS=$(aws ecr get-repository-policy --region "$AWS_REGION" --repository-name "$ECR_REPO_NAME" 2>/dev/null || echo "no-policy")
        if [ "$POLICY_EXISTS" != "no-policy" ]; then
            echo -e "${GREEN}[OK]${NC} Repository policy configured"
        else
            echo -e "${YELLOW}[WARNING]${NC} No repository policy set (using defaults)"
        fi
    else
        echo -e "${RED}[ERROR]${NC} ECR repository not found: $ECR_REPO_NAME"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    fi
fi

# Check Docker configuration in .env
echo -e "${GREEN}[CHECK 2]${NC} Validating Docker configuration..."
REQUIRED_VARS=("ECR_REPOSITORY_URI" "DOCKER_IMAGE_TAG")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}[ERROR]${NC} Required variable $var not found in .env"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    else
        echo -e "${GREEN}[OK]${NC} $var is configured"
    fi
done

# Check AWS permissions for ECR
echo -e "${GREEN}[CHECK 3]${NC} Validating AWS ECR permissions..."
if aws ecr get-authorization-token --region "$AWS_REGION" >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} AWS ECR authorization successful"
else
    echo -e "${RED}[ERROR]${NC} Cannot authorize with ECR. Check AWS credentials and permissions"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

# Check if Docker helper scripts exist
echo -e "${GREEN}[CHECK 4]${NC} Validating helper scripts..."
HELPER_SCRIPTS=("connect-to-docker-worker.sh" "monitor-worker-setup.sh")
for script in "${HELPER_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        echo -e "${GREEN}[OK]${NC} Helper script exists: $script"
        if [ -x "$script" ]; then
            echo -e "${GREEN}[OK]${NC} Helper script is executable: $script"
        else
            echo -e "${YELLOW}[WARNING]${NC} Helper script not executable: $script"
        fi
    else
        echo -e "${YELLOW}[WARNING]${NC} Helper script missing: $script (will be created when needed)"
    fi
done

# Check setup status
echo -e "${GREEN}[CHECK 5]${NC} Validating setup status..."
if grep -q "step-200-completed" .setup-status 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Step 200 marked as completed in .setup-status"
else
    echo -e "${RED}[ERROR]${NC} Step 200 not marked as completed. Run step-200-docker-setup-ecr-repository.sh first"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo
echo -e "${BLUE}======================================${NC}"

if [ $VALIDATION_ERRORS -eq 0 ]; then
    echo -e "${GREEN}✅ All Docker Prerequisites Validated Successfully${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
    echo -e "${GREEN}[SUMMARY]${NC}"
    echo "ECR Repository: $ECR_REPOSITORY_URI"
    echo "Docker Image Tag: $DOCKER_IMAGE_TAG"
    echo "AWS Region: $AWS_REGION"
    echo
    echo -e "${GREEN}[NEXT STEP]${NC}"
    echo "Ready to build Docker image:"
    echo "  ./scripts/step-210-docker-build-gpu-worker-image.sh"
    
    # Update status tracking
    echo "step-201-completed=$(date)" >> .setup-status
    exit 0
else
    echo -e "${RED}❌ Validation Failed: $VALIDATION_ERRORS Error(s) Found${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
    echo -e "${RED}[REQUIRED ACTIONS]${NC}"
    echo "Fix the errors above, then run:"
    echo "  ./scripts/step-200-docker-setup-ecr-repository.sh"
    echo "  ./scripts/step-201-docker-validate-ecr-configuration.sh"
    exit 1
fi