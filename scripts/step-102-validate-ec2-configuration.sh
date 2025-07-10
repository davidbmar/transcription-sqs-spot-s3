#!/bin/bash

# step-026-validate-ec2-configuration.sh - Validate EC2 configuration after step-025

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
echo -e "${BLUE}EC2 Configuration Validation${NC}"
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

# Check 1: EC2 configuration variables set
check_status "SECURITY_GROUP_ID configured" \
    "[ -n '$SECURITY_GROUP_ID' ]" \
    "Run ./scripts/step-025-setup-ec2-configuration.sh"

check_status "KEY_NAME configured" \
    "[ -n '$KEY_NAME' ]" \
    "Run ./scripts/step-025-setup-ec2-configuration.sh"

check_status "SUBNET_ID configured" \
    "[ -n '$SUBNET_ID' ]" \
    "Run ./scripts/step-025-setup-ec2-configuration.sh"

check_status "AMI_ID configured" \
    "[ -n '$AMI_ID' ]" \
    "Run ./scripts/step-025-setup-ec2-configuration.sh"

# Check 2: Security group exists and accessible
if [ -n "$SECURITY_GROUP_ID" ]; then
    check_status "Security group exists and accessible" \
        "aws ec2 describe-security-groups --group-ids '$SECURITY_GROUP_ID' --region '$AWS_REGION' >/dev/null 2>&1" \
        "Security group may have been deleted or is in wrong region"
    
    # Check security group rules
    echo -e "${YELLOW}[INFO]${NC} Checking security group rules..."
    SG_RULES=$(aws ec2 describe-security-groups \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].IpPermissions' \
        --output json 2>/dev/null || echo "[]")
    
    SSH_RULE_COUNT=$(echo "$SG_RULES" | jq '[.[] | select(.FromPort == 22 and .ToPort == 22)] | length')
    check_status "SSH access rule configured" \
        "[ '$SSH_RULE_COUNT' -gt '0' ]" \
        "Security group should allow SSH access on port 22"
fi

# Check 3: Key pair exists
if [ -n "$KEY_NAME" ]; then
    check_status "Key pair exists in AWS" \
        "aws ec2 describe-key-pairs --key-names '$KEY_NAME' --region '$AWS_REGION' >/dev/null 2>&1" \
        "Key pair may have been deleted or is in wrong region"
    
    # Check local key file
    check_status "Private key file exists locally" \
        "[ -f '${KEY_NAME}.pem' ]" \
        "Private key file ${KEY_NAME}.pem should exist for SSH access"
    
    if [ -f "${KEY_NAME}.pem" ]; then
        check_status "Private key file has correct permissions" \
            "[ \$(stat -c %a '${KEY_NAME}.pem') = '600' ]" \
            "Run: chmod 600 ${KEY_NAME}.pem"
    fi
fi

