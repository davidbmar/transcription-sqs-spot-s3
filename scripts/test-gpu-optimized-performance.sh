#!/bin/bash
# Test GPU Optimized Performance

set -e

# Load configuration
source .env

echo "🚀 GPU OPTIMIZED PERFORMANCE TEST"
echo "================================="
echo "This will compare standard vs optimized GPU transcription"
echo ""

# Create test script
cat > /tmp/test_gpu_optimized.py << 'EOF'
#!/usr/bin/env python3
import time
import boto3
import json
import sys
import os
sys.path.append('/opt/transcription-worker')
sys.path.append('src')

# Import both transcribers
try:
    from transcriber import Transcriber
    from transcriber_gpu_optimized import GPUOptimizedTranscriber
except ImportError:
    print("❌ Failed to import transcribers. Trying local path...")
    sys.path.append(os.path.dirname(os.path.abspath(__file__)) + '/../src')
    from transcriber import Transcriber
    from transcriber_gpu_optimized import GPUOptimizedTranscriber

import logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def test_transcriber(transcriber_class, name, test_file):
    """Test a transcriber with timing"""
    print(f"\n🧪 Testing {name}")
    print("=" * 50)
    
    try:
        # Initialize transcriber
        start_init = time.time()
        transcriber = transcriber_class(
            model_name="large-v3",
            device="cuda",
            batch_size=64 if "Optimized" in name else 32
        )
        init_time = time.time() - start_init
        print(f"✅ Initialization: {init_time:.2f}s")
        
        # Load model
        start_load = time.time()
        transcriber.load_model()
        load_time = time.time() - start_load
        print(f"✅ Model loading: {load_time:.2f}s")
        
        # Transcribe
        print(f"📝 Transcribing: {test_file}")
        start_trans = time.time()
        result = transcriber.transcribe_audio(test_file)
        trans_time = time.time() - start_trans
        
        # Calculate metrics
        audio_duration = 60  # seconds
        rtf = trans_time / audio_duration
        speedup = audio_duration / trans_time
        
        print(f"✅ Transcription complete!")
        print(f"   - Transcription time: {trans_time:.2f}s")
        print(f"   - Real-time factor: {rtf:.3f}")
        print(f"   - Speed: {speedup:.1f}x realtime")
        print(f"   - Segments: {len(result.get('segments', []))}")
        
        return {
            "name": name,
            "init_time": init_time,
            "load_time": load_time,
            "trans_time": trans_time,
            "rtf": rtf,
            "speedup": speedup,
            "segments": len(result.get('segments', []))
        }
        
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        return None

def main():
    # Test file
    test_file = "/tmp/test_audio.webm"
    
    # Download test file if needed
    if not os.path.exists(test_file):
        print("📥 Downloading test file...")
        s3 = boto3.client('s3', region_name='${AWS_REGION}')
        s3.download_file('${AUDIO_BUCKET}', 'integration-test/00060-00120.webm', test_file)
        print("✅ Test file ready")
    
    results = []
    
    # Test standard transcriber
    result1 = test_transcriber(Transcriber, "Standard Transcriber", test_file)
    if result1:
        results.append(result1)
    
    # Test GPU optimized transcriber
    result2 = test_transcriber(GPUOptimizedTranscriber, "GPU Optimized Transcriber", test_file)
    if result2:
        results.append(result2)
    
    # Print comparison
    if len(results) == 2:
        print("\n📊 PERFORMANCE COMPARISON")
        print("=" * 60)
        print(f"{'Metric':<25} {'Standard':<15} {'Optimized':<15} {'Improvement':<10}")
        print("-" * 60)
        
        std = results[0]
        opt = results[1]
        
        metrics = [
            ("Model Load Time", "load_time", "s", True),
            ("Transcription Time", "trans_time", "s", True),
            ("Real-time Factor", "rtf", "", True),
            ("Speed (x realtime)", "speedup", "x", False)
        ]
        
        for metric_name, key, unit, lower_better in metrics:
            std_val = std[key]
            opt_val = opt[key]
            
            if lower_better:
                improvement = (std_val - opt_val) / std_val * 100
            else:
                improvement = (opt_val - std_val) / std_val * 100
            
            print(f"{metric_name:<25} {std_val:<14.2f}{unit} {opt_val:<14.2f}{unit} {improvement:>8.1f}%")
        
        print("-" * 60)
        overall_speedup = std["trans_time"] / opt["trans_time"]
        print(f"🚀 OVERALL SPEEDUP: {overall_speedup:.2f}x")
        
        if overall_speedup > 2:
            print(f"🎉 GPU Optimized is {overall_speedup:.1f}x FASTER!")
        else:
            print(f"⚠️  Only {overall_speedup:.1f}x improvement - check GPU utilization")

if __name__ == "__main__":
    main()
EOF

# Run the test
echo "Running GPU optimization test..."
python3 /tmp/test_gpu_optimized.py