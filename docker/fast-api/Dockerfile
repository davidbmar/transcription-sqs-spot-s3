# Fast API WhisperX GPU Docker Image
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    git \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /app

# Install Python dependencies
RUN pip3 install --no-cache-dir \
    "numpy<2" \
    torch==2.0.1 \
    torchaudio==2.0.2 \
    transformers \
    accelerate \
    datasets \
    huggingface-hub \
    fastapi \
    uvicorn \
    pydantic \
    python-multipart \
    boto3 \
    requests \
    whisperx

# Copy Fast API server scripts
COPY fast_api_server.py .
COPY fast_api_server_v2.py .
COPY fast_api_server_s3.py .
COPY entrypoint.sh .

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Create health check script
RUN echo '#!/usr/bin/env python3\n\
import requests\n\
import sys\n\
try:\n\
    response = requests.get("http://localhost:8080/health", timeout=5)\n\
    if response.status_code == 200:\n\
        sys.exit(0)\n\
    else:\n\
        sys.exit(1)\n\
except Exception:\n\
    sys.exit(1)' > /app/health_check.py && chmod +x /app/health_check.py

# Expose API port and health check port
EXPOSE 8000 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python3 /app/health_check.py || exit 1

# Default to S3-enhanced server
ENV SERVER_VERSION=s3

# Run the server via entrypoint
CMD ["./entrypoint.sh"]