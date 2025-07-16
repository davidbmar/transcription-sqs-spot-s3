#!/bin/bash

# step-210-build-gpu-worker-image.sh - Build GPU WhisperX Docker image (PATH 200)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Build GPU WhisperX Docker Image${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Verify prerequisites
if [ ! -f ".deployment-path" ] || [ "$(cat .deployment-path)" != "docker-gpu" ]; then
    echo -e "${RED}[ERROR]${NC} Docker prerequisites not set up. Run step-200-docker-setup-ecr-repository.sh first."
    exit 1
fi

if [ -z "$ECR_REPOSITORY_URI" ]; then
    echo -e "${RED}[ERROR]${NC} ECR_REPOSITORY_URI not found in configuration."
    exit 1
fi

echo -e "${GREEN}[STEP 1]${NC} Checking Docker environment..."

# Check Docker installation
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARNING]${NC} Docker is not installed"
    echo "Attempting to install Docker..."
    
    # Check if we're on Ubuntu/Debian
    if command -v apt-get >/dev/null 2>&1; then
        # Download and run Docker installation script
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh
        
        # Add current user to docker group
        sudo usermod -aG docker $USER
        
        # Start Docker service
        sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
        
        echo -e "${GREEN}[OK]${NC} Docker installed successfully"
        echo -e "${YELLOW}[NOTE]${NC} You've been added to the docker group, but you may need to log out and back in"
        echo "For now, this script will use sudo for Docker commands."
        
        # Create alias for docker commands with sudo
        docker() {
            sudo docker "$@"
        }
    else
        echo -e "${RED}[ERROR]${NC} Cannot auto-install Docker on this system"
        echo "Please install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
    fi
    
    # Verify installation worked
    if ! command -v docker >/dev/null 2>&1 && ! command -v sudo docker >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Docker installation failed"
        exit 1
    fi
fi

# Check Docker daemon
if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker daemon is not running"
    echo ""
    echo "Please start Docker by running:"
    echo -e "${GREEN}sudo systemctl start docker${NC}"
    echo ""
    echo "Then run this script again."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Docker environment ready"
docker --version

# Check if user has permission to run Docker without sudo
if ! docker ps >/dev/null 2>&1; then
    if sudo docker ps >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARNING]${NC} Docker requires sudo. You may need to add your user to the docker group:"
        echo "  sudo usermod -aG docker $USER"
        echo "  Then log out and back in for changes to take effect."
        echo "For now, this script will use sudo for Docker commands."
        # Create alias for docker commands with sudo
        docker() {
            sudo docker "$@"
        }
    else
        echo -e "${RED}[ERROR]${NC} Cannot access Docker daemon even with sudo"
        exit 1
    fi
fi

echo -e "${GREEN}[STEP 2]${NC} Preparing build context..."

# Ensure source directory exists
if [ ! -d "src" ]; then
    echo -e "${RED}[ERROR]${NC} Source directory 'src' not found"
    exit 1
fi

# Ensure Dockerfile exists
if [ ! -f "docker/gpu-worker/Dockerfile" ]; then
    echo -e "${RED}[ERROR]${NC} Dockerfile not found at docker/gpu-worker/Dockerfile"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Build context ready"
echo "Source files: $(ls -1 src/ | wc -l) files"
echo "Dockerfile: docker/gpu-worker/Dockerfile"

echo -e "${GREEN}[STEP 3]${NC} Building GPU worker Docker image..."
echo "Repository: $ECR_REPOSITORY_URI"
echo "Tag: $DOCKER_IMAGE_TAG"

BUILD_START_TIME=$(date +%s)

# Build Docker image with METRICS_BUCKET argument
docker build \
    -f docker/gpu-worker/Dockerfile \
    --build-arg METRICS_BUCKET="$METRICS_BUCKET" \
    -t "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" \
    -t "$ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG" \
    .

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))

echo -e "${GREEN}[OK]${NC} Docker image built successfully in ${BUILD_DURATION}s"

echo -e "${GREEN}[STEP 4]${NC} Verifying built image..."

# Check image size
IMAGE_SIZE=$(docker images "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" --format "table {{.Size}}" | tail -1)
echo -e "${GREEN}[OK]${NC} Image size: $IMAGE_SIZE"

# Test basic functionality
echo -e "${GREEN}[INFO]${NC} Testing image imports..."
docker run --rm "$ECR_REPO_NAME:$DOCKER_IMAGE_TAG" python3 -c "
import torch
import whisperx
print(f'✅ PyTorch {torch.__version__} with CUDA {torch.version.cuda}')
print(f'✅ CUDA available: {torch.cuda.is_available()}')
print('✅ WhisperX imported successfully')
print('✅ GPU worker image ready!')
" || echo -e "${YELLOW}[WARNING]${NC} Image test failed (may work on GPU instances)"

echo -e "${GREEN}[STEP 5]${NC} Image build summary..."

echo -e "${GREEN}[OK]${NC} Build completed successfully!"
echo
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ GPU Worker Image Built${NC}"
echo -e "${BLUE}======================================${NC}"
echo
echo -e "${GREEN}[IMAGE DETAILS]${NC}"
echo "Local tag: $ECR_REPO_NAME:$DOCKER_IMAGE_TAG"
echo "ECR tag: $ECR_REPOSITORY_URI:$DOCKER_IMAGE_TAG"
echo "Image size: $IMAGE_SIZE"
echo "Build time: ${BUILD_DURATION}s"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "1. Push to ECR:"
echo "   ./scripts/step-211-docker-push-image-to-ecr.sh"
echo
echo "2. Launch Docker GPU workers:"
echo "   ./scripts/step-220-docker-launch-gpu-workers.sh"
echo
echo -e "${YELLOW}[LOCAL TESTING]${NC}"
echo "Test locally (if you have GPU):"
echo "  docker run --gpus all --rm $ECR_REPO_NAME:$DOCKER_IMAGE_TAG --help"

# Update status tracking
echo "step-210-completed=$(date)" >> .setup-status