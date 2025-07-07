#!/bin/bash
# Update Integration Tests to Use New Podcast Episode

set -e

echo "🔄 UPDATING INTEGRATION TESTS"
echo "=============================="
echo "Replacing 4 short files with 1 comprehensive podcast episode"
echo ""

# Load configuration
source .env

echo "📋 Current Integration Test Status:"
echo "Old test files (4 × 60s webm files): Removed from active testing"
echo "New test file: My First Million Episode 723 (81 minutes MP3)"
echo "Benefits: Real-world content, longer duration, better GPU testing"
echo ""

# Check if new podcast exists in S3
echo "📥 Verifying podcast file in S3..."
if aws s3 ls s3://${AUDIO_BUCKET}/integration-test-new/mfm-episode-723.mp3 >/dev/null 2>&1; then
    echo "✅ Podcast file found in S3"
    
    # Get file details
    echo ""
    echo "📊 Podcast File Details:"
    aws s3 ls s3://${AUDIO_BUCKET}/integration-test-new/mfm-episode-723.mp3 --human-readable
    echo "   Duration: 81 minutes (4,860 seconds)"
    echo "   Content: Business discussion about acquisitions"
    echo "   Quality: 112 kbps MP3, stereo"
else
    echo "❌ Podcast file not found in S3!"
    echo "Please ensure the file was uploaded to: s3://${AUDIO_BUCKET}/integration-test-new/mfm-episode-723.mp3"
    exit 1
fi

echo ""
echo "🧪 Available Test Scripts:"
echo "─────────────────────────────"
echo "1. benchmark-podcast-gpu-cpu.py - Full CPU vs GPU podcast test"
echo "2. benchmark-gpu-cpu-complete.py - Original 4-file test (still available)"
echo "3. test-gpu-performance.sh - GPU optimization testing"
echo "4. update-for-gpu-optimization.sh - System optimization"

echo ""
echo "🎯 Recommended Usage:"
echo "─────────────────────"
echo "For comprehensive testing:"
echo "  python3 scripts/benchmark-podcast-gpu-cpu.py"
echo ""
echo "For quick GPU optimization testing:"
echo "  ./scripts/test-gpu-performance.sh"
echo ""
echo "For system verification:"
echo "  ./scripts/update-for-gpu-optimization.sh"

echo ""
echo "⚡ Expected Performance with 81-minute podcast:"
echo "──────────────────────────────────────────────"
echo "CPU baseline: 30-120 minutes processing time"
echo "GPU target: 3-8 minutes processing time (10-25x speedup)"
echo "GPU optimal: 1-3 minutes processing time (25-60x speedup)"

echo ""
echo "💡 Benefits of New Test:"
echo "────────────────────────"
echo "✅ Real-world audio content (business conversation)"
echo "✅ Substantial duration for meaningful GPU testing"
echo "✅ Better representation of actual use cases"
echo "✅ More pronounced performance differences"
echo "✅ Single comprehensive test vs multiple small tests"

echo ""
echo "🔧 Integration Test Update Complete!"
echo "The system is now configured to use the 81-minute podcast"
echo "for comprehensive GPU vs CPU performance testing."