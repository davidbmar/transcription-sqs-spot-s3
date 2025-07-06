#!/bin/bash

# step-010-setup-iam-permissions.sh - Set up IAM permissions for the transcription system

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

# Use configuration values (with fallbacks for backward compatibility)
REGION="${AWS_REGION:-us-east-2}"
IAM_USER="${IAM_USER:-davidbmar}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_status "Setting up IAM permissions for transcription system..."

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_status "AWS Account ID: $ACCOUNT_ID"
print_status "IAM User: $IAM_USER"

# Step 1: Create IAM policy for user
print_status "Creating IAM policy for user permissions..."

cat > /tmp/transcription-user-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SQSFullAccess",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:SetQueueAttributes",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ListQueues",
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:PurgeQueue",
        "sqs:TagQueue",
        "sqs:UntagQueue",
        "sqs:ListQueueTags"
      ],
      "Resource": [
        "arn:aws:sqs:*:$ACCOUNT_ID:*"
      ]
    },
    {
      "Sid": "S3BucketOperations",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetBucketAcl",
        "s3:PutBucketAcl",
        "s3:GetBucketPolicy",
        "s3:PutBucketPolicy",
        "s3:DeleteBucket"
      ],
      "Resource": [
        "arn:aws:s3:::transcription-metrics-*",
        "arn:aws:s3:::dbm-cf-2-web",
        "arn:aws:s3:::audio-transcription-*"
      ]
    },
    {
      "Sid": "S3ObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectVersion",
        "s3:ListMultipartUploadParts",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::transcription-metrics-*/*",
        "arn:aws:s3:::dbm-cf-2-web/*",
        "arn:aws:s3:::audio-transcription-*/*"
      ]
    },
    {
      "Sid": "S3ListAllBuckets",
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    },
    {
      "Sid": "EC2SpotOperations",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeSpotInstanceRequests",
        "ec2:DescribeSpotPriceHistory",
        "ec2:RequestSpotInstances",
        "ec2:CancelSpotInstanceRequests",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DescribeTags",
        "ec2:CreateLaunchTemplate",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeImages",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMRoleOperations",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:CreatePolicy",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:CreateInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::$ACCOUNT_ID:role/transcription-*",
        "arn:aws:iam::$ACCOUNT_ID:policy/transcription-*",
        "arn:aws:iam::$ACCOUNT_ID:instance-profile/transcription-*"
      ]
    },
    {
      "Sid": "STSOperations",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Check if policy already exists
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/TranscriptionSystemUserPolicy"
if aws iam get-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
    print_warning "Policy already exists, updating..."
    
    # Create new version of the policy
    POLICY_VERSION=$(aws iam create-policy-version \
        --policy-arn "$POLICY_ARN" \
        --policy-document file:///tmp/transcription-user-policy.json \
        --set-as-default \
        --query 'PolicyVersion.VersionId' \
        --output text)
    
    print_status "Policy updated with version: $POLICY_VERSION"
else
    # Create the policy
    POLICY_ARN=$(aws iam create-policy \
        --policy-name TranscriptionSystemUserPolicy \
        --policy-document file:///tmp/transcription-user-policy.json \
        --description "Permissions for audio transcription system operations" \
        --query 'Policy.Arn' \
        --output text)
    
    print_status "Policy created: $POLICY_ARN"
fi

# Step 2: Attach policy to user
print_status "Attaching policy to user $IAM_USER..."

# Check if already attached
if aws iam list-attached-user-policies --user-name "$IAM_USER" | grep -q "$POLICY_ARN"; then
    print_warning "Policy already attached to user"
else
    aws iam attach-user-policy \
        --user-name "$IAM_USER" \
        --policy-arn "$POLICY_ARN"
    
    print_status "Policy attached to user successfully"
fi

# Step 3: Create IAM role for EC2 instances (if it doesn't exist)
print_status "Setting up EC2 instance role..."

ROLE_NAME="transcription-worker-role"
INSTANCE_PROFILE_NAME="transcription-worker-profile"

# Check if role exists
if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    print_warning "Role $ROLE_NAME already exists"
else
    # Create trust policy for EC2
    cat > /tmp/ec2-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # Create the role
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --description "Role for transcription worker EC2 instances"
    
    print_status "Role created: $ROLE_NAME"
    
    # Create instance profile
    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME"
    
    # Add role to instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
    
    print_status "Instance profile created and linked to role"
fi

# Create worker policy
cat > /tmp/transcription-worker-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Access",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::transcription-metrics-*/*",
        "arn:aws:s3:::dbm-cf-2-web/*",
        "arn:aws:s3:::audio-transcription-*/*",
        "arn:aws:s3:::transcription-metrics-*",
        "arn:aws:s3:::dbm-cf-2-web",
        "arn:aws:s3:::audio-transcription-*"
      ]
    },
    {
      "Sid": "SQSAccess",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": "arn:aws:sqs:*:$ACCOUNT_ID:*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:$ACCOUNT_ID:*"
    }
  ]
}
EOF

# Attach policy to role
WORKER_POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/TranscriptionWorkerPolicy"
if aws iam get-policy --policy-arn "$WORKER_POLICY_ARN" 2>/dev/null; then
    print_warning "Worker policy already exists"
else
    aws iam create-policy \
        --policy-name TranscriptionWorkerPolicy \
        --policy-document file:///tmp/transcription-worker-policy.json \
        --description "Permissions for transcription worker EC2 instances"
    
    print_status "Worker policy created"
fi

# Attach policy to role
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" | grep -q "$WORKER_POLICY_ARN"; then
    print_warning "Worker policy already attached to role"
else
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$WORKER_POLICY_ARN"
    
    print_status "Worker policy attached to role"
fi

# Clean up temporary files
rm -f /tmp/transcription-user-policy.json
rm -f /tmp/transcription-worker-policy.json
rm -f /tmp/ec2-trust-policy.json

# Print summary
echo ""
print_status "=== IAM Setup Complete ==="
echo ""
echo "User Policy: $POLICY_ARN"
echo "  Attached to: $IAM_USER"
echo ""
echo "EC2 Instance Role: $ROLE_NAME"
echo "  Instance Profile: $INSTANCE_PROFILE_NAME"
echo "  Worker Policy: $WORKER_POLICY_ARN"
echo ""
echo "Next steps:"
echo "1. Run ./scripts/step-010-create-sqs_resources.sh to create SQS queues"
echo "2. The IAM permissions are now configured for all transcription operations"
echo ""

# Save configuration
cat > iam-config.env << EOF
# IAM Configuration
export AWS_ACCOUNT_ID="$ACCOUNT_ID"
export IAM_USER="$IAM_USER"
export USER_POLICY_ARN="$POLICY_ARN"
export WORKER_ROLE_NAME="$ROLE_NAME"
export WORKER_INSTANCE_PROFILE="$INSTANCE_PROFILE_NAME"
export WORKER_POLICY_ARN="$WORKER_POLICY_ARN"
EOF

print_status "IAM configuration saved to iam-config.env"