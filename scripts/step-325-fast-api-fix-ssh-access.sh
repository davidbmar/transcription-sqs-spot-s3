#!/bin/bash

# step-325-fast-api-fix-ssh-access.sh - Fix SSH access to Fast API GPU instances

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
echo -e "${BLUE}🔐 Fix SSH Access to Fast API Instances${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Get current public IP
echo -e "${GREEN}[STEP 1]${NC} Detecting current public IP..."
MY_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com 2>/dev/null || curl -s http://ipinfo.io/ip 2>/dev/null || echo "unknown")

if [ "$MY_PUBLIC_IP" = "unknown" ]; then
    echo -e "${RED}[ERROR]${NC} Could not detect public IP"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Current public IP: $MY_PUBLIC_IP"

# Check if this IP already has access
echo -e "${GREEN}[STEP 2]${NC} Checking existing SSH access rules..."
EXISTING_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" \
    --output text)

if echo "$EXISTING_RULES" | grep -q "$MY_PUBLIC_IP/32"; then
    echo -e "${GREEN}[OK]${NC} SSH access already granted for $MY_PUBLIC_IP"
else
    echo -e "${YELLOW}[INFO]${NC} Adding SSH access for $MY_PUBLIC_IP..."
    
    # Add SSH access for current IP
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "$MY_PUBLIC_IP/32" \
        --region "$AWS_REGION" \
        --output json > /dev/null
    
    echo -e "${GREEN}[OK]${NC} SSH access granted for $MY_PUBLIC_IP"
fi

# Show all current SSH rules
echo -e "${GREEN}[STEP 3]${NC} Current SSH access rules:"
aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].[CidrIp]" \
    --output table

# Test SSH access to Fast API instances
echo -e "${GREEN}[STEP 4]${NC} Testing SSH access to Fast API instances..."

FAST_API_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
    --output json)

INSTANCE_COUNT=$(echo "$FAST_API_INSTANCES" | jq -r '.[][] | length')

if [ "$INSTANCE_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}[INFO]${NC} No running Fast API instances found"
else
    echo "$FAST_API_INSTANCES" | jq -r '.[][]' | jq -r '@tsv' | while IFS=$'\t' read -r instance_id public_ip; do
        echo -e "\n${BLUE}Testing: $instance_id ($public_ip)${NC}"
        
        if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_NAME.pem" ubuntu@"$public_ip" "echo 'SSH connection successful'" 2>/dev/null; then
            echo -e "${GREEN}✓ SSH connection successful${NC}"
        else
            echo -e "${RED}✗ SSH connection failed${NC}"
            echo "  This could be normal if the instance is still initializing"
        fi
    done
fi

# Cleanup old/unused SSH rules (optional)
echo -e "${GREEN}[STEP 5]${NC} SSH access management complete"
echo
echo -e "${YELLOW}[OPTIONAL CLEANUP]${NC}"
echo "To remove old SSH access rules for previous IPs:"
echo "  aws ec2 revoke-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr OLD_IP/32 --region $AWS_REGION"

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ SSH Access Fixed${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Check Fast API instance health:"
echo "   ./scripts/step-326-fast-api-check-gpu-health.sh"
echo
echo "2. Test voice transcription:"
echo "   ./scripts/step-330-fast-api-test-voice-transcription.sh"
echo
echo -e "${YELLOW}[ACCESS INFO]${NC}"
echo "Your IP: $MY_PUBLIC_IP"
echo "SSH Key: $KEY_NAME.pem"
echo "Security Group: $SECURITY_GROUP_ID"