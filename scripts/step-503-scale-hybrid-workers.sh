#!/bin/bash
set -e

echo "⚡ HYBRID WORKER SCALING MANAGEMENT"
echo "=================================="

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found."
    exit 1
fi

# Function to list current hybrid workers
list_workers() {
    echo "🔍 Current Hybrid Workers:"
    echo "========================="
    
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Type,Values=hybrid-worker" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress,LaunchTime,InstanceType]' \
        --output table
    
    WORKER_COUNT=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Type,Values=hybrid-worker" "Name=instance-state-name,Values=running,pending" \
        --query 'length(Reservations[].Instances[])' \
        --output text)
    
    echo ""
    echo "📊 Total active hybrid workers: $WORKER_COUNT"
}

# Function to check queue depth
check_queue_depth() {
    echo ""
    echo "📈 Queue Analysis:"
    echo "================="
    
    QUEUE_ATTRS=$(aws sqs get-queue-attributes \
        --queue-url "$QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
        --region "$AWS_REGION" \
        --output json)
    
    PENDING=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages')
    PROCESSING=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible')
    TOTAL_JOBS=$((PENDING + PROCESSING))
    
    echo "  Pending jobs: $PENDING"
    echo "  Processing jobs: $PROCESSING"
    echo "  Total jobs: $TOTAL_JOBS"
    
    # Calculate recommended workers
    # Assuming each worker processes 1 job every 30 seconds (Voxtral speed)
    # Target: Process all jobs within 10 minutes (600 seconds)
    if [ $TOTAL_JOBS -gt 0 ]; then
        JOBS_PER_WORKER_PER_10MIN=20  # 600s / 30s per job
        RECOMMENDED_WORKERS=$(( (TOTAL_JOBS + JOBS_PER_WORKER_PER_10MIN - 1) / JOBS_PER_WORKER_PER_10MIN ))
        echo "  Recommended workers: $RECOMMENDED_WORKERS (to clear queue in ~10 minutes)"
    else
        RECOMMENDED_WORKERS=1
        echo "  Recommended workers: $RECOMMENDED_WORKERS (maintenance level)"
    fi
    
    echo ""
    return $RECOMMENDED_WORKERS
}

# Function to launch additional workers
launch_workers() {
    local count=$1
    echo "🚀 Launching $count additional hybrid workers..."
    
    for i in $(seq 1 $count); do
        echo "  Launching worker $i/$count..."
        
        # Use the same launch script but suppress most output
        ./scripts/step-500-launch-hybrid-workers.sh >/dev/null 2>&1 &
        LAUNCH_PID=$!
        
        echo "  Worker $i launched (PID: $LAUNCH_PID)"
        
        # Small delay to avoid AWS API throttling
        sleep 5
    done
    
    echo "✅ Initiated launch of $count workers"
    echo "   Workers will be ready in ~15 minutes"
}

# Function to terminate excess workers
terminate_workers() {
    local count=$1
    echo "🛑 Terminating $count oldest hybrid workers..."
    
    # Get oldest workers
    WORKERS_TO_TERMINATE=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Type,Values=hybrid-worker" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[] | sort_by(@, &LaunchTime) | [0:'$count'].InstanceId' \
        --output text)
    
    for instance_id in $WORKERS_TO_TERMINATE; do
        echo "  Terminating: $instance_id"
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$AWS_REGION" >/dev/null
    done
    
    echo "✅ Terminated $count workers"
}

# Main menu
echo ""
list_workers
check_queue_depth
RECOMMENDED=$?

CURRENT_WORKERS=$WORKER_COUNT

echo ""
echo "🎯 SCALING RECOMMENDATIONS:"
echo "=========================="
echo "  Current workers: $CURRENT_WORKERS"
echo "  Recommended workers: $RECOMMENDED"

if [ $CURRENT_WORKERS -lt $RECOMMENDED ]; then
    SCALE_UP=$((RECOMMENDED - CURRENT_WORKERS))
    echo "  💡 Suggestion: Scale UP by $SCALE_UP workers"
elif [ $CURRENT_WORKERS -gt $RECOMMENDED ] && [ $CURRENT_WORKERS -gt 1 ]; then
    SCALE_DOWN=$((CURRENT_WORKERS - RECOMMENDED))
    echo "  💡 Suggestion: Scale DOWN by $SCALE_DOWN workers"
