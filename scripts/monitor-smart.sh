#!/bin/bash
# monitor-smart.sh - Auto-detect and choose which worker to monitor

source .env

echo "🔍 DETECTING ALL TRANSCRIPTION WORKERS & TESTS"
echo "=============================================="

# Arrays to store instances
declare -a INSTANCES
declare -a NAMES
declare -a STATES
declare -a TYPES

# Function to add instance to arrays
add_instance() {
    local id="$1"
    local name="$2" 
    local state="$3"
    local type="$4"
    
    INSTANCES+=("$id")
    NAMES+=("$name")
    STATES+=("$state")
    TYPES+=("$type")
}

# Get all instances with transcription-related tags
echo "Scanning for transcription workers..."

# Get running instances with worker tags
RUNNING_WORKERS=$(aws ec2 describe-instances \
    --region $AWS_REGION \
    --filters "Name=tag:Type,Values=*worker*,*test*" "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,Tags[?Key==`Type`].Value|[0],LaunchTime]' \
    --output text 2>/dev/null)

# Parse running workers
if [ -n "$RUNNING_WORKERS" ]; then
    while IFS=$'\t' read -r instance_id name state type launch_time; do
        if [ -n "$instance_id" ] && [ "$instance_id" != "None" ]; then
            add_instance "$instance_id" "${name:-unknown}" "$state" "${type:-worker}"
        fi
    done <<< "$RUNNING_WORKERS"
fi

# Also check for recent terminated instances (might have logs)
RECENT_TERMINATED=$(aws ec2 describe-instances \
    --region $AWS_REGION \
    --filters "Name=tag:Type,Values=*worker*,*test*" "Name=instance-state-name,Values=terminated" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,Tags[?Key==`Type`].Value|[0],LaunchTime]' \
    --output text 2>/dev/null | head -10)

# Parse recent terminated
if [ -n "$RECENT_TERMINATED" ]; then
    while IFS=$'\t' read -r instance_id name state type launch_time; do
        if [ -n "$instance_id" ] && [ "$instance_id" != "None" ]; then
            add_instance "$instance_id" "${name:-unknown}" "$state" "${type:-worker}"
        fi
    done <<< "$RECENT_TERMINATED"
fi

# Check if we found any instances
if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No transcription workers or tests found!"
    echo ""
    echo "To launch a new worker, try:"
    echo "  ./scripts/launch-production-gpu-worker.sh"
    exit 1
fi

# Display available instances
echo ""
echo "📋 AVAILABLE WORKERS & TESTS:"
echo "=============================================="
for i in "${!INSTANCES[@]}"; do
    instance_id="${INSTANCES[$i]}"
    name="${NAMES[$i]}"
    state="${STATES[$i]}"
    type="${TYPES[$i]}"
    
    # Add status indicator
    case "$state" in
        "running") status="🟢 ACTIVE" ;;
        "pending") status="🟡 STARTING" ;;
        "stopping"|"shutting-down") status="🟠 STOPPING" ;;
        "terminated") status="🔴 TERMINATED" ;;
        *) status="⚪ $state" ;;
    esac
    
    printf "%2d. %s - %s\n" $((i+1)) "$instance_id" "$status"
    printf "    Name: %s | Type: %s\n" "$name" "$type"
    echo ""
done

# Auto-select if only one running instance
RUNNING_COUNT=0
RUNNING_INDEX=-1
for i in "${!STATES[@]}"; do
    if [ "${STATES[$i]}" = "running" ]; then
        RUNNING_COUNT=$((RUNNING_COUNT + 1))
        RUNNING_INDEX=$i
    fi
done

if [ $RUNNING_COUNT -eq 1 ] && [ -z "$1" ]; then
    echo "🎯 Auto-selecting the only running instance..."
    CHOICE=$((RUNNING_INDEX + 1))
else
    # Ask user to choose
    echo "=============================================="
    read -p "Enter number to monitor (1-${#INSTANCES[@]}), or press Enter for first running: " CHOICE
    
    # Default to first running instance if just Enter pressed
    if [ -z "$CHOICE" ] && [ $RUNNING_COUNT -gt 0 ]; then
        CHOICE=$((RUNNING_INDEX + 1))
    fi
fi

# Validate choice
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#INSTANCES[@]} ]; then
    echo "❌ Invalid choice. Please enter a number between 1 and ${#INSTANCES[@]}"
    exit 1
fi

