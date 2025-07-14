#!/bin/bash
set -e

echo "============================================"
echo "🐳 Step 200: Setup Docker Prerequisites"
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

# Check deployment path
if [ -f ".deployment-path" ]; then
    DEPLOYMENT_PATH=$(cat .deployment-path)
    if [ "$DEPLOYMENT_PATH" != "docker" ] && [ "$DEPLOYMENT_PATH" != "docker-gpu" ]; then
        echo "⚠️  Warning: You selected the traditional path but are running Docker setup."
        echo "   Run step-060-choose-deployment-path.sh to switch to Docker path."
        read -p "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

echo "📋 This script will:"
echo "  1. Check Docker installation locally"
echo "  2. Create ECR repository for Docker images"
echo "  3. Setup Docker configuration directory"
echo "  4. Create initial Dockerfiles"
echo ""

# Function to check command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Check Docker installation
echo "🔍 Checking Docker installation..."
if command_exists docker; then
    DOCKER_VERSION=$(docker --version)
    echo "✅ Docker is installed: $DOCKER_VERSION"
else
    echo "❌ Docker is not installed."
    echo ""
    echo "📚 Please install Docker first:"
    echo "   - macOS/Windows: Download Docker Desktop from https://docker.com"
    echo "   - Linux: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not running. Please start Docker."
    exit 1
fi

# 2. Create ECR repository
echo ""
echo "🏗️ Setting up Amazon ECR (Elastic Container Registry)..."

# Generate ECR repository name using existing queue prefix
ECR_REPO_NAME="${QUEUE_PREFIX}-whisper-transcriber"
echo "   Repository name: $ECR_REPO_NAME"

# Check if repository exists
EXISTING_REPO=$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" 2>/dev/null || true)

if [ -n "$EXISTING_REPO" ]; then
    echo "✅ ECR repository already exists: $ECR_REPO_NAME"
    ECR_REPOSITORY_URI=$(echo "$EXISTING_REPO" | jq -r '.repositories[0].repositoryUri')
else
    echo "📦 Creating ECR repository..."
    CREATE_RESULT=$(aws ecr create-repository \
        --repository-name "$ECR_REPO_NAME" \
        --image-scanning-configuration scanOnPush=true \
        --region "$AWS_REGION")
    
    ECR_REPOSITORY_URI=$(echo "$CREATE_RESULT" | jq -r '.repository.repositoryUri')
    echo "✅ ECR repository created: $ECR_REPOSITORY_URI"
    
    # Set lifecycle policy to keep only last 10 images
    echo "📋 Setting lifecycle policy (keep last 10 images)..."
    aws ecr put-lifecycle-policy \
        --repository-name "$ECR_REPO_NAME" \
        --lifecycle-policy-text '{
            "rules": [{
                "rulePriority": 1,
                "description": "Keep last 10 images",
                "selection": {
                    "tagStatus": "any",
                    "countType": "imageCountMoreThan",
                    "countNumber": 10
                },
                "action": {
                    "type": "expire"
                }
            }]
        }' >/dev/null
fi

# Save ECR URI to config
echo ""
echo "💾 Saving ECR configuration..."
if ! grep -q "ECR_REPOSITORY_URI" "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "# Docker/ECR Configuration" >> "$CONFIG_FILE"
    echo "export ECR_REPOSITORY_URI=\"$ECR_REPOSITORY_URI\"" >> "$CONFIG_FILE"
    echo "export ECR_REPO_NAME=\"$ECR_REPO_NAME\"" >> "$CONFIG_FILE"
else
    # Update existing values
    sed -i.bak "s|^export ECR_REPOSITORY_URI=.*|export ECR_REPOSITORY_URI=\"$ECR_REPOSITORY_URI\"|" "$CONFIG_FILE"
    sed -i.bak "s|^export ECR_REPO_NAME=.*|export ECR_REPO_NAME=\"$ECR_REPO_NAME\"|" "$CONFIG_FILE"
fi

# 3. Create Docker directory structure
echo ""
echo "📁 Creating Docker directory structure..."
mkdir -p docker/{base,worker,test}
mkdir -p docker/worker/scripts

# 4. Create base Dockerfile for testing
echo ""
echo "📄 Creating test Dockerfile..."
cat > docker/test/Dockerfile << 'EOF'
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
EOF

echo "✅ Created docker/test/Dockerfile"

# 5. Create .dockerignore
echo ""
echo "📄 Creating .dockerignore..."
cat > .dockerignore << 'EOF'
# Git files
.git
.gitignore

# Python cache
__pycache__
*.pyc
*.pyo
*.pyd
.Python
*.egg-info
.pytest_cache

# Environment files
.env
.env.*
!.env.template

# Logs
*.log
logs/

# AWS credentials
.aws/
*.pem

# IDE files
.vscode/
.idea/
*.swp
*.swo

# OS files
.DS_Store
Thumbs.db

# Build artifacts
build/
dist/
*.tar.gz

# Documentation
*.md
docs/

# Temporary files
tmp/
temp/
EOF

echo "✅ Created .dockerignore"

# 6. Test Docker build
echo ""
echo "🧪 Testing Docker build with minimal image..."
cd docker/test
if docker build -t whisper-test:latest .; then
    echo "✅ Docker build successful!"
    echo ""
    echo "🏃 Running test container..."
    docker run --rm whisper-test:latest
    cd ../..
else
    echo "❌ Docker build failed. Please check the error messages above."
    cd ../..
    exit 1
fi

# Update status
echo ""
echo "✅ Docker prerequisites setup completed!"
echo ""
echo "📊 Summary:"
echo "  • Docker: Installed and running"
echo "  • ECR Repository: $ECR_REPOSITORY_URI"
echo "  • Docker directories: Created"
echo "  • Test build: Successful"
echo ""
echo "📋 Next steps:"
echo "  1. Run: ./scripts/step-201-validate-docker-setup.sh"
echo "  2. Then: ./scripts/step-210-build-worker-image.sh"
echo ""

# Update setup status
echo "step-301-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
echo "ecr-repository-uri=$ECR_REPOSITORY_URI" >> .setup-status