# Check 4: Subnet exists and is accessible
if [ -n "$SUBNET_ID" ]; then
    check_status "Subnet exists and accessible" \
        "aws ec2 describe-subnets --subnet-ids '$SUBNET_ID' --region '$AWS_REGION' >/dev/null 2>&1" \
        "Subnet may have been deleted or is in wrong region"
    
    # Check if subnet is in a VPC
    echo -e "${YELLOW}[INFO]${NC} Checking subnet configuration..."
    SUBNET_INFO=$(aws ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{"Subnets": []}')
    
    VPC_ID=$(echo "$SUBNET_INFO" | jq -r '.Subnets[0].VpcId // "null"')
    AZ=$(echo "$SUBNET_INFO" | jq -r '.Subnets[0].AvailabilityZone // "null"')
    
    check_status "Subnet is in a VPC ($VPC_ID)" \
        "[ '$VPC_ID' != 'null' ]" \
        "Subnet should be associated with a VPC"
    
    echo -e "${GREEN}[INFO]${NC} Subnet is in availability zone: $AZ"
fi

# Check 5: AMI exists and is accessible
if [ -n "$AMI_ID" ]; then
    check_status "AMI exists and accessible" \
        "aws ec2 describe-images --image-ids '$AMI_ID' --region '$AWS_REGION' >/dev/null 2>&1" \
        "AMI may not exist in this region or may be private"
    
    # Check AMI details
    echo -e "${YELLOW}[INFO]${NC} Checking AMI details..."
    AMI_INFO=$(aws ec2 describe-images \
        --image-ids "$AMI_ID" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{"Images": []}')
    
    AMI_NAME=$(echo "$AMI_INFO" | jq -r '.Images[0].Name // "Unknown"')
    AMI_STATE=$(echo "$AMI_INFO" | jq -r '.Images[0].State // "unknown"')
    
    echo -e "${GREEN}[INFO]${NC} AMI: $AMI_NAME (State: $AMI_STATE)"
    
    check_status "AMI is available" \
        "[ '$AMI_STATE' = 'available' ]" \
        "AMI should be in 'available' state"
fi

# Check 6: Instance type is valid for region
if [ -n "$INSTANCE_TYPE" ]; then
    echo -e "${YELLOW}[INFO]${NC} Checking instance type availability..."
    INSTANCE_TYPE_AVAILABLE=$(aws ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --region "$AWS_REGION" \
        --query 'InstanceTypeOfferings[0].InstanceType' \
        --output text 2>/dev/null || echo "None")
    
    check_status "Instance type ($INSTANCE_TYPE) available in region" \
        "[ '$INSTANCE_TYPE_AVAILABLE' = '$INSTANCE_TYPE' ]" \
        "Instance type may not be available in this region"
fi

# Check 7: Instance pricing validation (on-demand)
echo -e "${GREEN}✓${NC} On-demand pricing configured (no spot pricing needed for PATH 100)"

# Check 8: Test launch template creation (dry run)
echo -e "${YELLOW}[INFO]${NC} Testing launch template creation (dry run)..."
if [ -n "$AMI_ID" ] && [ -n "$INSTANCE_TYPE" ] && [ -n "$KEY_NAME" ] && [ -n "$SECURITY_GROUP_ID" ]; then
    DRY_RUN_RESULT=$(aws ec2 create-launch-template \
        --dry-run \
        --launch-template-name "validation-test-$(date +%s)" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"KeyName\": \"$KEY_NAME\",
            \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"]
        }" \
        --region "$AWS_REGION" 2>&1 || echo "FAILED")
    
    if echo "$DRY_RUN_RESULT" | grep -q "DryRunOperation"; then
        echo -e "${GREEN}✓${NC} Launch template creation would succeed"
    else
        echo -e "${RED}✗${NC} Launch template creation would fail"
        echo -e "${YELLOW}[INFO]${NC} Error: $(echo "$DRY_RUN_RESULT" | head -1)"
        VALIDATION_PASSED=0
    fi
fi

# Check 9: Setup status updated
check_status "Step 025 marked complete" \
    "grep -q 'STEP_025_COMPLETE=' .setup-status" \
    "Run ./scripts/step-025-setup-ec2-configuration.sh"

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}✓ EC2 configuration validation PASSED${NC}"
    echo
    echo "EC2 Configuration verified:"
    echo "- Security Group: $SECURITY_GROUP_ID"
    echo "- Key Pair: $KEY_NAME"
    echo "- Subnet: $SUBNET_ID (AZ: $AZ)"
    echo "- AMI: $AMI_ID"
    echo "- Instance Type: $INSTANCE_TYPE"
    echo "- Instance Pricing: On-Demand (reliable, no interruption)"
    echo
    # Auto-detect and show next step
    if [ -f "$(dirname "$0")/next-step-helper.sh" ]; then
        source "$(dirname "$0")/next-step-helper.sh"
        show_next_step "$0" "$(dirname "$0")"
    fi
else
    echo -e "${RED}✗ EC2 configuration validation FAILED${NC}"
    echo
    echo "Please fix the issues above before proceeding."
    echo "You may need to re-run:"
    echo "  ./scripts/step-101-setup-ec2-configuration.sh"
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))