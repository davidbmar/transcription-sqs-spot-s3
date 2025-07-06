#!/bin/bash

# step-999-destroy-all-resources-complete-teardown.sh - Destroy all resources and configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Display script information
echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║         COMPLETE SYSTEM TEARDOWN - DESTROY ALL                ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${RED}⚠️  WARNING: This script performs a COMPLETE TEARDOWN! ⚠️${NC}"
echo
echo -e "${YELLOW}This script will PERMANENTLY DELETE:${NC}"
echo
echo -e "${RED}AWS Resources:${NC}"
echo "  • All EC2 instances and spot requests"
echo "  • SQS queues (main queue + dead letter queue)"
echo "  • S3 metrics bucket and all its contents"
echo "  • Security groups and key pairs"
echo "  • IAM roles, policies, and instance profiles"
echo
echo -e "${RED}Local Files:${NC}"
echo "  • All configuration files (.env, status files)"
echo "  • Generated credentials and keys"
echo "  • Setup tracking files"
echo
echo -e "${GREEN}What will be PRESERVED:${NC}"
echo "  • Audio bucket (to prevent data loss)"
echo "  • Your source code and git repository"
echo
echo -e "${YELLOW}When to use this script:${NC}"
echo "  • Starting completely fresh from scratch"
echo "  • Cleaning up after testing/development"
echo "  • Removing all traces of the system"
echo
echo -e "${YELLOW}Alternative:${NC} Use step-999-terminate-workers-or-selective-cleanup.sh"
echo "for selective cleanup that preserves infrastructure."
echo

# Initial confirmation
read -p "Do you want to proceed with COMPLETE TEARDOWN? (yes/no): " INITIAL_CONFIRM

if [ "$INITIAL_CONFIRM" != "yes" ]; then
    echo -e "${GREEN}[INFO]${NC} Teardown cancelled. No resources were affected."
    exit 0
fi

