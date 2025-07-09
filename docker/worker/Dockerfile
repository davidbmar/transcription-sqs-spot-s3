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
