#!/bin/bash
set -e

echo "============================================"
echo "✅ Step 201: Validate Docker Setup"
echo "============================================"
echo ""

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check if step-200 was completed
if ! grep -q "step-302-completed" .setup-status 2>/dev/null; then
    echo "❌ Error: step-200-setup-docker-prerequisites.sh must be run first."
    exit 1
fi

echo "🔍 Validating Docker setup..."
echo ""

# Track validation results
VALIDATION_PASSED=true
VALIDATION_RESULTS=()

# Function to add validation result
add_result() {
    local status=$1
    local message=$2
    VALIDATION_RESULTS+=("$status $message")
    if [ "$status" = "❌" ]; then
        VALIDATION_PASSED=false
    fi
}

# 1. Check Docker installation
echo "1️⃣ Checking Docker installation..."
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker --version)
    add_result "✅" "Docker installed: $DOCKER_VERSION"
else
    add_result "❌" "Docker not installed"
fi

# 2. Check Docker daemon
echo "2️⃣ Checking Docker daemon..."
if docker info >/dev/null 2>&1; then
    add_result "✅" "Docker daemon running"
else
    add_result "❌" "Docker daemon not running"
fi

# 3. Check ECR repository
echo "3️⃣ Checking ECR repository..."
if [ -n "$ECR_REPOSITORY_URI" ]; then
    ECR_REPO_NAME=$(echo "$ECR_REPOSITORY_URI" | cut -d'/' -f2)
    if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1; then
        add_result "✅" "ECR repository exists: $ECR_REPO_NAME"
    else
        add_result "❌" "ECR repository not found: $ECR_REPO_NAME"
    fi
else
    add_result "❌" "ECR_REPOSITORY_URI not set in config"
fi

# 4. Check Docker directory structure
echo "4️⃣ Checking Docker directory structure..."
REQUIRED_DIRS=("docker" "docker/base" "docker/worker" "docker/test")
for dir in "${REQUIRED_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        add_result "✅" "Directory exists: $dir"
    else
        add_result "❌" "Directory missing: $dir"
    fi
done

# 5. Check test Dockerfile
echo "5️⃣ Checking test Dockerfile..."
if [ -f "docker/test/Dockerfile" ]; then
    add_result "✅" "Test Dockerfile exists"
else
    add_result "❌" "Test Dockerfile missing"
fi

# 6. Check .dockerignore
echo "6️⃣ Checking .dockerignore..."
if [ -f ".dockerignore" ]; then
    add_result "✅" ".dockerignore exists"
else
    add_result "❌" ".dockerignore missing"
fi

# 7. Test Docker build capability
echo "7️⃣ Testing Docker build capability..."
cd docker/test
if docker build -t whisper-test-validation:latest . >/dev/null 2>&1; then
    add_result "✅" "Docker build test successful"
    # Clean up test image
    docker rmi whisper-test-validation:latest >/dev/null 2>&1 || true
else
    add_result "❌" "Docker build test failed"
fi
cd ../..

# 8. Test ECR authentication
echo "8️⃣ Testing ECR authentication..."
if aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPOSITORY_URI" >/dev/null 2>&1; then
    add_result "✅" "ECR authentication successful"
else
    add_result "❌" "ECR authentication failed"
fi

# 9. Check AWS permissions
echo "9️⃣ Checking AWS permissions..."
REQUIRED_PERMISSIONS=("ecr:GetAuthorizationToken" "ecr:BatchCheckLayerAvailability" "ecr:GetDownloadUrlForLayer" "ecr:BatchGetImage" "ecr:PutImage" "ecr:InitiateLayerUpload" "ecr:UploadLayerPart" "ecr:CompleteLayerUpload")
# Note: This is a simplified check - actual permission testing would require more complex setup
if aws sts get-caller-identity >/dev/null 2>&1; then
    add_result "✅" "AWS credentials configured"
else
    add_result "❌" "AWS credentials not configured"
fi

# 10. Check disk space
echo "🔟 Checking disk space..."
AVAILABLE_SPACE=$(df -h . | awk 'NR==2 {print $4}')
AVAILABLE_SPACE_GB=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE_SPACE_GB" -gt 10 ]; then
    add_result "✅" "Sufficient disk space: $AVAILABLE_SPACE available"
else
    add_result "⚠️" "Low disk space: $AVAILABLE_SPACE available (recommend 10GB+)"
fi

# Display results
echo ""
echo "📊 Validation Results:"
echo "====================="
for result in "${VALIDATION_RESULTS[@]}"; do
    echo "   $result"
done

echo ""
if [ "$VALIDATION_PASSED" = true ]; then
    echo "🎉 All validations passed! Docker setup is ready."
    echo ""
    echo "📋 Next steps:"
    echo "  1. Run: ./scripts/step-210-build-worker-image.sh"
    echo "  2. Then: ./scripts/step-211-push-to-ecr.sh"
    echo ""
    
    # Update setup status
    echo "step-302-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
    echo "docker-validation-passed=true" >> .setup-status
    
    # Create summary file
    cat > docker/DOCKER_SETUP_SUMMARY.md << EOF
# Docker Setup Summary

## Configuration
- ECR Repository: $ECR_REPOSITORY_URI
- Region: $AWS_REGION
- Docker Version: $DOCKER_VERSION

## Validation Results
$(printf '%s\n' "${VALIDATION_RESULTS[@]}")

## Generated Files
- docker/test/Dockerfile
- docker/base/ (directory)
- docker/worker/ (directory)
- .dockerignore

## Next Steps
1. Build worker image: \`./scripts/step-210-build-worker-image.sh\`
2. Push to ECR: \`./scripts/step-211-push-to-ecr.sh\`
3. Launch worker: \`./scripts/step-220-launch-docker-worker.sh\`

Generated: $(date)
EOF
    echo "📄 Created docker/DOCKER_SETUP_SUMMARY.md"
    
else
    echo "❌ Some validations failed. Please fix the issues above before proceeding."
    echo ""
    echo "🔧 Common fixes:"
    echo "  • Docker not running: Start Docker Desktop or run 'sudo systemctl start docker'"
    echo "  • AWS credentials: Run 'aws configure' or check IAM permissions"
    echo "  • ECR issues: Re-run step-200-setup-docker-prerequisites.sh"
    exit 1
fi