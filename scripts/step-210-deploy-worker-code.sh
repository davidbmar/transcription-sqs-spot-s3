#!/bin/bash
# COMPATIBILITY WRAPPER - Script has been renumbered
echo "⚠️  WARNING: This script has been renumbered!"
echo "   Old: step-210-deploy-worker-code.sh"
echo "   New: step-210-deploy-worker-code.sh"
echo "   Please update your scripts/documentation to use the new name."
echo ""
echo "   Redirecting to new script in 3 seconds..."
sleep 3
exec "$(dirname "$0")/step-210-deploy-worker-code.sh" "$@"
