#!/bin/bash

# validate-setup.sh - Validate that all components are properly configured

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Transcription System Setup Validation${NC}"
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
check_status "Configuration file (.env)" \
    "[ -f .env ]" \
    "Run ./scripts/step-000-setup-configuration.sh"

if [ -f ".env" ]; then
    source .env
    
    # Check 2: Required environment variables
    for var in AWS_REGION AWS_ACCOUNT_ID QUEUE_URL AUDIO_BUCKET METRICS_BUCKET; do
        check_status "Environment variable: $var" \
            "[ -n \"\${$var}\" ]" \
            "Check .env file or re-run configuration script"
    done
    
    # Check 3: AWS CLI configured
    check_status "AWS CLI access" \
        "aws sts get-caller-identity --region $AWS_REGION >/dev/null 2>&1" \
        "Configure AWS CLI with: aws configure"
    
    # Check 4: IAM role exists
    check_status "IAM role: transcription-worker-role" \
        "aws iam get-role --role-name transcription-worker-role >/dev/null 2>&1" \
        "Run ./scripts/step-010-setup-iam-permissions.sh"
    
    # Check 5: IAM instance profile exists
    check_status "IAM instance profile: transcription-worker-profile" \
        "aws iam get-instance-profile --instance-profile-name transcription-worker-profile >/dev/null 2>&1" \
        "Run ./scripts/step-010-setup-iam-permissions.sh"
    
    # Check 6: SQS queue exists
    if [ -n "$QUEUE_URL" ]; then
        check_status "SQS queue accessible" \
            "aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names QueueArn --region $AWS_REGION >/dev/null 2>&1" \
            "Run ./scripts/step-020-create-sqs-resources.sh"
    fi
    
    # Check 7: S3 buckets exist
    if [ -n "$AUDIO_BUCKET" ]; then
        check_status "S3 audio bucket: $AUDIO_BUCKET" \
            "aws s3 ls s3://$AUDIO_BUCKET >/dev/null 2>&1" \
            "Create bucket or check permissions"
    fi
    
    if [ -n "$METRICS_BUCKET" ]; then
        check_status "S3 metrics bucket: $METRICS_BUCKET" \
            "aws s3 ls s3://$METRICS_BUCKET >/dev/null 2>&1" \
            "Run ./scripts/step-020-create-sqs-resources.sh"
    fi
    
    # Check 8: EC2 configuration
    check_status "EC2 security group configured" \
        "[ -n \"$SECURITY_GROUP_ID\" ]" \
        "Run ./scripts/step-025-setup-ec2-configuration.sh"
    
    check_status "EC2 key pair configured" \
        "[ -n \"$KEY_NAME\" ]" \
        "Run ./scripts/step-025-setup-ec2-configuration.sh"
    
    check_status "EC2 subnet configured" \
        "[ -n \"$SUBNET_ID\" ]" \
        "Run ./scripts/step-025-setup-ec2-configuration.sh"
    
    # Check 9: Key pair file exists
    if [ -n "$KEY_NAME" ]; then
        check_status "SSH key file: ${KEY_NAME}.pem" \
            "[ -f \"${KEY_NAME}.pem\" ]" \
            "Key file missing - may need to recreate with step-025"
    fi
    
    # Check 10: Python dependencies
    check_status "Python boto3 module" \
        "python3 -c 'import boto3' 2>/dev/null" \
        "Run: pip3 install boto3"
fi

# Check 11: Script permissions
for script in scripts/step-*.sh scripts/send_to_queue.py scripts/launch-spot-worker.sh; do
    if [ -f "$script" ]; then
        check_status "Executable: $script" \
            "[ -x \"$script\" ]" \
            "Run: chmod +x $script"
    fi
done

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo
    echo "Your system is ready. Next steps:"
    echo "1. Run a test: ./scripts/test-full-workflow.sh"
    echo "2. Launch a worker: ./scripts/step-030-launch-spot-worker.sh"
    echo "3. Send jobs: python3 scripts/send_to_queue.py --s3_input_path s3://... --s3_output_path s3://..."
else
    echo -e "${RED}Some checks failed.${NC}"
    echo
    echo "Please fix the issues above before proceeding."
    echo "Run the setup scripts in order:"
    echo "1. ./scripts/step-000-setup-configuration.sh"
    echo "2. ./scripts/step-010-setup-iam-permissions.sh"
    echo "3. ./scripts/step-020-create-sqs-resources.sh"
    echo "4. ./scripts/step-025-setup-ec2-configuration.sh"
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))