#!/bin/bash

# step-425-voxtral-fix-ssh-access.sh - Fix SSH access to Real Voxtral instances

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
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🔧 Fix SSH Access to Real Voxtral${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Get current public IP
echo -e "${GREEN}[STEP 1]${NC} Getting current public IP..."
MY_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
if [ -z "$MY_PUBLIC_IP" ]; then
    echo -e "${RED}[ERROR]${NC} Could not determine public IP"
    exit 1
fi
echo "Current public IP: $MY_PUBLIC_IP"

# Check security group exists
echo -e "${GREEN}[STEP 2]${NC} Validating security group..."
if ! aws ec2 describe-security-groups --group-ids "$SECURITY_GROUP_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Security group not found: $SECURITY_GROUP_ID"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Security group validated: $SECURITY_GROUP_ID"

# Check current SSH rules
echo -e "${GREEN}[STEP 3]${NC} Checking current SSH rules..."
CURRENT_SSH_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`]' \
    --output json)

echo "Current SSH rules:"
echo "$CURRENT_SSH_RULES" | jq -r '.[] | "  Port \(.FromPort): \(.IpRanges[].CidrIp // .UserIdGroupPairs[].GroupId // "No source")"'

# Check if current IP already has access
IP_HAS_ACCESS=$(echo "$CURRENT_SSH_RULES" | jq -r --arg ip "$MY_PUBLIC_IP/32" '.[] | select(.IpRanges[]?.CidrIp == $ip) | "found"')

if [ "$IP_HAS_ACCESS" = "found" ]; then
    echo -e "${GREEN}[OK]${NC} Current IP already has SSH access"
else
    echo -e "${YELLOW}[INFO]${NC} Current IP does not have SSH access"
    
    # Add SSH access for current IP
    echo -e "${GREEN}[STEP 4]${NC} Adding SSH access for current IP..."
    
    echo "Adding rule: $MY_PUBLIC_IP/32 -> port 22"
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "$MY_PUBLIC_IP/32" \
        --region "$AWS_REGION" || echo "Rule may already exist"
    
    echo -e "${GREEN}[OK]${NC} SSH access added for $MY_PUBLIC_IP"
fi

# Find Real Voxtral instances
echo -e "${GREEN}[STEP 5]${NC} Finding Real Voxtral instances..."
REAL_VOXTRAL_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=real-voxtral-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,State.Name]' \
    --output json)

if [ "$REAL_VOXTRAL_INSTANCES" = "[]" ]; then
    echo -e "${YELLOW}[WARNING]${NC} No running Real Voxtral instances found"
    echo "Launch instances first with: ./scripts/step-420-voxtral-launch-gpu-instances.sh"
else
    echo "Real Voxtral instances found:"
    echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "\(.[0]) - \(.[1]) - \(.[2])"'
fi

# Test SSH connectivity
echo -e "${GREEN}[STEP 6]${NC} Testing SSH connectivity..."

if [ "$REAL_VOXTRAL_INSTANCES" != "[]" ]; then
    FIRST_IP=$(echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[0][0][1]')
    
    if [ "$FIRST_IP" != "null" ] && [ -n "$FIRST_IP" ]; then
        echo "Testing SSH to: $FIRST_IP"
        
        if ssh -i "$KEY_NAME.pem" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$FIRST_IP" "echo 'SSH test successful'" 2>/dev/null; then
            echo -e "${GREEN}✓ SSH connectivity confirmed${NC}"
        else
            echo -e "${RED}✗ SSH connectivity failed${NC}"
            echo "Possible issues:"
            echo "  1. Instance still starting (wait 2-3 minutes)"
            echo "  2. Key file permissions: chmod 400 $KEY_NAME.pem"
            echo "  3. Key file path: ensure $KEY_NAME.pem exists"
        fi
    else
        echo -e "${YELLOW}[INFO]${NC} No public IP available for testing"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} No instances to test"
fi

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ SSH Access Configuration Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[CONFIGURATION SUMMARY]${NC}"
echo "Your IP: $MY_PUBLIC_IP"
echo "Security Group: $SECURITY_GROUP_ID"
echo "Key Pair: $KEY_NAME"
echo
if [ "$REAL_VOXTRAL_INSTANCES" != "[]" ]; then
    echo -e "${GREEN}[SSH COMMANDS]${NC}"
    echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "ssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1])"'
    echo
    echo -e "${GREEN}[MONITORING COMMANDS]${NC}"
    echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "# Instance \(.[0])\nssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1]) \"sudo tail -f /var/log/voxtral-startup.log\"\nssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1]) \"docker logs real-voxtral-worker\"\n"'
else
    echo -e "${YELLOW}[NOTE]${NC} Launch Real Voxtral instances first:"
    echo "  ./scripts/step-420-voxtral-launch-gpu-instances.sh"
fi

echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Check Real Voxtral health:"
echo "   ./scripts/step-426-voxtral-check-gpu-health.sh"
echo
echo "2. Test transcription:"
echo "   ./scripts/step-430-voxtral-test-transcription.sh"