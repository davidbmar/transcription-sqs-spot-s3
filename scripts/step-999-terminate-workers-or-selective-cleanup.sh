#!/bin/bash

# step-999-terminate-workers-or-selective-cleanup.sh - Clean up AWS resources created by the transcription system

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display script information
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Selective Resource Cleanup Script                    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${YELLOW}This script provides selective cleanup options:${NC}"
echo
echo -e "${GREEN}Option 1: --workers-only${NC}"
echo "  • Terminates all EC2 spot instances (workers)"
echo "  • Cancels active spot requests"
echo "  • Preserves SQS queues and S3 buckets"
echo "  • Use when you want to stop workers but keep infrastructure"
echo
echo -e "${GREEN}Option 2: --all${NC}"
echo "  • Removes ALL resources except audio bucket:"
echo "    - EC2 instances and spot requests"
echo "    - SQS queues (main + DLQ)"
echo "    - S3 metrics bucket"
echo "    - Security groups and key pairs"
echo "    - IAM roles and policies"
echo "  • Preserves audio bucket to prevent data loss"
echo "  • Use for complete cleanup while keeping your data"
echo
echo -e "${YELLOW}Usage:${NC} $0 [--workers-only | --all]"
echo

# Parse command line arguments
CLEANUP_WORKERS_ONLY=0
CLEANUP_ALL=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --workers-only)
            CLEANUP_WORKERS_ONLY=1
            shift
            ;;
        --all)
            CLEANUP_ALL=1
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --workers-only    Only terminate EC2 instances (keep queues/buckets)"
            echo "  --all            Remove all resources (instances, queues, buckets, IAM)"
            echo "  --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if no options provided
if [ $CLEANUP_WORKERS_ONLY -eq 0 ] && [ $CLEANUP_ALL -eq 0 ]; then
    echo -e "${RED}[ERROR]${NC} No cleanup option specified."
    echo
    echo "Please specify one of:"
    echo "  $0 --workers-only    # Terminate EC2 instances only"
    echo "  $0 --all            # Remove all resources"
    echo
    exit 1
fi

# Confirmation prompt
if [ $CLEANUP_WORKERS_ONLY -eq 1 ]; then
    echo -e "${YELLOW}You selected: --workers-only${NC}"
    echo "This will terminate all EC2 worker instances but preserve queues and buckets."
    echo
    read -p "Do you want to proceed? (yes/no): " CONFIRM
elif [ $CLEANUP_ALL -eq 1 ]; then
    echo -e "${RED}You selected: --all${NC}"
    echo "This will remove ALL resources except the audio bucket!"
    echo
    read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
fi

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}[INFO]${NC} Cleanup cancelled."
    exit 0
fi

echo

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Transcription System Resource Cleanup${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Function to terminate EC2 instances
cleanup_ec2_instances() {
    echo -e "${GREEN}[STEP 1]${NC} Terminating EC2 instances..."
    
    # Find all transcription worker instances
    INSTANCES=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:Type,Values=whisper-worker" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[*].Instances[*].InstanceId" \
        --output text)
    
    if [ -z "$INSTANCES" ]; then
        echo -e "${YELLOW}[INFO]${NC} No worker instances found"
    else
        echo -e "${YELLOW}[INFO]${NC} Found instances to terminate: $INSTANCES"
        
        # Terminate instances
        aws ec2 terminate-instances \
            --region "$AWS_REGION" \
            --instance-ids $INSTANCES \
            >/dev/null
        
        echo -e "${GREEN}[OK]${NC} Instances terminated"
        
        # Wait for termination
        echo -e "${YELLOW}[INFO]${NC} Waiting for instances to terminate..."
        aws ec2 wait instance-terminated \
            --region "$AWS_REGION" \
            --instance-ids $INSTANCES
        
        echo -e "${GREEN}[OK]${NC} All instances terminated"
    fi
    
    # Cancel any open spot requests
    echo -e "${GREEN}[STEP 2]${NC} Canceling spot instance requests..."
    SPOT_REQUESTS=$(aws ec2 describe-spot-instance-requests \
        --region "$AWS_REGION" \
        --filters "Name=state,Values=open,active" \
        --query "SpotInstanceRequests[?LaunchSpecification.InstanceType=='$INSTANCE_TYPE'].SpotInstanceRequestId" \
        --output text)
    
    if [ -z "$SPOT_REQUESTS" ]; then
        echo -e "${YELLOW}[INFO]${NC} No active spot requests found"
    else
        echo -e "${YELLOW}[INFO]${NC} Canceling spot requests: $SPOT_REQUESTS"
        aws ec2 cancel-spot-instance-requests \
            --region "$AWS_REGION" \
            --spot-instance-request-ids $SPOT_REQUESTS \
            >/dev/null
        echo -e "${GREEN}[OK]${NC} Spot requests canceled"
    fi
}