# Get selected instance details
SELECTED_INDEX=$((CHOICE - 1))
SELECTED_ID="${INSTANCES[$SELECTED_INDEX]}"
SELECTED_NAME="${NAMES[$SELECTED_INDEX]}"
SELECTED_STATE="${STATES[$SELECTED_INDEX]}"
SELECTED_TYPE="${TYPES[$SELECTED_INDEX]}"

echo ""
echo "🎯 MONITORING SELECTED WORKER"
echo "=============================================="
echo "Instance: $SELECTED_ID"
echo "Name: $SELECTED_NAME"
echo "State: $SELECTED_STATE"
echo "Type: $SELECTED_TYPE"
echo ""

# Determine log path based on worker type
case "$SELECTED_TYPE" in
    *"production"*|*"worker"*)
        LOG_PATH="s3://$METRICS_BUCKET/worker-logs/$SELECTED_ID"
        LOG_FILE="production.log"
        ;;
    *"granular"*|*"nvidia"*)
        LOG_PATH="s3://$METRICS_BUCKET/debug-logs/nvidia-granular-$SELECTED_ID"
        LOG_FILE="live.log"
        ;;
    *"minimal"*)
        LOG_PATH="s3://$METRICS_BUCKET/debug-logs/minimal-test-$SELECTED_ID"
        LOG_FILE="live.log"
        ;;
    *"micro"*)
        LOG_PATH="s3://$METRICS_BUCKET/debug-logs/micro-nvidia-$SELECTED_ID"
        LOG_FILE="live.log"
        ;;
    *)
        # Try to detect from available logs
        if aws s3 ls s3://$METRICS_BUCKET/worker-logs/$SELECTED_ID/ --region $AWS_REGION >/dev/null 2>&1; then
            LOG_PATH="s3://$METRICS_BUCKET/worker-logs/$SELECTED_ID"
            LOG_FILE="production.log"
        elif aws s3 ls s3://$METRICS_BUCKET/debug-logs/nvidia-granular-$SELECTED_ID/ --region $AWS_REGION >/dev/null 2>&1; then
            LOG_PATH="s3://$METRICS_BUCKET/debug-logs/nvidia-granular-$SELECTED_ID"
            LOG_FILE="live.log"
        else
            LOG_PATH="s3://$METRICS_BUCKET/debug-logs/minimal-test-$SELECTED_ID"
            LOG_FILE="live.log"
        fi
        ;;
esac

echo "📁 Log path: $LOG_PATH"
echo "📄 Log file: $LOG_FILE"
echo ""
echo "Press Ctrl+C to stop monitoring"
echo "=============================================="

# Start monitoring loop
while true; do
    clear
    echo "=== MONITORING: $SELECTED_NAME ($SELECTED_ID) - $(date) ==="
    echo ""
    
    # Show queue status if it's a worker
    if [[ "$SELECTED_TYPE" == *"worker"* ]]; then
        echo "📊 Queue Status:"
        ./scripts/monitor-queue.sh 2>/dev/null || echo "Queue status unavailable"
        echo ""
    fi
    
    # Check if logs exist
    echo "📁 Available logs:"
    aws s3 ls $LOG_PATH/ --region $AWS_REGION 2>/dev/null || echo "  No logs found"
    
    echo ""
    echo "📋 Latest log content:"
    echo "================================"
    
    # Get and display log content
    LOG_CONTENT=$(aws s3 cp $LOG_PATH/$LOG_FILE - --region $AWS_REGION 2>/dev/null || echo "Log not available")
    
    if [ "$LOG_CONTENT" != "Log not available" ]; then
        # Show last 20 lines with line numbers
        echo "$LOG_CONTENT" | tail -20 | nl -v $(( $(echo "$LOG_CONTENT" | wc -l) - 19 ))
    else
        echo "  $LOG_CONTENT"
        
        # Try alternative log files
        echo ""
        echo "Trying alternative log files..."
        for alt_file in "startup-complete.log" "final.log" "live.log" "production.log"; do
            ALT_CONTENT=$(aws s3 cp $LOG_PATH/$alt_file - --region $AWS_REGION 2>/dev/null)
            if [ -n "$ALT_CONTENT" ]; then
                echo "Found: $alt_file"
                echo "$ALT_CONTENT" | tail -10 | nl
                break
            fi
        done
    fi
    
    echo ""
    echo "================================"
    echo "Refreshing in 15 seconds... (Ctrl+C to stop)"
    sleep 15
done