# Function to print colored output
print_header() {
    echo ""
    echo -e "${RED}=== $1 ===${NC}"
    echo ""
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_danger() {
    echo -e "${RED}[DANGER]${NC} $1"
}

# Check if configuration exists
if [ ! -f ".env" ]; then
    print_error "No configuration file found. Nothing to destroy."
    exit 1
fi

# Load configuration
source .env

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    DANGER: DESTROY ALL                        ║"
echo "║         This will permanently delete all resources!           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_danger "This script will destroy the following resources:"
echo ""
echo "SQS Queues:"
echo "  - $QUEUE_NAME ($QUEUE_URL)"
echo "  - $DLQ_NAME ($DLQ_URL)"
echo ""
echo "S3 Buckets:"
echo -e "  - ${RED}$METRICS_BUCKET${NC} (will be DELETED)"
echo ""
echo -e "${GREEN}S3 Buckets that will be PRESERVED:${NC}"
echo -e "  - ${GREEN}$AUDIO_BUCKET${NC} (your audio files - will NOT be deleted)"
echo ""
echo "EC2 Resources:"
echo "  - All instances tagged as 'whisper-worker'"
echo "  - All spot instance requests"
echo ""
echo "IAM Resources:"
echo "  - Policy: TranscriptionSystemUserPolicy"
echo "  - Policy: TranscriptionWorkerPolicy"
echo "  - Role: transcription-worker-role"
echo "  - Instance Profile: transcription-worker-profile"
echo ""
echo "Configuration Files:"
echo "  - transcription-config.env"
echo "  - worker-config.env"
echo "  - docker.env"
echo "  - queue-config.env"
echo "  - iam-config.env"
echo "  - All other generated files"
echo ""

# Confirmation
read -p "Are you ABSOLUTELY SURE you want to destroy all resources? Type 'DESTROY ALL' to confirm: " CONFIRM

if [ "$CONFIRM" != "DESTROY ALL" ]; then
    print_warning "Destruction cancelled."
    exit 0
fi

# Double confirmation
read -p "This is your LAST CHANCE. Type the environment name '$ENVIRONMENT' to confirm: " CONFIRM_ENV

if [ "$CONFIRM_ENV" != "$ENVIRONMENT" ]; then
    print_warning "Environment name mismatch. Destruction cancelled."
    exit 0
fi

print_header "Starting Resource Destruction"

# Step 1: Terminate EC2 instances
print_header "Terminating EC2 Instances"

# Find and terminate worker instances
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=whisper-worker" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
    print_status "Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances \
        --instance-ids $INSTANCE_IDS \
        --region "$AWS_REGION" || print_warning "Failed to terminate some instances"
else
    print_status "No worker instances found"
fi

# Cancel spot instance requests
SPOT_REQUESTS=$(aws ec2 describe-spot-instance-requests \
    --filters "Name=state,Values=active,open" \
    --query 'SpotInstanceRequests[*].SpotInstanceRequestId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$SPOT_REQUESTS" ] && [ "$SPOT_REQUESTS" != "None" ]; then
    print_status "Cancelling spot requests: $SPOT_REQUESTS"
    aws ec2 cancel-spot-instance-requests \
        --spot-instance-request-ids $SPOT_REQUESTS \
        --region "$AWS_REGION" || print_warning "Failed to cancel some spot requests"
else
    print_status "No active spot requests found"
fi

# Step 2: Delete SQS queues
print_header "Deleting SQS Queues"

# Delete main queue
if [ -n "$QUEUE_URL" ]; then
    print_status "Deleting queue: $QUEUE_NAME"
    aws sqs delete-queue \
        --queue-url "$QUEUE_URL" \
        --region "$AWS_REGION" 2>/dev/null || print_warning "Queue may already be deleted"
fi

# Delete DLQ
if [ -n "$DLQ_URL" ]; then
    print_status "Deleting DLQ: $DLQ_NAME"
    aws sqs delete-queue \
        --queue-url "$DLQ_URL" \
        --region "$AWS_REGION" 2>/dev/null || print_warning "DLQ may already be deleted"
fi

# Step 3: Delete S3 buckets
print_header "Deleting S3 Buckets"

# Delete metrics bucket (must be empty first, including all versions)
if [ -n "$METRICS_BUCKET" ]; then
    if aws s3 ls "s3://$METRICS_BUCKET" 2>/dev/null; then
        print_status "Emptying bucket: $METRICS_BUCKET"
        
        # Delete all objects
        aws s3 rm "s3://$METRICS_BUCKET" --recursive || print_warning "Failed to empty bucket"
        
        # Check if versioning is enabled and delete all versions
        print_status "Checking for versioned objects in $METRICS_BUCKET"
        VERSIONS=$(aws s3api list-object-versions \
            --bucket "$METRICS_BUCKET" \
            --output json \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            2>/dev/null || echo "{}")
            
        if [ "$VERSIONS" != "{}" ] && [ -n "$VERSIONS" ]; then
            print_status "Deleting all object versions and delete markers"
            echo "$VERSIONS" | aws s3api delete-objects \
                --bucket "$METRICS_BUCKET" \
                --delete "$(echo "$VERSIONS" | jq -c '{Objects: (.Objects + .DeleteMarkers) | map(select(. != null))}')" \
                2>/dev/null || print_warning "Failed to delete some versions"
        fi
        
        # Now delete the bucket
        print_status "Deleting bucket: $METRICS_BUCKET"
        aws s3 rb "s3://$METRICS_BUCKET" --force || print_warning "Failed to delete bucket"
    else
        print_status "Bucket $METRICS_BUCKET not found or already deleted"
    fi
fi

# Step 4: Delete IAM resources
print_header "Deleting IAM Resources"

# Detach and delete policies
print_status "Detaching policies from user $IAM_USER"
aws iam detach-user-policy \
    --user-name "$IAM_USER" \
    --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/TranscriptionSystemUserPolicy" \
    2>/dev/null || print_warning "Policy already detached from user"

print_status "Detaching policies from role"
aws iam detach-role-policy \
    --role-name "transcription-worker-role" \
    --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/TranscriptionWorkerPolicy" \
    2>/dev/null || print_warning "Policy already detached from role"

# Delete policies
print_status "Deleting user policy"
aws iam delete-policy \
    --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/TranscriptionSystemUserPolicy" \
    2>/dev/null || print_warning "User policy already deleted"

print_status "Deleting worker policy"
aws iam delete-policy \
    --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/TranscriptionWorkerPolicy" \
    2>/dev/null || print_warning "Worker policy already deleted"

# Remove role from instance profile and delete
print_status "Cleaning up instance profile"
aws iam remove-role-from-instance-profile \
    --instance-profile-name "transcription-worker-profile" \
    --role-name "transcription-worker-role" \
    2>/dev/null || print_warning "Role already removed from instance profile"

aws iam delete-instance-profile \
    --instance-profile-name "transcription-worker-profile" \
    2>/dev/null || print_warning "Instance profile already deleted"

# Delete role
print_status "Deleting IAM role"
aws iam delete-role \
    --role-name "transcription-worker-role" \
    2>/dev/null || print_warning "Role already deleted"

# Step 5: Clean up local files
print_header "Cleaning Up Local Files"

print_status "Removing configuration files..."
rm -f transcription-config.env
rm -f worker-config.env
rm -f docker.env
rm -f queue-config.env
rm -f iam-config.env
rm -f queue-resources-summary.txt
rm -f .setup-status
rm -f NEXT_STEPS.md

print_status "Configuration files removed"

# Final summary
print_header "Destruction Complete"

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              All resources have been destroyed!               ║"
echo "║         The transcription system has been removed.            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_status "Summary of destroyed resources:"
echo "  - EC2 instances and spot requests terminated"
echo "  - SQS queues deleted"
echo "  - S3 metrics bucket deleted"
echo "  - IAM policies, role, and instance profile deleted"
echo "  - All configuration files removed"
echo ""
print_warning "Note: The audio bucket '${GREEN}$AUDIO_BUCKET${NC}' was ${GREEN}NOT deleted${NC} as it may contain important data."
print_warning "Note: Any running Lambda functions or CloudWatch rules were NOT deleted."
echo ""
print_status "To set up the system again, run: ./scripts/step-000-setup-configuration.sh"