# Function to cleanup all resources
cleanup_all_resources() {
    # First cleanup EC2 instances
    cleanup_ec2_instances
    
    # Cleanup SQS queues
    echo -e "${GREEN}[STEP 3]${NC} Removing SQS queues..."
    
    if [ -n "$QUEUE_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} Deleting main queue: $QUEUE_URL"
        aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION" 2>/dev/null || \
            echo -e "${YELLOW}[WARNING]${NC} Main queue not found or already deleted"
    fi
    
    if [ -n "$DLQ_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} Deleting DLQ: $DLQ_URL"
        aws sqs delete-queue --queue-url "$DLQ_URL" --region "$AWS_REGION" 2>/dev/null || \
            echo -e "${YELLOW}[WARNING]${NC} DLQ not found or already deleted"
    fi
    
    echo -e "${GREEN}[OK]${NC} SQS queues removed"
    
    # Cleanup S3 buckets
    echo -e "${GREEN}[STEP 4]${NC} Cleaning S3 buckets..."
    
    if [ -n "$METRICS_BUCKET" ]; then
        echo -e "${YELLOW}[INFO]${NC} Emptying metrics bucket: $METRICS_BUCKET"
        aws s3 rm "s3://$METRICS_BUCKET" --recursive 2>/dev/null || true
        
        echo -e "${YELLOW}[INFO]${NC} Deleting metrics bucket: $METRICS_BUCKET"
        aws s3 rb "s3://$METRICS_BUCKET" 2>/dev/null || \
            echo -e "${YELLOW}[WARNING]${NC} Metrics bucket not found or already deleted"
    fi
    
    echo -e "${GREEN}[OK]${NC} S3 buckets cleaned"
    
    # Cleanup EC2 resources
    echo -e "${GREEN}[STEP 5]${NC} Cleaning EC2 configuration..."
    
    if [ -n "$SECURITY_GROUP_ID" ]; then
        echo -e "${YELLOW}[INFO]${NC} Deleting security group: $SECURITY_GROUP_ID"
        aws ec2 delete-security-group \
            --region "$AWS_REGION" \
            --group-id "$SECURITY_GROUP_ID" 2>/dev/null || \
            echo -e "${YELLOW}[WARNING]${NC} Security group not found or in use"
    fi
    
    if [ -n "$KEY_NAME" ]; then
        echo -e "${YELLOW}[INFO]${NC} Deleting key pair: $KEY_NAME"
        aws ec2 delete-key-pair \
            --region "$AWS_REGION" \
            --key-name "$KEY_NAME" 2>/dev/null || \
            echo -e "${YELLOW}[WARNING]${NC} Key pair not found or already deleted"
        
        # Remove local key file
        if [ -f "${KEY_NAME}.pem" ]; then
            rm -f "${KEY_NAME}.pem"
            echo -e "${GREEN}[OK]${NC} Local key file removed"
        fi
    fi
    
    # Cleanup IAM resources
    echo -e "${GREEN}[STEP 6]${NC} Cleaning IAM resources..."
    
    # Detach and delete policies
    echo -e "${YELLOW}[INFO]${NC} Detaching IAM policies..."
    
    # User policy
    aws iam detach-user-policy \
        --user-name "$IAM_USER" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionSystemUserPolicy" \
        2>/dev/null || true
    
    aws iam delete-policy \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionSystemUserPolicy" \
        2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} User policy not found"
    
    # Role policy
    aws iam detach-role-policy \
        --role-name "transcription-worker-role" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionWorkerPolicy" \
        2>/dev/null || true
    
    aws iam delete-policy \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/TranscriptionWorkerPolicy" \
        2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Worker policy not found"
    
    # Remove instance profile
    echo -e "${YELLOW}[INFO]${NC} Removing instance profile..."
    aws iam remove-role-from-instance-profile \
        --instance-profile-name "transcription-worker-profile" \
        --role-name "transcription-worker-role" \
        2>/dev/null || true
    
    aws iam delete-instance-profile \
        --instance-profile-name "transcription-worker-profile" \
        2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Instance profile not found"
    
    # Delete role
    echo -e "${YELLOW}[INFO]${NC} Deleting IAM role..."
    aws iam delete-role \
        --role-name "transcription-worker-role" \
        2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Role not found"
    
    echo -e "${GREEN}[OK]${NC} IAM resources cleaned"
    
    # Clean up local files
    echo -e "${GREEN}[STEP 7]${NC} Cleaning local files..."
    rm -f .setup-status
    rm -f iam-config.env
    rm -f queue-resources-summary.txt
    
    echo -e "${GREEN}[OK]${NC} Local files cleaned"
}

# Main cleanup logic
if [ $CLEANUP_WORKERS_ONLY -eq 1 ]; then
    echo -e "${YELLOW}[INFO]${NC} Cleaning up EC2 instances only..."
    cleanup_ec2_instances
    echo
    echo -e "${GREEN}✓${NC} Worker instances terminated"
    echo -e "${YELLOW}[INFO]${NC} Queues and buckets preserved"
elif [ $CLEANUP_ALL -eq 1 ]; then
    echo -e "${RED}[WARNING]${NC} This will delete ALL resources created by the transcription system!"
    echo "This includes:"
    echo "  - All EC2 instances"
    echo "  - SQS queues (and any messages in them)"
    echo "  - S3 buckets (metrics only, not audio bucket)"
    echo "  - Security groups and key pairs"
    echo "  - IAM roles and policies"
    echo
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}[INFO]${NC} Cleanup canceled"
        exit 0
    fi
    
    echo
    cleanup_all_resources
    echo
    echo -e "${GREEN}✓${NC} All resources cleaned up"
    echo -e "${YELLOW}[INFO]${NC} To set up again, start with ./scripts/step-000-setup-configuration.sh"
fi

echo -e "${BLUE}======================================${NC}"