else
    echo "  ✅ Current scale is optimal"
fi

echo ""
echo "🎛️ SCALING OPTIONS:"
echo "=================="
echo "1. Auto-scale (apply recommendation)"
echo "2. Manual scale up"
echo "3. Manual scale down"
echo "4. Emergency shutdown (terminate all)"
echo "5. Just monitor (no changes)"
echo "6. Exit"

echo ""
read -p "Choose option (1-6): " choice

case $choice in
    1)
        echo ""
        echo "🤖 Auto-scaling based on queue analysis..."
        
        if [ $CURRENT_WORKERS -lt $RECOMMENDED ]; then
            SCALE_UP=$((RECOMMENDED - CURRENT_WORKERS))
            echo "  Scaling UP by $SCALE_UP workers"
            launch_workers $SCALE_UP
        elif [ $CURRENT_WORKERS -gt $RECOMMENDED ] && [ $CURRENT_WORKERS -gt 1 ]; then
            SCALE_DOWN=$((CURRENT_WORKERS - RECOMMENDED))
            echo "  Scaling DOWN by $SCALE_DOWN workers"
            terminate_workers $SCALE_DOWN
        else
            echo "  No scaling needed - current capacity is optimal"
        fi
        ;;
        
    2)
        echo ""
        read -p "How many workers to add? " add_count
        if [[ "$add_count" =~ ^[0-9]+$ ]] && [ "$add_count" -gt 0 ]; then
            launch_workers $add_count
        else
            echo "❌ Invalid number"
        fi
        ;;
        
    3)
        echo ""
        if [ $CURRENT_WORKERS -le 1 ]; then
            echo "❌ Cannot scale down - only $CURRENT_WORKERS worker(s) running"
        else
            read -p "How many workers to remove? (max $((CURRENT_WORKERS - 1))): " remove_count
            if [[ "$remove_count" =~ ^[0-9]+$ ]] && [ "$remove_count" -gt 0 ] && [ "$remove_count" -lt $CURRENT_WORKERS ]; then
                terminate_workers $remove_count
            else
                echo "❌ Invalid number"
            fi
        fi
        ;;
        
    4)
        echo ""
        echo "🚨 EMERGENCY SHUTDOWN - This will terminate ALL hybrid workers!"
        read -p "Are you sure? Type 'SHUTDOWN' to confirm: " confirm
        if [ "$confirm" = "SHUTDOWN" ]; then
            echo "🛑 Terminating all hybrid workers..."
            ALL_WORKERS=$(aws ec2 describe-instances \
                --region "$AWS_REGION" \
                --filters "Name=tag:Type,Values=hybrid-worker" "Name=instance-state-name,Values=running,pending" \
                --query 'Reservations[].Instances[].InstanceId' \
                --output text)
            
            if [ ! -z "$ALL_WORKERS" ]; then
                aws ec2 terminate-instances --instance-ids $ALL_WORKERS --region "$AWS_REGION"
                echo "✅ All hybrid workers terminated"
            else
                echo "ℹ️ No workers to terminate"
            fi
        else
            echo "❌ Shutdown cancelled"
        fi
        ;;
        
    5)
        echo ""
        echo "📊 Entering monitoring mode..."
        ./scripts/step-502-monitor-hybrid-health.sh
        ;;
        
    6)
        echo "👋 Exiting scaling management"
        exit 0
        ;;
        
    *)
        echo "❌ Invalid option"
        exit 1
        ;;
esac

echo ""
echo "⏱️ Updated worker status in 30 seconds:"
sleep 30
list_workers

echo ""
echo "📝 Scaling Management Complete!"
echo "============================="
echo ""
echo "💡 Pro Tips:"
echo "  - Each hybrid worker processes ~120 jobs/hour (30s per job)"
echo "  - Monitor queue depth regularly for optimal scaling"
echo "  - Use spot instances for cost savings on large workloads"
echo "  - Scale down during low usage periods"
echo ""
echo "🔍 Monitor performance:"
echo "  ./scripts/step-502-monitor-hybrid-health.sh"
echo ""
echo "📊 Check costs:"
echo "  aws ec2 describe-instances --filters 'Name=tag:Type,Values=hybrid-worker' --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,State.Name]' --output table"