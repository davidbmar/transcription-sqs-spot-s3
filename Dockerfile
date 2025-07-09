# Use NVIDIA CUDA 11.8 with cuDNN 8 runtime on Ubuntu 22.04
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive \
    AWS_DEFAULT_REGION=us-east-2

# Install OS and build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential python3.10 python3-pip python3.10-dev \
    ffmpeg git wget curl vim unzip jq nano htop procps \
    libsndfile1-dev libjpeg-dev libpng-dev libssl-dev \
    awscli \
 && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
 && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy and install Python packages (create requirements.txt for transcription)
COPY requirements.txt /app/
RUN pip3 install --upgrade pip && \
    pip3 install --no-cache-dir -r requirements.txt

# Copy application code
COPY src/ /app/src/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create temp directory for runtime
RUN mkdir -p /app/temp

# Pre-download Whisper models to reduce startup time
RUN python3 -c "import whisper; whisper.load_model('large-v3')" || echo "Model download will happen at runtime"

# Healthcheck to verify transcription worker is alive
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
  CMD python3 -c "import os, time; f='/app/health_check.txt'; exit(0 if os.path.exists(f) and time.time()-os.path.getmtime(f)<300 else 1)"

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]