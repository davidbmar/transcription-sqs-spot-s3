#!/bin/bash

# step-327-fast-api-fix-iam-and-restart.sh - Fix IAM permissions and restart Fast API setup

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
echo -e "${BLUE}🔧 Fix Fast API IAM and Restart Setup${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Find Fast API instances
echo -e "${GREEN}[STEP 1]${NC} Finding Fast API instances..."
FAST_API_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
    --output json)

if [ "$FAST_API_INSTANCES" = "[]" ]; then
    echo -e "${RED}[ERROR]${NC} No running Fast API instances found"
    exit 1
fi

INSTANCE_ID=$(echo "$FAST_API_INSTANCES" | jq -r '.[0][0][0]')
PUBLIC_IP=$(echo "$FAST_API_INSTANCES" | jq -r '.[0][0][1]')

echo -e "${GREEN}[OK]${NC} Found instance: $INSTANCE_ID ($PUBLIC_IP)"

# Set instance profile if not configured
if [ -z "$INSTANCE_PROFILE" ]; then
    INSTANCE_PROFILE="transcription-worker-profile"
    echo -e "${YELLOW}[INFO]${NC} Using default instance profile: $INSTANCE_PROFILE"
fi

# Check if instance has IAM instance profile
echo -e "${GREEN}[STEP 2]${NC} Checking IAM instance profile..."
CURRENT_PROFILE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text 2>/dev/null || echo "None")

if [ "$CURRENT_PROFILE" = "None" ] || [ "$CURRENT_PROFILE" = "null" ]; then
    echo -e "${YELLOW}[INFO]${NC} No IAM instance profile attached. Attaching worker profile..."
    
    # Attach the worker instance profile
    aws ec2 associate-iam-instance-profile \
        --instance-id "$INSTANCE_ID" \
        --iam-instance-profile Name="$INSTANCE_PROFILE" \
        --region "$AWS_REGION" >/dev/null
    
    echo -e "${GREEN}[OK]${NC} IAM instance profile attached: $INSTANCE_PROFILE"
    echo -e "${YELLOW}[INFO]${NC} Waiting 30 seconds for IAM to propagate..."
    sleep 30
else
    echo -e "${GREEN}[OK]${NC} IAM instance profile already attached"
fi

# Create manual setup script
echo -e "${GREEN}[STEP 3]${NC} Creating manual setup script..."
cat > /tmp/fast-api-manual-setup.sh << 'EOF'
#!/bin/bash
set -e

log_step() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a /var/log/fast-api-manual-setup.log
}

log_step "🔧 MANUAL FAST_API SETUP STARTING"

# Configure AWS CLI with region
aws configure set region REGION_PLACEHOLDER
log_step "✅ AWS CLI configured"

# Test AWS access
if aws sts get-caller-identity >/dev/null 2>&1; then
    log_step "✅ AWS credentials working"
else
    log_step "❌ AWS credentials failed"
    exit 1
fi

# Login to ECR
log_step "🔐 Logging into ECR..."
aws ecr get-login-password --region REGION_PLACEHOLDER | docker login --username AWS --password-stdin ECR_URI_PLACEHOLDER

# Pull the Fast API image
log_step "📥 Pulling Fast API image..."
docker pull ECR_URI_PLACEHOLDER:DOCKER_TAG_PLACEHOLDER

# Stop any existing container
docker stop fast-api-gpu 2>/dev/null || true
docker rm fast-api-gpu 2>/dev/null || true

# Run Fast API container
log_step "🚀 Starting Fast API container..."
docker run -d \
    --name fast-api-gpu \
    --gpus all \
    --restart unless-stopped \
    -p 8000:8000 \
    -e AWS_REGION=REGION_PLACEHOLDER \
    -e DEVICE=cuda \
    -v /var/log/fast-api:/app/logs \
    ECR_URI_PLACEHOLDER:DOCKER_TAG_PLACEHOLDER

# Wait and check
sleep 10
if docker ps | grep -q fast-api-gpu; then
    log_step "✅ Fast API container running successfully"
    docker logs fast-api-gpu | tail -10 | tee -a /var/log/fast-api-manual-setup.log
else
    log_step "❌ Fast API container failed to start"
    docker logs fast-api-gpu 2>&1 | tee -a /var/log/fast-api-manual-setup.log
fi

# Test API
sleep 5
if curl -f http://localhost:8000/health >/dev/null 2>&1; then
    log_step "✅ API is healthy"
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
    log_step "🎉 FAST_API READY at http://$PUBLIC_IP:8000"
else
    log_step "⚠️ API not responding yet, may need more time"
fi

log_step "🔧 MANUAL SETUP COMPLETE"
EOF

# Replace placeholders
sed -i "s/REGION_PLACEHOLDER/$AWS_REGION/g" /tmp/fast-api-manual-setup.sh
sed -i "s|ECR_URI_PLACEHOLDER|$FAST_API_ECR_REPOSITORY_URI|g" /tmp/fast-api-manual-setup.sh
sed -i "s/DOCKER_TAG_PLACEHOLDER/$FAST_API_DOCKER_IMAGE_TAG/g" /tmp/fast-api-manual-setup.sh

# Copy script to instance
echo -e "${GREEN}[STEP 4]${NC} Copying setup script to instance..."
scp -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" /tmp/fast-api-manual-setup.sh ubuntu@"$PUBLIC_IP":/tmp/

# Run the setup script
echo -e "${GREEN}[STEP 5]${NC} Running manual setup on instance..."
ssh -o StrictHostKeyChecking=no -i "$KEY_NAME.pem" ubuntu@"$PUBLIC_IP" "chmod +x /tmp/fast-api-manual-setup.sh && sudo /tmp/fast-api-manual-setup.sh"

echo -e "${GREEN}[STEP 6]${NC} Checking final status..."
sleep 10

# Test API
if curl -f -s --max-time 5 "http://$PUBLIC_IP:8000/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ FAST_API IS NOW READY${NC}"
    echo -e "API Endpoint: ${GREEN}http://$PUBLIC_IP:8000${NC}"
    echo -e "Health Check: ${GREEN}http://$PUBLIC_IP:8000/health${NC}"
    echo -e "API Docs: ${GREEN}http://$PUBLIC_IP:8000/docs${NC}"
else
    echo -e "${YELLOW}⚠️ API not responding yet${NC}"
    echo "Check container status: ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_IP 'docker logs fast-api-gpu'"
fi

echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fast API Fix Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Test transcription:"
echo "   ./scripts/step-330-fast-api-test-voice-transcription.sh"
echo
echo "2. Manual test:"
echo "   curl http://$PUBLIC_IP:8000/health"