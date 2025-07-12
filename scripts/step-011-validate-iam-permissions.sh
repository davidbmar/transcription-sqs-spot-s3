#!/bin/bash

# step-011-validate-iam-permissions.sh - Validate IAM setup after step-010

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000 first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}IAM Permissions Validation${NC}"
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

# Check 1: User policy exists
USER_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionSystemUserPolicy"
check_status "User policy exists" \
    "aws iam get-policy --policy-arn '$USER_POLICY_ARN' >/dev/null 2>&1" \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 2: User policy attached to user
check_status "User policy attached to IAM user" \
    "aws iam list-attached-user-policies --user-name '$IAM_USER' --query 'AttachedPolicies[?PolicyArn==\`$USER_POLICY_ARN\`]' --output text | grep -q ." \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 3: EC2 instance role exists
ROLE_NAME="transcription-worker-role"
check_status "EC2 instance role exists" \
    "aws iam get-role --role-name '$ROLE_NAME' >/dev/null 2>&1" \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 4: Worker policy exists
WORKER_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionWorkerPolicy"
check_status "Worker policy exists" \
    "aws iam get-policy --policy-arn '$WORKER_POLICY_ARN' >/dev/null 2>&1" \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 5: Worker policy attached to role
check_status "Worker policy attached to role" \
    "aws iam list-attached-role-policies --role-name '$ROLE_NAME' --query 'AttachedPolicies[?PolicyArn==\`$WORKER_POLICY_ARN\`]' --output text | grep -q ." \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 6: Instance profile exists
INSTANCE_PROFILE_NAME="transcription-worker-profile"
check_status "Instance profile exists" \
    "aws iam get-instance-profile --instance-profile-name '$INSTANCE_PROFILE_NAME' >/dev/null 2>&1" \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 7: Role linked to instance profile
check_status "Role linked to instance profile" \
    "aws iam get-instance-profile --instance-profile-name '$INSTANCE_PROFILE_NAME' --query 'InstanceProfile.Roles[?RoleName==\`$ROLE_NAME\`]' --output text | grep -q ." \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 8: Test user permissions (basic EC2 describe)
check_status "User can describe EC2 instances" \
    "aws ec2 describe-instances --region '$AWS_REGION' --max-items 1 >/dev/null 2>&1" \
    "Check user policy permissions"

# Check 9: Test user can create launch templates
check_status "User can describe launch templates" \
    "aws ec2 describe-launch-templates --region '$AWS_REGION' --max-items 1 >/dev/null 2>&1" \
    "Check user policy permissions"

# Check 10: IAM config file exists
check_status "IAM configuration file exists" \
    "[ -f iam-config.env ]" \
    "Should be created by step-010-setup-iam-permissions.sh"

# Check 11: Setup status updated
check_status "Step 011 marked complete" \
    "grep -q 'STEP_011_COMPLETE=' .setup-status" \
    "Run ./scripts/step-010-setup-iam-permissions.sh"

# Check 12: Test assume role (if we can)
echo -e "${YELLOW}[INFO]${NC} Testing role assume capability..."
ASSUME_ROLE_TEST=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME" \
    --role-session-name "validation-test" 2>&1 || echo "FAILED")

if echo "$ASSUME_ROLE_TEST" | grep -q "AssumedRoleUser"; then
    echo -e "${GREEN}✓${NC} Role can be assumed successfully"
else
    echo -e "${YELLOW}⚠${NC} Role assume test inconclusive (may require instance context)"
fi

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}✓ IAM permissions validation PASSED${NC}"
    echo
    echo "IAM Resources Created:"
    echo "- User Policy: $USER_POLICY_ARN"
    echo "- Worker Role: $ROLE_NAME"
    echo "- Worker Policy: $WORKER_POLICY_ARN"
    echo "- Instance Profile: $INSTANCE_PROFILE_NAME"
    echo
    echo "Next step: Create SQS and S3 resources"
    echo "  ./scripts/step-020-create-sqs-resources.sh"
else
    echo -e "${RED}✗ IAM permissions validation FAILED${NC}"
    echo
    echo "Please fix the issues above before proceeding."
    echo "You may need to re-run:"
    echo "  ./scripts/step-010-setup-iam-permissions.sh"
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))