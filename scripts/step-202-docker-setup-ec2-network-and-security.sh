#!/bin/bash

# step-202-docker-setup-ec2-network-and-security.sh - Setup EC2 network, security groups, and key pairs for Docker GPU instances (PATH 200)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Please run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Setting up EC2 configuration for DLAMI on-demand workers (PATH 100)..."
echo -e "${GREEN}[INFO]${NC} AWS Region: $AWS_REGION"

# Check if EC2 configuration is already complete
if [ -n "$SECURITY_GROUP_ID" ] && [ -n "$KEY_NAME" ] && [ -n "$SUBNET_ID" ]; then
    echo -e "${YELLOW}[WARNING]${NC} EC2 configuration already exists:"
    echo "  Security Group: $SECURITY_GROUP_ID"
    echo "  Key Name: $KEY_NAME"
    echo "  Subnet: $SUBNET_ID"
    read -p "Do you want to reconfigure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}[INFO]${NC} Using existing configuration"
        exit 0
    fi
fi

# Get default VPC
echo -e "${GREEN}[INFO]${NC} Getting default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    echo -e "${RED}[ERROR]${NC} No default VPC found. Please create a VPC first."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Default VPC: $VPC_ID"

# Get first available subnet in the VPC
echo -e "${GREEN}[INFO]${NC} Getting available subnet..."
SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[0].SubnetId" \
    --output text)

echo -e "${GREEN}[INFO]${NC} Selected subnet: $SUBNET_ID"

# Create security group
echo -e "${GREEN}[INFO]${NC} Creating security group for transcription workers..."
SECURITY_GROUP_NAME="transcription-worker-sg-${ENVIRONMENT}"

# Check if security group already exists
EXISTING_SG=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" != "None" ]; then
    echo -e "${YELLOW}[WARNING]${NC} Security group $SECURITY_GROUP_NAME already exists: $EXISTING_SG"
    SECURITY_GROUP_ID=$EXISTING_SG
else
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SECURITY_GROUP_NAME" \
        --description "Security group for transcription worker instances" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)
    
    echo -e "${GREEN}[INFO]${NC} Created security group: $SECURITY_GROUP_ID"
    
    # Add SSH access (restrict this to your IP in production)
    echo -e "${GREEN}[INFO]${NC} Adding SSH access rule..."
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        >/dev/null 2>&1 || echo -e "${YELLOW}[WARNING]${NC} SSH rule already exists"
fi

# Create or get SSH key pair
echo -e "${GREEN}[INFO]${NC} Setting up SSH key pair..."
KEY_NAME="transcription-worker-key-${ENVIRONMENT}"

# Check if key pair exists
KEY_EXISTS=$(aws ec2 describe-key-pairs \
    --region "$AWS_REGION" \
    --key-names "$KEY_NAME" \
    --query "KeyPairs[0].KeyName" \
    --output text 2>/dev/null || echo "None")

if [ "$KEY_EXISTS" != "None" ]; then
    echo -e "${YELLOW}[WARNING]${NC} Key pair $KEY_NAME already exists"
else
    echo -e "${GREEN}[INFO]${NC} Creating new key pair..."
    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --query "KeyMaterial" \
        --output text > "${KEY_NAME}.pem"
    
    chmod 600 "${KEY_NAME}.pem"
    echo -e "${GREEN}[INFO]${NC} Key pair created and saved to ${KEY_NAME}.pem"
    echo -e "${YELLOW}[WARNING]${NC} Keep this key file safe! It's needed to SSH into your instances."
fi

# Get the latest Deep Learning AMI
echo -e "${GREEN}[INFO]${NC} Finding latest Deep Learning AMI..."
LATEST_DL_AMI=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

if [ "$LATEST_DL_AMI" != "None" ] && [ -n "$LATEST_DL_AMI" ]; then
    echo -e "${GREEN}[INFO]${NC} Found Deep Learning AMI: $LATEST_DL_AMI"
    AMI_ID=$LATEST_DL_AMI
else
    echo -e "${YELLOW}[WARNING]${NC} Could not find Deep Learning AMI, using configured AMI: $AMI_ID"
fi

# Update .env file with EC2 configuration
echo -e "${GREEN}[INFO]${NC} Updating configuration file..."

# Create temporary file with updated values
cp "$CONFIG_FILE" "${CONFIG_FILE}.tmp"

# Update the values in the temp file
sed -i "s|^export SECURITY_GROUP_ID=.*|export SECURITY_GROUP_ID=\"$SECURITY_GROUP_ID\"|" "${CONFIG_FILE}.tmp"
sed -i "s|^export KEY_NAME=.*|export KEY_NAME=\"$KEY_NAME\"|" "${CONFIG_FILE}.tmp"
sed -i "s|^export SUBNET_ID=.*|export SUBNET_ID=\"$SUBNET_ID\"|" "${CONFIG_FILE}.tmp"
sed -i "s|^export AMI_ID=.*|export AMI_ID=\"$AMI_ID\"|" "${CONFIG_FILE}.tmp"

# Move temp file to replace original
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo -e "${GREEN}[INFO]${NC} Configuration updated"

# Display summary
echo
echo -e "${GREEN}[INFO]${NC} === EC2 Configuration Complete ==="
echo
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo "Security Group: $SECURITY_GROUP_ID"
echo "Key Name: $KEY_NAME"
echo "AMI ID: $AMI_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Instance Pricing: On-Demand (reliable, no interruption risk)"
echo
# Auto-detect and show next step
if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
    source "$(dirname "$0")/next-step-helper.sh"
    show_next_step "$0" "$(dirname "$0")"
fi
echo
echo -e "${GREEN}[INFO]${NC} EC2 configuration saved to $CONFIG_FILE"

# Update setup status
echo "step-202-completed=$(date)" >> .setup-status
echo -e "${GREEN}[INFO]${NC} Docker EC2 network and security setup complete"