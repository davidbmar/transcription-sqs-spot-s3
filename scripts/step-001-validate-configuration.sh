#!/bin/bash

# step-001-validate-configuration.sh - Validate configuration after step-000

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Configuration Validation${NC}"
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

# Check 1: Configuration file exists
check_status "Configuration file (.env) exists" \
    "[ -f .env ]" \
    "Run ./scripts/step-000-setup-configuration.sh"

if [ -f ".env" ]; then
    source .env
    
    # Check 2: Required environment variables
    for var in AWS_REGION AWS_ACCOUNT_ID IAM_USER ENVIRONMENT QUEUE_NAME METRICS_BUCKET AUDIO_BUCKET; do
        check_status "Environment variable: $var" \
            "[ -n \"\${$var}\" ]" \
            "Check .env file or re-run step-000-setup-configuration.sh"
    done
    
    # Check 3: AWS region format
    check_status "AWS region format valid" \
        "echo '$AWS_REGION' | grep -qE '^[a-z]{2}-[a-z]+-[0-9]$'" \
        "AWS region should be like 'us-east-1' or 'us-west-2'"
    
    # Check 4: AWS account ID format
    check_status "AWS account ID format valid" \
        "echo '$AWS_ACCOUNT_ID' | grep -qE '^[0-9]{12}$'" \
        "AWS account ID should be 12 digits"
    
    # Check 5: Environment is valid
    check_status "Environment setting valid" \
        "echo '$ENVIRONMENT' | grep -qE '^(dev|staging|prod)$'" \
        "Environment should be 'dev', 'staging', or 'prod'"
    
    # Check 6: Template file exists
    check_status "Template file (.env.template) exists" \
        "[ -f .env.template ]" \
        "Template file should exist in repository"
    
    # Check 7: .env is not committed to git
    if [ -d ".git" ]; then
        check_status ".env file not tracked by git" \
            "! git ls-files --error-unmatch .env >/dev/null 2>&1" \
            "Add .env to .gitignore to prevent committing secrets"
    fi
    
    # Check 8: Setup status tracking
    check_status "Setup status file exists" \
        "[ -f .setup-status ]" \
        "Setup status file should be created by step-000"
    
    if [ -f ".setup-status" ]; then
        check_status "Step 000 marked complete in setup status" \
            "grep -q 'STEP_000_COMPLETE=' .setup-status" \
            "Run step-000-setup-configuration.sh again"
    fi
fi

# Check 9: AWS CLI configured
check_status "AWS CLI configured" \
    "aws sts get-caller-identity >/dev/null 2>&1" \
    "Run 'aws configure' to set up AWS credentials"

if aws sts get-caller-identity >/dev/null 2>&1; then
    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    if [ -n "$AWS_ACCOUNT_ID" ]; then
        check_status "AWS CLI account matches configuration" \
            "[ '$CURRENT_ACCOUNT' = '$AWS_ACCOUNT_ID' ]" \
            "AWS CLI account ($CURRENT_ACCOUNT) doesn't match configured account ($AWS_ACCOUNT_ID)"
    fi
fi

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}✓ Configuration validation PASSED${NC}"
    echo
    echo "Next step: Run IAM permissions setup"
    echo "  ./scripts/step-010-setup-iam-permissions.sh"
else
    echo -e "${RED}✗ Configuration validation FAILED${NC}"
    echo
    echo "Please fix the issues above before proceeding."
    echo "You may need to re-run:"
    echo "  ./scripts/step-000-setup-configuration.sh"
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))