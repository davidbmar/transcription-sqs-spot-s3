#!/bin/bash
# Voxtral ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR for Voxtral..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$VOXTRAL_ECR_REPOSITORY_URI"
echo "✅ Voxtral ECR login successful"
