#!/bin/bash
# ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI"
echo "✅ ECR login successful"
