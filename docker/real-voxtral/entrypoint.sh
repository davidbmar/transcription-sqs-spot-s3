#!/bin/bash

# Real Voxtral Container Entrypoint Script

set -e

echo "🚀 STARTING REAL VOXTRAL CONTAINER"
echo "=================================="

# Check environment variables
echo "🔧 Environment Check:"
echo "  - AWS_REGION: ${AWS_REGION:-'not set'}"
echo "  - CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-'not set'}"
echo "  - HOME: $HOME"
echo "  - PWD: $(pwd)"

# GPU Detection
echo "🔧 GPU Detection:"
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "  - NVIDIA drivers: Available"
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits || echo "  - GPU query failed"
else
    echo "  - NVIDIA drivers: Not available (CPU mode)"
fi

# Python environment check
echo "🔧 Python Environment:"
echo "  - Python version: $(python3 --version)"
echo "  - PyTorch version: $(python3 -c 'import torch; print(torch.__version__)')"
echo "  - CUDA available in PyTorch: $(python3 -c 'import torch; print(torch.cuda.is_available())')"

# Test transformers import
echo "🔧 Testing Voxtral imports..."
python3 -c "
try:
    from transformers import VoxtralForConditionalGeneration, AutoProcessor
    print('✅ Voxtral imports successful!')
except ImportError as e:
    print(f'❌ Voxtral import failed: {e}')
    print('This may be expected if transformers is not latest version')
except Exception as e:
    print(f'❌ Unexpected error: {e}')
"

# Start health check server in background
echo "🏥 Starting health check server..."
python3 /app/health_check.py &
HEALTH_PID=$!

# Function to cleanup on exit
cleanup() {
    echo "🧹 Cleaning up..."
    kill $HEALTH_PID 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

# Give health server time to start
sleep 2

# Test health endpoint
echo "🏥 Testing health endpoint..."
curl -f http://localhost:8080/health >/dev/null 2>&1 && echo "✅ Health endpoint working" || echo "⚠ Health endpoint not responding"

# Start main Voxtral server
echo "🚀 Starting Real Voxtral API server..."
echo "  - Main API: http://0.0.0.0:8000"
echo "  - Health check: http://0.0.0.0:8080"
echo "  - Model: mistralai/Voxtral-Mini-3B-2507"

exec python3 /app/voxtral_server.py