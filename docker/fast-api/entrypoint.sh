#!/bin/bash

# Entrypoint script for Fast API container
# Allows selection of different server versions via environment variable

# Default to S3-enabled server if not specified
SERVER_VERSION="${SERVER_VERSION:-s3}"

echo "Starting Fast API server (version: $SERVER_VERSION)..."

case "$SERVER_VERSION" in
    "v1"|"basic")
        echo "Running basic Fast API server..."
        exec python3 fast_api_server.py
        ;;
    "v2")
        echo "Running Fast API server v2..."
        exec python3 fast_api_server_v2.py
        ;;
    "s3"|"enhanced")
        echo "Running S3-enhanced Fast API server..."
        exec python3 fast_api_server_s3.py
        ;;
    *)
        echo "Unknown server version: $SERVER_VERSION"
        echo "Available versions: v1, v2, s3 (default)"
        exit 1
        ;;
esac