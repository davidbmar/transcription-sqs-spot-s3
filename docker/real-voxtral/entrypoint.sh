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

# Model caching setup
echo "🗄️ Setting up model caching..."
export MODELS_CACHE_BUCKET=${MODELS_CACHE_BUCKET:-"dbm-cf-2-web"}
export MODELS_CACHE_PREFIX=${MODELS_CACHE_PREFIX:-"bintarball"}
export VOXTRAL_MODEL_CACHE_KEY=${VOXTRAL_MODEL_CACHE_KEY:-"voxtral-mini-3b-2507-v1"}
export CACHE_MODELS_TO_S3=${CACHE_MODELS_TO_S3:-"true"}

CACHE_PATH="s3://$MODELS_CACHE_BUCKET/$MODELS_CACHE_PREFIX/$VOXTRAL_MODEL_CACHE_KEY"
LOCAL_CACHE_DIR="/app/models/cached"

echo "  Cache bucket: $MODELS_CACHE_BUCKET"
echo "  Cache path: $CACHE_PATH"
echo "  Local cache: $LOCAL_CACHE_DIR"

# Check if model is cached in S3 and download
if [ "$CACHE_MODELS_TO_S3" = "true" ]; then
    echo "🔍 Checking S3 model cache..."
    
    if aws s3 ls "$CACHE_PATH/" >/dev/null 2>&1; then
        echo "📥 Found cached model in S3, downloading..."
        mkdir -p "$LOCAL_CACHE_DIR"
        
        if aws s3 cp "$CACHE_PATH/" "$LOCAL_CACHE_DIR/" --recursive; then
            echo "✅ Model cache downloaded successfully"
            export TRANSFORMERS_CACHE="$LOCAL_CACHE_DIR"
            export HF_HOME="$LOCAL_CACHE_DIR"
            echo "  Using cached model from: $LOCAL_CACHE_DIR"
        else
            echo "⚠️ Failed to download cache, will use Hugging Face"
        fi
    else
        echo "🔄 No cached model found, will download from Hugging Face"
        echo "  (Model will be cached for future use)"
    fi
else
    echo "🔄 S3 caching disabled, using Hugging Face directly"
fi

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

# Start server and cache model after successful load
python3 /app/voxtral_server.py &
SERVER_PID=$!

# Function to cache model to S3 after successful load
cache_model_to_s3() {
    echo "🗄️ Checking if model should be cached to S3..."
    
    # Wait for server to be ready and model loaded
    for i in {1..60}; do
        if curl -f -s http://localhost:8080/health >/dev/null 2>&1; then
            HEALTH_RESPONSE=$(curl -s http://localhost:8080/health)
            MODEL_LOADED=$(echo "$HEALTH_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('model_loaded', False))" 2>/dev/null || echo "false")
            
            if [ "$MODEL_LOADED" = "True" ] || [ "$MODEL_LOADED" = "true" ]; then
                echo "✅ Model loaded successfully, checking cache status..."
                
                # Check if we need to upload cache
                if [ "$CACHE_MODELS_TO_S3" = "true" ] && ! aws s3 ls "$CACHE_PATH/" >/dev/null 2>&1; then
                    echo "📤 Uploading model cache to S3..."
                    
                    # Find the transformers cache directory
                    CACHE_SOURCE="/root/.cache/huggingface"
                    if [ -n "$TRANSFORMERS_CACHE" ] && [ -d "$TRANSFORMERS_CACHE" ]; then
                        CACHE_SOURCE="$TRANSFORMERS_CACHE"
                    fi
                    
                    if [ -d "$CACHE_SOURCE" ]; then
                        echo "  Uploading from: $CACHE_SOURCE"
                        echo "  Uploading to: $CACHE_PATH/"
                        
                        if aws s3 cp "$CACHE_SOURCE/" "$CACHE_PATH/" --recursive --quiet; then
                            echo "✅ Model cached to S3 successfully"
                            echo "  Future deployments will be faster!"
                        else
                            echo "⚠️ Failed to cache model to S3 (non-critical)"
                        fi
                    else
                        echo "⚠️ Cache directory not found: $CACHE_SOURCE"
                    fi
                else
                    echo "ℹ️ Model already cached or caching disabled"
                fi
                break
            fi
        fi
        sleep 10
    done
}

# Run caching in background
cache_model_to_s3 &

# Wait for main server process
wait $SERVER_PID