#!/bin/bash
# Real Voxtral ECR Login Helper Script
set -e

source .env
echo "🔐 Logging into ECR for Real Voxtral..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REAL_VOXTRAL_ECR_REPOSITORY_URI"
echo "✅ Real Voxtral ECR login successful"
