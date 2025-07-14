#!/bin/bash
set -e

echo "🚀 Starting WhisperX Transcription Worker Container"
echo "=================================================="
echo ""

# Check CUDA availability
echo "🔧 GPU/CUDA Check:"
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "✅ NVIDIA drivers detected"
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits | while read line; do
        echo "   GPU: $line"
    done
    
    # Install CUDA-enabled PyTorch if GPU is available
    echo "🚀 Installing CUDA-enabled PyTorch..."
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 --upgrade
else
    echo "⚠️  NVIDIA drivers not detected - using CPU-only mode"
fi

# Test Python imports
echo ""
echo "🔧 Python Environment Check:"
python3 -c "import torch; print(f'   PyTorch: {torch.__version__}')"
python3 -c "import torch; print(f'   CUDA Available: {torch.cuda.is_available()}')"
if python3 -c "import torch; torch.cuda.is_available()" 2>/dev/null; then
    python3 -c "import torch; print(f'   CUDA Devices: {torch.cuda.device_count()}')"
fi

# Check for required environment variables
echo ""
echo "🔧 Environment Check:"
REQUIRED_VARS=("AWS_REGION" "QUEUE_URL" "METRICS_BUCKET" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Missing environment variable: $var"
        exit 1
    else
        echo "✅ $var is set"
    fi
done

# Start health check server in background
echo ""
echo "🏥 Starting health check server..."
python3 /app/health-check.py &
HEALTH_PID=$!

# Handle graceful shutdown
cleanup() {
    echo "📤 Received shutdown signal. Cleaning up..."
    kill $HEALTH_PID 2>/dev/null || true
    kill $WORKER_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start the transcription worker
echo ""
echo "🎵 Starting transcription worker..."
cd /app
python3 -m src.transcription_worker --queue-url "$QUEUE_URL" --s3-bucket "$METRICS_BUCKET" --region "$AWS_REGION" &
WORKER_PID=$!

# Wait for worker to finish
wait $WORKER_PID
