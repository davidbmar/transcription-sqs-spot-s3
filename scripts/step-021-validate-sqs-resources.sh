#!/bin/bash

# step-021-validate-sqs-resources.sh - Validate SQS and S3 resources after step-020

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
echo -e "${BLUE}SQS & S3 Resources Validation${NC}"
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

# Check 1: Main SQS queue exists and accessible
check_status "Main SQS queue exists and accessible" \
    "aws sqs get-queue-attributes --queue-url '$QUEUE_URL' --attribute-names QueueArn --region '$AWS_REGION' >/dev/null 2>&1" \
    "Run ./scripts/step-020-create-sqs-resources.sh"

# Check 2: Dead letter queue exists
check_status "Dead letter queue exists and accessible" \
    "aws sqs get-queue-attributes --queue-url '$DLQ_URL' --attribute-names QueueArn --region '$AWS_REGION' >/dev/null 2>&1" \
    "Run ./scripts/step-020-create-sqs-resources.sh"

# Check 3: Queue URLs are set in .env
check_status "QUEUE_URL set in configuration" \
    "[ -n '$QUEUE_URL' ]" \
    "Check .env file or re-run step-020"

check_status "DLQ_URL set in configuration" \
    "[ -n '$DLQ_URL' ]" \
    "Check .env file or re-run step-020"

# Check 4: Queue attributes are correct
if [ -n "$QUEUE_URL" ]; then
    echo -e "${YELLOW}[INFO]${NC} Checking queue configuration..."
    
    # Get queue attributes
    QUEUE_ATTRS=$(aws sqs get-queue-attributes \
        --queue-url "$QUEUE_URL" \
        --attribute-names All \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo "{}")
    
    # Check visibility timeout
    VISIBILITY_TIMEOUT=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.VisibilityTimeout // "0"')
    check_status "Queue visibility timeout configured (${VISIBILITY_TIMEOUT}s)" \
        "[ '$VISIBILITY_TIMEOUT' -ge '1800' ]" \
        "Visibility timeout should be at least 30 minutes (1800s)"
    
    # Check message retention
    MSG_RETENTION=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.MessageRetentionPeriod // "0"')
    check_status "Message retention configured (${MSG_RETENTION}s)" \
        "[ '$MSG_RETENTION' -ge '172800' ]" \
        "Message retention should be at least 2 days (172800s)"
    
    # Check redrive policy (DLQ configuration)
    REDRIVE_POLICY=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.RedrivePolicy // "null"')
    check_status "Dead letter queue configured" \
        "[ '$REDRIVE_POLICY' != 'null' ]" \
        "Queue should have DLQ redrive policy"
fi

# Check 5: Metrics S3 bucket exists and accessible
check_status "Metrics S3 bucket exists and accessible" \
    "aws s3 ls 's3://$METRICS_BUCKET' --region '$AWS_REGION' >/dev/null 2>&1" \
    "Run ./scripts/step-020-create-sqs-resources.sh"

# Check 6: Audio S3 bucket accessible
check_status "Audio S3 bucket accessible" \
    "aws s3 ls 's3://$AUDIO_BUCKET' --region '$AWS_REGION' >/dev/null 2>&1" \
    "Check if bucket exists or permissions are correct"

# Check 7: Queue metrics file exists
check_status "Queue metrics file exists in S3" \
    "aws s3 ls 's3://$METRICS_BUCKET/queue-stats.json' >/dev/null 2>&1" \
    "Should be created by step-020-create-sqs-resources.sh"

# Check 8: Test queue operations
echo -e "${YELLOW}[INFO]${NC} Testing queue operations..."

# Test sending a message
TEST_MESSAGE='{"test": true, "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
SEND_RESULT=$(aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$TEST_MESSAGE" \
    --region "$AWS_REGION" 2>&1 || echo "FAILED")

if echo "$SEND_RESULT" | grep -q "MessageId"; then
    echo -e "${GREEN}✓${NC} Can send messages to queue"
    
    # Test receiving the message
    sleep 2
    RECEIVE_RESULT=$(aws sqs receive-message \
        --queue-url "$QUEUE_URL" \
        --max-number-of-messages 1 \
        --region "$AWS_REGION" 2>/dev/null || echo "FAILED")
    
    if echo "$RECEIVE_RESULT" | grep -q "Messages"; then
        echo -e "${GREEN}✓${NC} Can receive messages from queue"
        
        # Clean up test message
        RECEIPT_HANDLE=$(echo "$RECEIVE_RESULT" | jq -r '.Messages[0].ReceiptHandle')
        aws sqs delete-message \
            --queue-url "$QUEUE_URL" \
            --receipt-handle "$RECEIPT_HANDLE" \
            --region "$AWS_REGION" >/dev/null 2>&1
        echo -e "${GREEN}✓${NC} Can delete messages from queue"
    else
        echo -e "${RED}✗${NC} Cannot receive messages from queue"
        VALIDATION_PASSED=0
    fi
else
    echo -e "${RED}✗${NC} Cannot send messages to queue"
    VALIDATION_PASSED=0
fi

# Check 9: Queue resource summary file
check_status "Queue resources summary file exists" \
    "[ -f queue-resources-summary.txt ]" \
    "Should be created by step-020-create-sqs-resources.sh"

# Check 10: Setup status updated
check_status "Step 021 marked complete" \
    "grep -q 'STEP_021_COMPLETE=' .setup-status" \
    "Run ./scripts/step-020-create-sqs-resources.sh"

# Summary
echo
echo -e "${BLUE}======================================${NC}"
if [ $VALIDATION_PASSED -eq 1 ]; then
    echo -e "${GREEN}✓ SQS & S3 resources validation PASSED${NC}"
    echo
    echo "Resources verified:"
    echo "- Main Queue: $QUEUE_URL"
    echo "- Dead Letter Queue: $DLQ_URL"
    echo "- Metrics Bucket: s3://$METRICS_BUCKET"
    echo "- Audio Bucket: s3://$AUDIO_BUCKET"
    echo
    echo "Next step: Configure EC2 settings"
    echo "  ./scripts/step-025-setup-ec2-configuration.sh"
else
    echo -e "${RED}✗ SQS & S3 resources validation FAILED${NC}"
    echo
    echo "Please fix the issues above before proceeding."
    echo "You may need to re-run:"
    echo "  ./scripts/step-020-create-sqs-resources.sh"
fi
echo -e "${BLUE}======================================${NC}"

exit $((1 - VALIDATION_PASSED))