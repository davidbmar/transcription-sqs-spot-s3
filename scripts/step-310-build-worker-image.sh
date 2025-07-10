#!/bin/bash
set -e

echo "============================================"
echo "🏗️ Step 210: Build Worker Docker Image"
echo "============================================"
echo ""

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check if previous steps completed
if ! grep -q "step-201-completed" .setup-status 2>/dev/null; then
    echo "❌ Error: step-201-validate-docker-setup.sh must be run first."
    exit 1
fi

echo "🐳 Building WhisperX Docker image with GPU support..."
echo ""

# Create worker Dockerfile
echo "📄 Creating worker Dockerfile..."
cat > docker/worker/Dockerfile << 'EOF'
# Use NVIDIA CUDA 11.8 with cuDNN 8 runtime on Ubuntu 22.04
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive \
    AWS_DEFAULT_REGION=us-east-2

# Install OS and build dependencies in minimal steps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential python3.10 python3-pip python3.10-dev \
    ffmpeg git wget curl jq \
    libsndfile1-dev libjpeg-dev libpng-dev libssl-dev \
    && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set working directory
WORKDIR /app

# Copy and install Python packages
COPY requirements.txt /app/
RUN pip3 install --upgrade pip && \
    pip3 install --no-cache-dir -r requirements.txt && \
    pip3 cache purge && \
    rm -rf /root/.cache/pip/* /tmp/* /var/tmp/*

# Copy application code and scripts
COPY src/ /app/src/
COPY docker/worker/scripts/ /app/scripts/

# Create necessary directories
RUN mkdir -p /app/logs /app/tmp

# Set proper permissions
RUN chmod +x /app/scripts/*.sh

# Health check script
COPY docker/worker/health-check.py /app/health-check.py
RUN chmod +x /app/health-check.py

# Create temp directory for runtime
RUN mkdir -p /app/temp

# Healthcheck to verify container is alive
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD python3 -c "import os, time; f='/app/health_check.txt'; exit(0 if os.path.exists(f) and time.time()-os.path.getmtime(f)<300 else 1)"

# Expose health check port
EXPOSE 8080

# Default command
CMD ["/app/scripts/entrypoint.sh"]
EOF

echo "✅ Created docker/worker/Dockerfile"

# Create entrypoint script
echo "📄 Creating entrypoint script..."
mkdir -p docker/worker/scripts
cat > docker/worker/scripts/entrypoint.sh << 'EOF'
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
REQUIRED_VARS=("AWS_REGION" "QUEUE_URL" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY")
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
python3 -m src.transcription_worker --queue-url "$QUEUE_URL" --region "$AWS_REGION" &
WORKER_PID=$!

# Wait for worker to finish
wait $WORKER_PID
EOF

chmod +x docker/worker/scripts/entrypoint.sh
echo "✅ Created docker/worker/scripts/entrypoint.sh"

# Create health check script
echo "📄 Creating health check script..."
cat > docker/worker/health-check.py << 'EOF'
#!/usr/bin/env python3
"""
Health check server for Docker container
Provides HTTP endpoint for container health monitoring
"""

import http.server
import socketserver
import json
import time
import threading
import os
import subprocess
from datetime import datetime

class HealthCheckHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            health_data = {
                'status': 'healthy',
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'uptime': time.time() - start_time,
                'gpu_available': self.check_gpu(),
                'worker_running': self.check_worker_process(),
                'container_id': os.environ.get('HOSTNAME', 'unknown')
            }
            
            self.wfile.write(json.dumps(health_data, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def check_gpu(self):
        try:
            result = subprocess.run(['nvidia-smi'], capture_output=True, text=True)
            return result.returncode == 0
        except:
            return False
    
    def check_worker_process(self):
        try:
            result = subprocess.run(['pgrep', '-f', 'transcription_worker'], capture_output=True)
            return result.returncode == 0
        except:
            return False
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

start_time = time.time()

def run_health_server():
    PORT = 8080
    with socketserver.TCPServer(("", PORT), HealthCheckHandler) as httpd:
        print(f"🏥 Health check server running on port {PORT}")
        httpd.serve_forever()

if __name__ == "__main__":
    run_health_server()
EOF

chmod +x docker/worker/health-check.py
echo "✅ Created docker/worker/health-check.py"

# Create build script
echo "📄 Creating build script..."
cat > docker/worker/build.sh << 'EOF'
#!/bin/bash
set -e

# Load configuration
if [ -f "../../.env" ]; then
    source "../../.env"
fi

IMAGE_NAME="${ECR_REPOSITORY_URI}:latest"
IMAGE_TAG="${ECR_REPOSITORY_URI}:$(date +%Y%m%d-%H%M%S)"

echo "🏗️ Building Docker image: $IMAGE_NAME"
echo ""

# Build the image
docker build -t "$IMAGE_NAME" -t "$IMAGE_TAG" -f Dockerfile ../..

echo ""
echo "✅ Docker image built successfully!"
echo "   Latest: $IMAGE_NAME"
echo "   Tagged: $IMAGE_TAG"
EOF

chmod +x docker/worker/build.sh
echo "✅ Created docker/worker/build.sh"

# Build the image
echo ""
echo "🏗️ Building Docker image (this may take several minutes)..."
cd docker/worker

# Copy requirements.txt to build context
cp ../../requirements.txt .

# Start build with progress
echo "Building image with tag: ${ECR_REPOSITORY_URI}:latest"
echo ""

if docker build -t "${ECR_REPOSITORY_URI}:latest" -f Dockerfile ../..; then
    echo ""
    echo "✅ Docker image built successfully!"
    
    # Create timestamped tag
    TIMESTAMP_TAG="${ECR_REPOSITORY_URI}:$(date +%Y%m%d-%H%M%S)"
    docker tag "${ECR_REPOSITORY_URI}:latest" "$TIMESTAMP_TAG"
    echo "   Latest: ${ECR_REPOSITORY_URI}:latest"
    echo "   Tagged: $TIMESTAMP_TAG"
    
    # Test the image
    echo ""
    echo "🧪 Testing the built image..."
    if docker run --rm "${ECR_REPOSITORY_URI}:latest" python3 -c "import sys; sys.path.append('/app'); import src.transcription_worker; print('✅ Worker module imports successfully')"; then
        echo "✅ Image test passed!"
    else
        echo "⚠️  Image test failed, but build completed"
    fi
    
else
    echo "❌ Docker build failed!"
    cd ../..
    exit 1
fi

cd ../..

# Update status
echo ""
echo "📊 Build Summary:"
echo "  • Image: ${ECR_REPOSITORY_URI}:latest"
echo "  • Size: $(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep "${ECR_REPOSITORY_URI}" | head -1 | awk '{print $2}')"
echo "  • GPU Support: CUDA 11.8"
echo "  • Health Check: Port 8080"
echo ""
echo "📋 Next steps:"
echo "  1. Run: ./scripts/step-211-push-to-ecr.sh"
echo "  2. Then: ./scripts/step-220-launch-docker-worker.sh"
echo ""

# Update setup status
echo "step-210-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
echo "docker-image-built=true" >> .setup-status
echo "docker-image-name=${ECR_REPOSITORY_URI}:latest" >> .setup-status