#!/bin/bash
set -e

# Docker entrypoint for transcription worker
echo "🐳 Starting transcription worker container"

# Function to write health check file
write_health_check() {
    touch /app/health_check.txt
}

# Function to run transcription worker
run_worker() {
    local queue_url="$1"
    local s3_bucket="$2"
    local region="${3:-us-east-2}"
    local model="${4:-large-v3}"
    local device="${5:-auto}"
    local idle_timeout="${6:-60}"
    
    echo "🚀 Starting transcription worker with:"
    echo "  Queue URL: $queue_url"
    echo "  S3 Bucket: $s3_bucket"
    echo "  Region: $region"
    echo "  Model: $model"
    echo "  Device: $device"
    echo "  Idle Timeout: $idle_timeout minutes"
    
    # Start health check background process
    while true; do
        write_health_check
        sleep 30
    done &
    
    # Determine device
    local worker_args="--queue-url $queue_url --s3-bucket $s3_bucket --region $region --model $model --idle-timeout $idle_timeout"
    
    if [ "$device" = "cpu" ]; then
        worker_args="$worker_args --cpu-only"
        echo "🖥️  Using CPU-only mode"
    elif [ "$device" = "auto" ]; then
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
            echo "🔥 GPU detected - using GPU acceleration"
        else
            worker_args="$worker_args --cpu-only"
            echo "🖥️  No GPU detected - using CPU mode"
        fi
    fi
    
    # Start the transcription worker
    exec python3 /app/src/transcription_worker.py $worker_args
}

# Parse command line arguments
case "$1" in
    "--help"|"-h")
        echo "Transcription Worker Docker Container"
        echo ""
        echo "Usage:"
        echo "  docker run transcription-worker worker <queue_url> <s3_bucket> [region] [model] [device] [idle_timeout]"
        echo ""
        echo "Parameters:"
        echo "  queue_url     - SQS queue URL for jobs"
        echo "  s3_bucket     - S3 bucket for outputs"
        echo "  region        - AWS region (default: us-east-2)"
        echo "  model         - Whisper model (default: large-v3)"
        echo "  device        - Device: auto|cpu|gpu (default: auto)"
        echo "  idle_timeout  - Idle timeout in minutes (default: 60)"
        echo ""
        echo "Examples:"
        echo "  # CPU-only worker"
        echo "  docker run transcription-worker worker https://sqs.us-east-2.amazonaws.com/123/queue my-bucket us-east-2 large-v3 cpu"
        echo ""
        echo "  # Auto-detect GPU/CPU"
        echo "  docker run transcription-worker worker https://sqs.us-east-2.amazonaws.com/123/queue my-bucket"
        ;;
    "worker")
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "❌ Error: queue_url and s3_bucket are required"
            echo "Run with --help for usage information"
            exit 1
        fi
        run_worker "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    "bash"|"shell")
        echo "🐚 Starting interactive bash shell"
        exec /bin/bash
        ;;
    *)
        echo "❌ Unknown command: $1"
        echo "Run with --help for usage information"
        exit 1
        ;;
esac