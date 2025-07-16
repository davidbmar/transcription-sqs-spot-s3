# GPU WhisperX Transcription Worker
# Based on proven runpodWhisperx approach with cuDNN 8 compatibility
# CUDA 11.8 + cuDNN 8 + PyTorch 2.0.0 = Stable GPU transcription

FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Prevent interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Set environment variables for caching and performance
ENV TORCH_HOME=/cache/torch
ENV HF_HOME=/cache/huggingface
ENV TRANSFORMERS_CACHE=/cache/huggingface
ENV CUDA_VISIBLE_DEVICES=0
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1

# Create cache directories
RUN mkdir -p /cache/torch /cache/huggingface /app /var/log

# Install system dependencies (Ubuntu 22.04 uses Python 3.10 by default)
RUN apt-get update && apt-get install -y \
    python3 \
    python3-dev \
    python3-venv \
    python3-pip \
    git \
    wget \
    curl \
    ffmpeg \
    libsndfile1 \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Use Python 3.10 (default in Ubuntu 22.04) for WhisperX compatibility
RUN python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"

# Upgrade pip and install core packages
RUN pip install --no-cache-dir --upgrade pip==24.0

# Install PyTorch 2.0.0 with CUDA 11.8 (proven stable combination from runpodWhisperx)
# Use explicit cu118 versions to ensure CUDA compatibility
RUN pip install --no-cache-dir \
    torch==2.0.0+cu118 \
    torchvision==0.15.0+cu118 \
    torchaudio==2.0.0+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

# Install critical dependencies with compatible versions
RUN pip install --no-cache-dir \
    boto3==1.34.0 \
    numpy==1.24.4 \
    soundfile==0.12.1 \
    faster-whisper==0.10.1 \
    transformers==4.30.0

# Install WhisperX dependencies manually to avoid version conflicts
RUN pip install --no-cache-dir \
    librosa==0.10.1 \
    huggingface-hub==0.20.0 \
    omegaconf==2.3.0 \
    pandas==2.0.3 \
    av==11.0.0 \
    ffmpeg-python==0.2.0 \
    nltk \
    setuptools==65.6.3

# Install WhisperX with --no-deps to prevent PyTorch version conflicts
# Use specific commit that works with Python 3.10 and maintains CUDA compatibility
RUN pip install --no-deps --no-cache-dir whisperx==3.1.1

# Install pyannote.audio after WhisperX to avoid conflicts
RUN pip install --no-cache-dir pyannote.audio==3.1.1

# Download VAD model from our S3 bucket to avoid HuggingFace dependencies
RUN mkdir -p /cache/torch && \
    curl -f -o /cache/torch/whisperx-vad-segmentation.bin \
    "https://s3.amazonaws.com/dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin" || \
    echo "⚠️ VAD model download failed - will be downloaded at runtime"

# Copy our transcription worker code
COPY src/ /app/

# Set working directory
WORKDIR /app

# Create health check script
RUN echo '#!/bin/bash\necho "{\\"status\\": \\"healthy\\", \\"timestamp\\": \\"$(date -Iseconds)\\", \\"gpu_available\\": $(nvidia-smi > /dev/null 2>&1 && echo true || echo false)}"' > /app/health.sh && \
    chmod +x /app/health.sh

# Test imports (optional - can be done at runtime)
RUN python3 -c "import torch; import whisperx; print('✅ WhisperX imports successful')" || echo "⚠️ Import test failed - will retry at runtime"

# Health check endpoint (for container orchestration)
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /app/health.sh || exit 1

# Expose port for health checks if needed
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["python3", "transcription_worker.py"]