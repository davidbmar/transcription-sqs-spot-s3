#!/bin/bash

# step-000-setup-configuration.sh - Interactive configuration setup for transcription system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
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

print_prompt() {
    echo -e "${CYAN}$1${NC}"
}

# Function to get user input with default value
get_input() {
    local prompt=$1
    local default=$2
    local var_name=$3
    
    if [ -n "$default" ]; then
        print_prompt "$prompt [$default]: "
    else
        print_prompt "$prompt: "
    fi
    
    read -r user_input
    
    if [ -z "$user_input" ] && [ -n "$default" ]; then
        eval "$var_name='$default'"
    else
        eval "$var_name='$user_input'"
    fi
}

# Function to validate AWS region
validate_region() {
    local region=$1
    aws ec2 describe-regions --region-names "$region" &>/dev/null
}

# Function to check if S3 bucket exists
check_bucket_exists() {
    local bucket=$1
    aws s3 ls "s3://$bucket" &>/dev/null
}

# Check if .env.template exists
if [ ! -f ".env.template" ]; then
    print_error ".env.template not found. Please make sure it exists in the project root."
    exit 1
fi

# Check if .env already exists
if [ -f ".env" ]; then
    print_warning ".env file already exists."
    echo -e "${CYAN}Do you want to recreate it? (y/n) [n]: ${NC}"
    read -r recreate
    if [ "$recreate" != "y" ] && [ "$recreate" != "Y" ]; then
        print_status "Using existing .env file"
        exit 0
    fi
fi

# Copy template to .env
cp .env.template .env
print_status "Created .env from template"

# Main configuration script
clear
echo -e "${MAGENTA}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          Audio Transcription System Configuration             ║"
echo "║                    Initial Setup Wizard                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_status "This script will help you configure the audio transcription system."
print_status "It will create .env file with your specific values."
echo ""

# Get AWS Account Info
print_header "AWS Account Information"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    print_error "Unable to get AWS account ID. Please ensure AWS CLI is configured."
    exit 1
fi

IAM_USER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | cut -d'/' -f2 || echo "")
print_status "AWS Account ID: $ACCOUNT_ID"
print_status "IAM User: $IAM_USER"

# Basic Configuration
print_header "Basic Configuration"

get_input "AWS Region" "us-east-2" AWS_REGION
while ! validate_region "$AWS_REGION"; do
    print_error "Invalid region: $AWS_REGION"
    get_input "Please enter a valid AWS Region" "us-east-2" AWS_REGION
done

get_input "Environment name (dev/staging/prod)" "dev" ENVIRONMENT

# Queue Configuration
print_header "SQS Queue Configuration"

DEFAULT_QUEUE_PREFIX="audio-transcription"
if [ "$ENVIRONMENT" != "prod" ]; then
    DEFAULT_QUEUE_PREFIX="${DEFAULT_QUEUE_PREFIX}-${ENVIRONMENT}"
fi

get_input "Queue name prefix" "$DEFAULT_QUEUE_PREFIX" QUEUE_PREFIX
QUEUE_NAME="${QUEUE_PREFIX}-queue"
DLQ_NAME="${QUEUE_PREFIX}-dlq"

print_status "Main Queue: $QUEUE_NAME"
print_status "Dead Letter Queue: $DLQ_NAME"

get_input "Message retention period (days)" "14" RETENTION_DAYS
RETENTION_SECONDS=$((RETENTION_DAYS * 86400))

get_input "Visibility timeout (seconds)" "1800" VISIBILITY_TIMEOUT
get_input "Max receive count before DLQ" "3" MAX_RECEIVE_COUNT

# S3 Configuration
print_header "S3 Bucket Configuration"

# Metrics bucket
DEFAULT_METRICS_BUCKET="transcription-metrics-${ENVIRONMENT}-$(date +%Y%m%d)"
get_input "Metrics bucket name" "$DEFAULT_METRICS_BUCKET" METRICS_BUCKET

# Audio storage bucket
get_input "Audio files S3 bucket" "dbm-cf-2-web" AUDIO_BUCKET
if ! check_bucket_exists "$AUDIO_BUCKET"; then
    print_warning "Bucket '$AUDIO_BUCKET' not found or not accessible"
    get_input "Create this bucket? (yes/no)" "no" CREATE_AUDIO_BUCKET
fi

# Worker Configuration
print_header "Worker Configuration"

