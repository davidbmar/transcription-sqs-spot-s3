#!/bin/bash
set -e

# Create compatibility wrappers for old script names
create_wrapper() {
    local old_name=$1
    local new_name=$2
    local old_path="scripts/$old_name"
    
    cat > "$old_path" << EOF
#!/bin/bash
# COMPATIBILITY WRAPPER - Script has been renumbered
echo "⚠️  WARNING: This script has been renumbered!"
echo "   Old: $old_name"
echo "   New: $new_name"
echo "   Please update your scripts/documentation to use the new name."
echo ""
echo "   Redirecting to new script in 3 seconds..."
sleep 3
exec "\$(dirname "\$0")/$new_name" "\$@"
EOF
    chmod +x "$old_path"
    echo "✅ Created wrapper: $old_name → $new_name"
}

echo "Creating compatibility wrappers..."
echo ""

create_wrapper "step-025-setup-ec2-configuration.sh" "step-100-setup-ec2-configuration.sh"
create_wrapper "step-026-validate-ec2-configuration.sh" "step-101-validate-ec2-configuration.sh"
create_wrapper "step-030-deploy-worker-code.sh" "step-110-deploy-worker-code.sh"
create_wrapper "step-031-validate-worker-code.sh" "step-111-validate-worker-code.sh"
create_wrapper "step-040-launch-spot-worker.sh" "step-120-launch-spot-worker.sh"
create_wrapper "step-045-check-worker-health.sh" "step-125-check-worker-health.sh"
create_wrapper "step-050-update-system-fixes.sh" "step-130-update-system-fixes.sh"
create_wrapper "step-055-test-complete-workflow.sh" "step-135-test-complete-workflow.sh"

echo ""
echo "✅ All compatibility wrappers created!"
echo ""
echo "These wrappers will:"
echo "1. Warn users about the renumbering"
echo "2. Wait 3 seconds"
echo "3. Redirect to the new script with all arguments"