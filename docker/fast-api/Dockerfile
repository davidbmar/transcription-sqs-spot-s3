# Voxtral GPU Docker Image
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

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
    torch \
    torchaudio \
    transformers \
    accelerate \
    datasets \
    huggingface-hub \
    fastapi \
    uvicorn \
    pydantic \
    python-multipart \
    boto3 \
    requests

# Copy Voxtral server scripts
COPY voxtral_server.py .
COPY voxtral_server_v2.py .

# Expose API port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Run the server
CMD ["python3", "voxtral_server.py"]