get_input "Default Whisper model" "large-v3" WHISPER_MODEL
get_input "Worker idle timeout (minutes)" "5" IDLE_TIMEOUT_MINUTES
get_input "Default chunk size (seconds)" "30" CHUNK_SIZE

# EC2/Spot Configuration
print_header "EC2 Spot Instance Configuration"

get_input "Instance type" "g4dn.xlarge" INSTANCE_TYPE
get_input "Maximum spot price (USD)" "0.50" SPOT_PRICE
get_input "AMI ID (leave blank for Ubuntu 22.04 default)" "" AMI_ID

if [ -z "$AMI_ID" ]; then
    # Get latest Ubuntu 22.04 AMI
    print_status "Finding latest Ubuntu 22.04 AMI..."
    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                  "Name=state,Values=available" \
        --query 'Images[0].ImageId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "ami-0c7217cdde317cfec")
    print_status "Using AMI: $AMI_ID"
fi

# Optional: existing resources
print_header "Existing Resources (Optional)"

get_input "EC2 Security Group ID (leave blank to skip)" "" SECURITY_GROUP_ID
get_input "EC2 Key Pair name (leave blank to skip)" "" KEY_NAME
get_input "VPC Subnet ID (leave blank for default)" "" SUBNET_ID

# Scaling Configuration
print_header "Auto-Scaling Configuration"

get_input "Minimum instances" "0" MIN_INSTANCES
get_input "Maximum instances" "10" MAX_INSTANCES
get_input "Minutes of work per instance per hour" "60" MINUTES_PER_INSTANCE_HOUR
get_input "Scale up threshold (pending minutes)" "30" SCALE_UP_THRESHOLD
get_input "Scale down threshold (pending minutes per instance)" "10" SCALE_DOWN_THRESHOLD

# Summary
print_header "Configuration Summary"

echo "AWS Configuration:"
echo "  Account ID: $ACCOUNT_ID"
echo "  Region: $AWS_REGION"
echo "  IAM User: $IAM_USER"
echo "  Environment: $ENVIRONMENT"
echo ""
echo "Queue Configuration:"
echo "  Queue Name: $QUEUE_NAME"
echo "  DLQ Name: $DLQ_NAME"
echo "  Retention: $RETENTION_DAYS days"
echo "  Visibility Timeout: $VISIBILITY_TIMEOUT seconds"
echo ""
echo "S3 Configuration:"
echo "  Metrics Bucket: $METRICS_BUCKET"
echo "  Audio Bucket: $AUDIO_BUCKET"
echo ""
echo "Worker Configuration:"
echo "  Whisper Model: $WHISPER_MODEL"
echo "  Idle Timeout: $IDLE_TIMEOUT_MINUTES minutes"
echo "  Chunk Size: $CHUNK_SIZE seconds"
echo ""
echo "EC2 Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Spot Price: \$$SPOT_PRICE"
echo "  AMI ID: $AMI_ID"
echo ""
echo "Scaling Configuration:"
echo "  Min Instances: $MIN_INSTANCES"
echo "  Max Instances: $MAX_INSTANCES"
echo ""

get_input "Is this configuration correct? (yes/no)" "yes" CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    print_warning "Configuration cancelled. Please run the script again."
    exit 1
fi

# Create configuration files
print_header "Creating Configuration Files"

# Main configuration file
CONFIG_FILE=".env"
print_status "Updating $CONFIG_FILE with your configuration..."

# Function to update .env file
update_env_var() {
    local var_name=$1
    local var_value=$2
    sed -i "s/^export ${var_name}=.*/export ${var_name}=\"${var_value}\"/" "$CONFIG_FILE"
}

