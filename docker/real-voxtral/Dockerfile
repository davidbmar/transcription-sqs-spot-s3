# Real Voxtral GPU Dockerfile - Mistral's Voxtral-Mini-3B-2507 Model
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=$CUDA_HOME/bin:$PATH
ENV LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    ffmpeg \
    git \
    curl \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip and install core dependencies
RUN pip3 install --upgrade pip setuptools wheel

# Install PyTorch with CUDA support first
RUN pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

# Install transformers from source for latest Voxtral support
RUN pip3 install git+https://github.com/huggingface/transformers.git

# Install additional ML dependencies
RUN pip3 install \
    accelerate \
    datasets \
    librosa \
    soundfile \
    huggingface_hub

# Install web framework dependencies
RUN pip3 install \
    fastapi \
    uvicorn \
    python-multipart \
    requests \
    boto3

# Install vLLM with audio support (may need to be compiled)
RUN pip3 install "vllm[audio]" || echo "vLLM[audio] install failed, continuing..."

# Create app directory
WORKDIR /app

# Copy application files
COPY voxtral_server.py /app/
COPY entrypoint.sh /app/
COPY health_check.py /app/

# Make scripts executable
RUN chmod +x /app/entrypoint.sh

# Create directories for model cache and temp files
RUN mkdir -p /app/models /app/temp

# Expose port for API
EXPOSE 8000 8080

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]