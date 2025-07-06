#!/bin/bash

# scaling_cron.sh - Cron wrapper for transcription worker scaling

# Configuration - Update these values for your environment
BUCKET="${S3_BUCKET:-your-metrics-bucket}"
QUEUE_URL="${QUEUE_URL:-https://sqs.us-east-1.amazonaws.com/account/transcription-queue}"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
SPOT_PRICE="${SPOT_PRICE:-0.50}"
AMI_ID="${AMI_ID:-ami-0c7217cdde317cfec}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID}"
KEY_NAME="${KEY_NAME}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-10}"

# Logging
LOG_DIR="/var/log/transcription-scaling"
LOG_FILE="$LOG_DIR/scaling.log"
LOCK_FILE="/tmp/transcription-scaling.lock"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to cleanup on exit
cleanup() {
    rm -f "$LOCK_FILE"
}

# Set up cleanup trap
trap cleanup EXIT

# Check if another instance is already running
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        log "Another scaling process is already running (PID: $PID)"
        exit 1
    else
        log "Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE"

log "Starting transcription worker scaling check"

# Check required configuration
if [ -z "$BUCKET" ] || [ -z "$QUEUE_URL" ]; then
    log "ERROR: S3_BUCKET and QUEUE_URL environment variables must be set"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/scaling_cron.py"

# Check if Python script exists
if [ ! -f "$PYTHON_SCRIPT" ]; then
    log "ERROR: Python scaling script not found at $PYTHON_SCRIPT"
    exit 1
fi

# Check if we have the required environment variables for launching instances
if [ -z "$SECURITY_GROUP_ID" ] || [ -z "$KEY_NAME" ]; then
    log "WARNING: SECURITY_GROUP_ID and KEY_NAME not set - will run in dry-run mode"
    DRY_RUN="--dry-run"
else
    DRY_RUN=""
fi

# Run the scaling script
log "Running scaling check..."
python3 "$PYTHON_SCRIPT" \
    --bucket "$BUCKET" \
    --queue-url "$QUEUE_URL" \
    --region "$REGION" \
    --instance-type "$INSTANCE_TYPE" \
    --spot-price "$SPOT_PRICE" \
    --ami-id "$AMI_ID" \
    --security-group-id "$SECURITY_GROUP_ID" \
    --key-name "$KEY_NAME" \
    --min-instances "$MIN_INSTANCES" \
    --max-instances "$MAX_INSTANCES" \
    --log-file "$LOG_FILE" \
    $DRY_RUN

RESULT=$?

if [ $RESULT -eq 0 ]; then
    log "Scaling check completed successfully"
else
    log "Scaling check failed with exit code $RESULT"
fi

# Log system resources
log "System resources:"
log "  CPU: $(uptime | awk -F'load average:' '{print $2}')"
log "  Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
log "  Disk: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"

log "Scaling check finished"

exit $RESULT