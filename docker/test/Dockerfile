# Test Dockerfile - Minimal setup to verify Docker works
FROM ubuntu:22.04

# Set non-interactive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Update and install basic utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        curl \
        jq \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /app

# Simple test script
RUN echo '#!/bin/bash\necho "🐳 Docker container is working!"\necho "Python version: $(python3 --version)"\necho "Current time: $(date)"' > /app/test.sh && \
    chmod +x /app/test.sh

CMD ["/app/test.sh"]
