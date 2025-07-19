#!/bin/bash

# step-425-voxtral-add-current-ip-to-security-group.sh - Add IP address to EC2 security group for full access

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Add an IP address to the EC2 security group for full access (SSH, API, web UI)"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -i, --ip IP_ADDRESS     Add specific IP address (default: auto-detect current IP)"
    echo "  --ssh-only              Only add SSH access (port 22)"
    echo "  --api-only              Only add API access (ports 8000, 8080)"
    echo
    echo "Examples:"
    echo "  $0                      # Add current IP with full access"
    echo "  $0 -i 192.168.1.100     # Add specific IP with full access"
    echo "  $0 --ssh-only           # Add current IP for SSH only"
    echo
    echo "Ports opened by default:"
    echo "  - 22   (SSH)"
    echo "  - 8000 (Main API)"
    echo "  - 8080 (Health check)"
    echo "  - 80   (HTTP - if web UI)"
    echo "  - 443  (HTTPS - if web UI)"
    exit 0
}

# Parse arguments
SPECIFIC_IP=""
SSH_ONLY=false
API_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -i|--ip)
            SPECIFIC_IP="$2"
            shift 2
            ;;
        --ssh-only)
            SSH_ONLY=true
            shift
            ;;
        --api-only)
            API_ONLY=true
            shift
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🔧 Add IP to Security Group${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Get IP address
echo -e "${GREEN}[STEP 1]${NC} Determining IP address..."
if [ -n "$SPECIFIC_IP" ]; then
    MY_PUBLIC_IP="$SPECIFIC_IP"
    echo "Using specified IP: $MY_PUBLIC_IP"
else
    MY_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
    echo "Auto-detected current IP: $MY_PUBLIC_IP"
fi
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

# Define ports to open
declare -a PORTS_TO_ADD=()
declare -a PORT_DESCRIPTIONS=()

if [ "$SSH_ONLY" = true ]; then
    PORTS_TO_ADD=(22)
    PORT_DESCRIPTIONS=("SSH")
elif [ "$API_ONLY" = true ]; then
    PORTS_TO_ADD=(8000 8080)
    PORT_DESCRIPTIONS=("Main API" "Health Check")
else
    # Full access - all ports
    PORTS_TO_ADD=(22 8000 8080 80 443)
    PORT_DESCRIPTIONS=("SSH" "Main API" "Health Check" "HTTP" "HTTPS")
fi

echo -e "${GREEN}[STEP 3]${NC} Adding security group rules..."
echo "Ports to configure: ${PORTS_TO_ADD[*]}"
echo

# Add rules for each port
for i in "${!PORTS_TO_ADD[@]}"; do
    PORT="${PORTS_TO_ADD[$i]}"
    DESC="${PORT_DESCRIPTIONS[$i]}"
    
    echo -n "Adding rule for port $PORT ($DESC)... "
    
    # Check if rule already exists
    EXISTING_RULE=$(aws ec2 describe-security-groups \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$PORT\`].IpRanges[?CidrIp==\`$MY_PUBLIC_IP/32\`]" \
        --output json 2>/dev/null)
    
    if [ "$EXISTING_RULE" != "[]" ] && [ "$EXISTING_RULE" != "null" ] && [ -n "$EXISTING_RULE" ]; then
        echo -e "${YELLOW}already exists${NC}"
    else
        # Add the rule
        if aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port "$PORT" \
            --cidr "$MY_PUBLIC_IP/32" \
            --region "$AWS_REGION" 2>/dev/null; then
            echo -e "${GREEN}✓ added${NC}"
        else
            echo -e "${YELLOW}rule may already exist${NC}"
        fi
    fi
done

echo -e "${GREEN}[OK]${NC} Security group rules updated for IP: $MY_PUBLIC_IP"

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
echo -e "${GREEN}✅ Security Group Configuration Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[CONFIGURATION SUMMARY]${NC}"
echo "IP Address: $MY_PUBLIC_IP"
echo "Security Group: $SECURITY_GROUP_ID"
echo "Ports Configured: ${PORTS_TO_ADD[*]}"
echo
echo -e "${CYAN}[ENABLED ACCESS]${NC}"
for i in "${!PORTS_TO_ADD[@]}"; do
    PORT="${PORTS_TO_ADD[$i]}"
    DESC="${PORT_DESCRIPTIONS[$i]}"
    echo "  Port $PORT - $DESC"
done
echo
if [ "$REAL_VOXTRAL_INSTANCES" != "[]" ]; then
    echo -e "${GREEN}[SSH COMMANDS]${NC}"
    echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "ssh -i '"$KEY_NAME"'.pem ubuntu@\(.[1])"'
    echo
    echo -e "${GREEN}[API ACCESS]${NC}"
    echo "$REAL_VOXTRAL_INSTANCES" | jq -r '.[][] | "# Instance \(.[0])\nAPI: http://\(.[1]):8000\nHealth: http://\(.[1]):8080/health\nDocs: http://\(.[1]):8000/docs\n"'
    
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