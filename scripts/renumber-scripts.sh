#!/bin/bash
set -e

echo "🔄 Script Renumbering Tool"
echo "========================="
echo ""
echo "This will renumber scripts to support the branching architecture:"
echo "- Common setup: 000-060 (unchanged)"
echo "- Traditional path: 100-199 (was 025-055)"
echo "- Docker path: 200-299 (new)"
echo ""

# Create renaming map
declare -A rename_map=(
    ["step-025-setup-ec2-configuration.sh"]="step-100-setup-ec2-configuration.sh"
    ["step-026-validate-ec2-configuration.sh"]="step-101-validate-ec2-configuration.sh"
    ["step-030-deploy-worker-code.sh"]="step-110-deploy-worker-code.sh"
    ["step-031-validate-worker-code.sh"]="step-111-validate-worker-code.sh"
    ["step-040-launch-spot-worker.sh"]="step-120-launch-spot-worker.sh"
    ["step-045-check-worker-health.sh"]="step-125-check-worker-health.sh"
    ["step-050-update-system-fixes.sh"]="step-130-update-system-fixes.sh"
    ["step-055-test-complete-workflow.sh"]="step-135-test-complete-workflow.sh"
)

# Check if running in dry-run mode
DRY_RUN=${1:-false}

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "🔍 DRY RUN MODE - No changes will be made"
    echo ""
fi

echo "📋 Planned renames:"
echo "==================="
for old_name in "${!rename_map[@]}"; do
    new_name="${rename_map[$old_name]}"
    if [ -f "scripts/$old_name" ]; then
        echo "  ✓ $old_name → $new_name"
    else
        echo "  ⚠️  $old_name (not found)"
    fi
done
echo ""

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "To execute the renaming, run without --dry-run flag"
    exit 0
fi

read -p "Proceed with renaming? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Cancelled"
    exit 1
fi

echo ""
echo "🚀 Renaming scripts..."
echo ""

# Perform the renaming
success_count=0
error_count=0

for old_name in "${!rename_map[@]}"; do
    new_name="${rename_map[$old_name]}"
    old_path="scripts/$old_name"
    new_path="scripts/$new_name"
    
    if [ -f "$old_path" ]; then
        if mv "$old_path" "$new_path"; then
            echo "  ✅ Renamed: $old_name → $new_name"
            ((success_count++))
            
            # Create compatibility wrapper
            cat > "$old_path" << EOF
#!/bin/bash
# COMPATIBILITY WRAPPER - Script has been renumbered
echo "⚠️  WARNING: This script has been renumbered!"
echo "   Old: $old_name"
echo "   New: $new_name"
echo "   Please update your scripts to use the new name."
echo ""
echo "   Redirecting to new script in 3 seconds..."
sleep 3
exec "\$(dirname "\$0")/$new_name" "\$@"
EOF
            chmod +x "$old_path"
            echo "     Created compatibility wrapper"
            
        else
            echo "  ❌ Failed to rename: $old_name"
            ((error_count++))
        fi
    else
        echo "  ⏭️  Skipped: $old_name (not found)"
    fi
done

echo ""
echo "📊 Summary:"
echo "  ✅ Successfully renamed: $success_count scripts"
if [ $error_count -gt 0 ]; then
    echo "  ❌ Errors: $error_count scripts"
fi

echo ""
echo "📝 Next steps:"
echo "1. Update CLAUDE.md with new script numbers"
echo "2. Update README.md references"
echo "3. Test the renamed scripts"
echo "4. Update step-060 if needed"

# Create a reference file
cat > scripts/SCRIPT_NUMBERING_REFERENCE.md << 'EOF'
# Script Numbering Reference

## After Renumbering (Current Structure)

### Common Setup (000-060) - Shared by all paths
- step-000-setup-configuration.sh
- step-001-validate-configuration.sh
- step-010-setup-iam-permissions.sh
- step-011-validate-iam-permissions.sh
- step-020-create-sqs-resources.sh
- step-021-validate-sqs-resources.sh
- step-060-choose-deployment-path.sh ← BRANCH POINT

### Traditional Path (100-199)
- step-100-setup-ec2-configuration.sh (was 025)
- step-101-validate-ec2-configuration.sh (was 026)
- step-110-deploy-worker-code.sh (was 030)
- step-111-validate-worker-code.sh (was 031)
- step-120-launch-spot-worker.sh (was 040)
- step-125-check-worker-health.sh (was 045)
- step-130-update-system-fixes.sh (was 050)
- step-135-test-complete-workflow.sh (was 055)
- step-140-199: Reserved for future traditional path features

### Docker Path (200-299)
- step-200-setup-docker-prerequisites.sh
- step-201-validate-docker-setup.sh
- step-210-build-worker-image.sh
- step-211-push-to-ecr.sh
- step-220-launch-docker-worker.sh
- step-225-check-docker-health.sh
- step-230-update-docker-workers.sh
- step-235-test-docker-workflow.sh
- step-240-299: Reserved for future Docker features

### Utilities (999)
- step-999-terminate-workers-or-selective-cleanup.sh
- step-999-destroy-all-resources-complete-teardown.sh
EOF

echo ""
echo "✅ Created scripts/SCRIPT_NUMBERING_REFERENCE.md for documentation"