#!/bin/bash
# pin-dependency-versions.sh - Script to verify and update pinned dependency versions

set -e

echo "🔍 Checking for unpinned dependencies in launch scripts..."
echo

# Function to check file for unpinned pip installs
check_unpinned() {
    local file=$1
    echo "Checking: $file"
    
    # Look for pip install commands without version pins
    grep -n "pip3 install" "$file" | grep -v "==" | grep -v -- "--upgrade pip" | grep -v "git+" || true
    
    echo
}

# Check all launch scripts
for script in scripts/launch*.sh scripts/step-*.sh; do
    if [ -f "$script" ]; then
        if grep -q "pip3 install" "$script" 2>/dev/null; then
            check_unpinned "$script"
        fi
    fi
done

echo "✅ Dependency version check complete"
echo
echo "📌 All dependencies should be pinned to specific versions to ensure:"
echo "   - Reproducible builds over time"
echo "   - No surprise breaking changes"
echo "   - Consistent behavior across deployments"
echo
echo "📄 See requirements-gpu-dlami.txt for the canonical pinned versions"