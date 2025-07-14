#!/bin/bash
set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Run step-000-setup-configuration.sh first."
    exit 1
fi

# Check if path already selected
if [ -f ".deployment-path" ]; then
    DEPLOYMENT_PATH=$(cat .deployment-path)
    echo "⚠️  Deployment path already selected: $DEPLOYMENT_PATH"
    read -p "Do you want to change it? (y/N): " change_choice
    if [[ ! "$change_choice" =~ ^[Yy]$ ]]; then
        echo "Keeping current selection: $DEPLOYMENT_PATH"
        exit 0
    fi
fi

clear
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    🚀 CHOOSE DEPLOYMENT PATH 🚀                    ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║                                                                    ║"
echo "║  After this point, you need to choose your deployment approach:   ║"
echo "║                                                                    ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║                                                                    ║"
echo "║  Option A: TRADITIONAL EC2 (Proven Approach)                       ║"
echo "║  ────────────────────────────────────────────                     ║"
echo "║  ✅ Current production-tested approach                             ║"
echo "║  ✅ Direct GPU access with native performance                      ║"
echo "║  ✅ Simple debugging - SSH directly to instances                   ║"
echo "║  ✅ No containerization overhead                                   ║"
echo "║  ⚠️  Manual dependency management                                  ║"
echo "║  ⚠️  Slower instance startup (3-5 minutes)                        ║"
echo "║                                                                    ║"
echo "║  📂 Script Range: Traditional Path                                ║"
echo "║     • Implementation: step-100 through step-135                   ║"
echo "║     • Reserved: step-140 through step-199 (future updates)        ║"
echo "║     Start with: ./scripts/step-100-setup-ec2-configuration.sh     ║"
echo "║                                                                    ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║                                                                    ║"
echo "║  Option B: DOCKER ON EC2 GPU (Modern Approach)                    ║"
echo "║  ─────────────────────────────────────────────                    ║"
echo "║  ✅ Consistent environments across dev/prod                        ║"
echo "║  ✅ Easy rollbacks and version management                          ║"
echo "║  ✅ Better resource isolation and monitoring                       ║"
echo "║  ✅ Faster deployments with pre-built images                       ║"
echo "║  ⚠️  Requires Docker/container knowledge                           ║"
echo "║  ⚠️  Small GPU performance overhead (~2-3%)                        ║"
echo "║                                                                    ║"
echo "║  📂 Script Range: Docker Path                                     ║"
echo "║     • Implementation: step-200 through step-299                   ║"
echo "║     Start with: ./scripts/step-200-setup-docker-prerequisites.sh  ║"
echo "║                                                                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Quick Comparison:"
echo "├─ Setup Time: Traditional (30 min) vs Docker (45 min first time)"
echo "├─ Launch Time: Traditional (3-5 min) vs Docker (1-2 min)"
echo "├─ Maintenance: Traditional (manual) vs Docker (automated)"
echo "└─ Best For: Traditional (simplicity) vs Docker (scale)"
echo ""
echo "📁 Script Organization:"
echo "├─ Common Setup: step-000 to step-060 (shared by both paths)"
echo "├─ Traditional Path: step-100 to step-135 (current), step-140 to step-199 (future)"
echo "└─ Docker Path: step-200 to step-299 (new implementation)"
echo ""
read -p "Select your deployment path (A/B): " choice

case ${choice^^} in
    A)
        echo "traditional" > .deployment-path
        echo ""
        echo "✅ Traditional EC2 path selected!"
        echo ""
        echo "📋 Your next steps:"
        echo "1. Run: ./scripts/step-100-setup-ec2-configuration.sh"
        echo "2. Follow the traditional deployment sequence:"
        echo "   • Setup: steps 100-111 (EC2 config and worker code)"
        echo "   • Deploy: steps 120-125 (launch and health check)"
        echo "   • Test: steps 130-135 (fixes and validation)"
        echo "   • Future: steps 140-199 reserved for traditional path features"
        echo ""
        echo "📚 Documentation: See README.md section 'Traditional Deployment'"
        
        # Create convenience symlinks
        ln -sf ./scripts/step-120-launch-spot-worker.sh ./scripts/launch-worker.sh 2>/dev/null || true
        ln -sf ./scripts/step-125-check-worker-health.sh ./scripts/check-health.sh 2>/dev/null || true
        ;;
    B)
        echo "docker-gpu" > .deployment-path
        echo ""
        echo "🐳 Docker path selected!"
        echo ""
        echo "📋 Your next steps:"
        echo "1. Run: ./scripts/step-200-docker-setup-ecr-repository.sh"
        echo "2. Follow the Docker deployment sequence:"
        echo "   • Setup: steps 200-211 (Docker prerequisites and image build)"
        echo "   • Deploy: steps 220-225 (launch GPU workers with Docker)"
        echo "   • Operations: steps 230-235 (updates and testing)"
        echo "   • Advanced: steps 240-299 reserved for Docker path features"
        echo ""
        echo "📚 Documentation: See DOCKER_GPU_IMPLEMENTATION_PLAN.md"
        
        # Create convenience symlinks
        ln -sf ./scripts/step-220-docker-launch-gpu-workers.sh ./scripts/launch-worker.sh 2>/dev/null || true
        ln -sf ./scripts/step-225-docker-monitor-worker-health.sh ./scripts/check-health.sh 2>/dev/null || true
        ;;
    *)
        echo ""
        echo "❌ Invalid choice. Please run this script again and select A or B."
        exit 1
        ;;
esac

# Update status tracking
echo "step-060-completed=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> .setup-status
echo "deployment-path-selected=$DEPLOYMENT_PATH" >> .setup-status

echo ""
echo "💡 Tip: You can always change your path by running this script again."
echo "💡 Both paths use the same SQS queues and S3 buckets you've already configured."