# Update all variables in .env file
update_env_var "AWS_ACCOUNT_ID" "$ACCOUNT_ID"
update_env_var "AWS_REGION" "$AWS_REGION"
update_env_var "IAM_USER" "$IAM_USER"
update_env_var "ENVIRONMENT" "$ENVIRONMENT"
update_env_var "QUEUE_NAME" "$QUEUE_NAME"
update_env_var "DLQ_NAME" "$DLQ_NAME"
update_env_var "QUEUE_PREFIX" "$QUEUE_PREFIX"
update_env_var "MESSAGE_RETENTION_SECONDS" "$RETENTION_SECONDS"
update_env_var "VISIBILITY_TIMEOUT" "$VISIBILITY_TIMEOUT"
update_env_var "MAX_RECEIVE_COUNT" "$MAX_RECEIVE_COUNT"
update_env_var "METRICS_BUCKET" "$METRICS_BUCKET"
update_env_var "AUDIO_BUCKET" "$AUDIO_BUCKET"
update_env_var "WHISPER_MODEL" "$WHISPER_MODEL"
update_env_var "IDLE_TIMEOUT_MINUTES" "$IDLE_TIMEOUT_MINUTES"
update_env_var "CHUNK_SIZE" "$CHUNK_SIZE"
update_env_var "INSTANCE_TYPE" "$INSTANCE_TYPE"
update_env_var "SPOT_PRICE" "$SPOT_PRICE"
update_env_var "AMI_ID" "$AMI_ID"
update_env_var "SECURITY_GROUP_ID" "$SECURITY_GROUP_ID"
update_env_var "KEY_NAME" "$KEY_NAME"
update_env_var "SUBNET_ID" "$SUBNET_ID"
update_env_var "MIN_INSTANCES" "$MIN_INSTANCES"
update_env_var "MAX_INSTANCES" "$MAX_INSTANCES"
update_env_var "SCALE_UP_THRESHOLD" "$SCALE_UP_THRESHOLD"
update_env_var "SCALE_DOWN_THRESHOLD" "$SCALE_DOWN_THRESHOLD"

print_status "Configuration saved to $CONFIG_FILE"

# Update setup status
print_status "Updating setup status..."

# Create a setup status file
SETUP_STATUS_FILE=".setup-status"
print_status "Creating $SETUP_STATUS_FILE..."

cat > "$SETUP_STATUS_FILE" << EOF
# Setup Status Tracker
STEP_000_COMPLETE=$(date)
STEP_000_COMPLETE=
STEP_000_COMPLETE=
CONFIGURATION_VERSION=1.0
EOF

# Create next steps guide
NEXT_STEPS_FILE="NEXT_STEPS.md"
print_status "Creating $NEXT_STEPS_FILE..."

cat > "$NEXT_STEPS_FILE" << EOF
# Audio Transcription System - Next Steps

## Configuration Completed ✅

Your configuration has been saved to \`.env\`.

## Next Steps

### 1. Set up IAM permissions (step-010)
\`\`\`bash
./scripts/step-010-setup-iam-permissions.sh
\`\`\`

### 2. Create SQS queues and S3 buckets (step-020)
\`\`\`bash
# Source the configuration first
source .env

# Run the setup script
./scripts/step-020-create-sqs-resources.sh
\`\`\`

### 3. Test sending a message
\`\`\`bash
python3 scripts/send_to_queue.py \\
  --queue_url "\$QUEUE_URL" \\
  --s3_input_path "s3://bucket/audio.mp3" \\
  --s3_output_path "s3://bucket/transcript.json" \\
  --estimated_duration_seconds 300
\`\`\`

### 4. Launch a worker
\`\`\`bash
./scripts/launch-spot-worker.sh
\`\`\`

### 5. Set up auto-scaling (optional)
- For Lambda-based scaling: Deploy \`scripts/scaling_lambda.py\`
- For cron-based scaling: Add \`scripts/scaling_cron.sh\` to crontab

## Configuration Files Created

- \`.env\` - Main configuration file
- \`.setup-status\` - Setup progress tracker

## Important Notes

- Always source \`.env\` before running scripts
- The QUEUE_URL will be set after running step-020
- Update security group and key pair if launching EC2 instances
EOF

print_header "Installing Python Dependencies"

# Create virtual environment if it doesn't exist
if [ ! -d "venv" ]; then
    print_status "Creating Python virtual environment..."
    python3 -m venv venv
fi

# Install dependencies in virtual environment
print_status "Installing Python dependencies in virtual environment..."
if source venv/bin/activate && pip install -r requirements.txt; then
    print_status "Python dependencies installed successfully"
    print_status "To activate the virtual environment: source venv/bin/activate"
else
    print_warning "Failed to install dependencies. You may need to install them manually:"
    print_warning "  python3 -m venv venv"
    print_warning "  source venv/bin/activate"
    print_warning "  pip install -r requirements.txt"
fi

print_header "Setup Complete!"

print_status "Configuration files created:"
echo "  - $CONFIG_FILE (main configuration)"
echo "  - $SETUP_STATUS_FILE (setup progress)"
echo "  - $NEXT_STEPS_FILE (next steps guide)"
echo ""
print_status "To use this configuration in other scripts:"
echo -e "${GREEN}  source $CONFIG_FILE${NC}"
echo ""
print_status "Next step: Run ${GREEN}./scripts/step-010-setup-iam-permissions.sh${NC}"