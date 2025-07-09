# Migration Plan: Implementing Branching Architecture

## 🎯 Objective
Restructure existing scripts to support dual deployment paths while maintaining backward compatibility.

## 📋 Implementation Checklist

### Phase 1: Preparation
- [ ] Create backup of current scripts directory
- [ ] Document current script dependencies
- [ ] Test current system still works
- [ ] Create migration tracking file

### Phase 2: Create Branch Point Script
```bash
# New script: step-025-choose-deployment-path.sh
#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════╗"
echo "║        Choose Your Deployment Path             ║"
echo "╠════════════════════════════════════════════════╣"
echo "║                                                ║"
echo "║  A) Traditional EC2 + Direct Install           ║"
echo "║     ✓ Current proven approach                  ║"
echo "║     ✓ Direct GPU access                        ║"
echo "║     ✓ No Docker overhead                       ║"
echo "║                                                ║"
echo "║  B) Docker Containers on EC2 GPU               ║"
echo "║     ✓ Consistent environments                  ║"
echo "║     ✓ Easy rollbacks                          ║"
echo "║     ✓ Better scaling                          ║"
echo "║                                                ║"
echo "╚════════════════════════════════════════════════╝"

read -p "Select path (A/B): " choice

case $choice in
    [Aa])
        echo "DEPLOYMENT_PATH=traditional" > .deployment-path
        echo "✅ Traditional path selected"
        echo ""
        echo "Next steps:"
        echo "  ./scripts/step-100-setup-ec2-configuration.sh"
        ;;
    [Bb])
        echo "DEPLOYMENT_PATH=docker" > .deployment-path
        echo "✅ Docker path selected"
        echo ""
        echo "Next steps:"
        echo "  ./scripts/step-200-setup-docker-prerequisites.sh"
        ;;
    *)
        echo "❌ Invalid choice. Please run again and select A or B."
        exit 1
        ;;
esac
```

### Phase 3: Renumber Existing Scripts

#### Rename Commands:
```bash
# Create mapping file first
cat > script-rename-map.txt << 'EOF'
step-025-setup-ec2-configuration.sh:step-100-setup-ec2-configuration.sh
step-026-validate-ec2-configuration.sh:step-101-validate-ec2-configuration.sh
step-030-deploy-worker-code.sh:step-110-deploy-worker-code.sh
step-031-validate-worker-code.sh:step-111-validate-worker-code.sh
step-040-launch-spot-worker.sh:step-120-launch-spot-worker.sh
step-045-check-worker-health.sh:step-125-check-worker-health.sh
step-050-update-system-fixes.sh:step-130-update-system-fixes.sh
step-055-test-complete-workflow.sh:step-135-test-complete-workflow.sh
EOF

# Backup and rename script
./scripts/migrate-script-numbers.sh
```

### Phase 4: Create Docker Path Scripts

#### Initial Docker Scripts:
```
step-200-setup-docker-prerequisites.sh
step-201-validate-docker-setup.sh
step-210-build-worker-image.sh
step-211-push-to-ecr.sh
step-220-launch-docker-worker.sh
step-225-check-docker-health.sh
step-230-update-docker-workers.sh
step-235-test-docker-workflow.sh
```

### Phase 5: Update Documentation

#### Files to Update:
1. `README.md` - Add path selection info
2. `CLAUDE.md` - Update script numbers
3. Create `PATH_SELECTION_GUIDE.md`
4. Update any hardcoded script references

### Phase 6: Create Helper Scripts

#### Smart Launcher:
```bash
# scripts/launch-worker.sh
#!/bin/bash
if [ -f .deployment-path ]; then
    source .deployment-path
    if [ "$DEPLOYMENT_PATH" = "docker" ]; then
        exec ./scripts/step-220-launch-docker-worker.sh "$@"
    else
        exec ./scripts/step-120-launch-spot-worker.sh "$@"
    fi
else
    echo "❌ No deployment path selected. Run step-025-choose-deployment-path.sh first"
    exit 1
fi
```

## 🔄 Backward Compatibility

### Compatibility Script:
```bash
# scripts/step-040-launch-spot-worker.sh (compatibility wrapper)
#!/bin/bash
echo "⚠️  DEPRECATED: This script number has changed"
echo "   Please use: ./scripts/step-120-launch-spot-worker.sh"
echo "   Running new script for backward compatibility..."
exec ./scripts/step-120-launch-spot-worker.sh "$@"
```

## 📊 Migration Timeline

### Week 1:
- Day 1-2: Create branch point script
- Day 3-4: Renumber traditional path scripts  
- Day 5: Test traditional path works

### Week 2:
- Day 1-3: Implement Docker path scripts
- Day 4-5: Integration testing both paths

### Week 3:
- Day 1-2: Update all documentation
- Day 3-4: Create migration guides
- Day 5: Team training on new structure

## 🚦 Success Criteria

1. **Both Paths Work**: Can deploy using either approach
2. **Clear Documentation**: Users understand which path to choose
3. **No Breaking Changes**: Existing deployments continue working
4. **Easy Switching**: Can change paths without rebuilding
5. **Performance Parity**: Docker path matches traditional performance

## 📝 Testing Checklist

### Traditional Path:
- [ ] Fresh checkout → successful deployment
- [ ] All scripts run in correct order
- [ ] GPU transcription works
- [ ] Monitoring/logs functional

### Docker Path:
- [ ] Fresh checkout → successful deployment
- [ ] Docker images build correctly
- [ ] GPU passthrough works
- [ ] Container logs accessible

### Migration:
- [ ] Can switch from traditional → Docker
- [ ] Can switch from Docker → traditional
- [ ] No data loss during switch
- [ ] Clear rollback procedure

## 🎉 Final Structure

```
User runs setup (000-024)
           ↓
    Chooses path (025)
         ↙   ↘
Traditional   Docker
 (100-199)   (200-299)
         ↘   ↙
    Production Use
```

This approach gives users choice while maintaining system integrity!