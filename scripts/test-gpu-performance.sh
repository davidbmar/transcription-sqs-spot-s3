#!/bin/bash
# Test GPU Performance with Optimizations

set -e

# Load configuration
source .env

echo "🧪 GPU PERFORMANCE TEST"
echo "======================"

# Create test script
cat > /tmp/test_gpu_perf.py << 'EOF'
import time
import torch
import whisperx
import numpy as np

print("\n🔍 GPU Performance Test")
print("=" * 50)

# Check GPU
print(f"CUDA Available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"GPU: {torch.cuda.get_device_name(0)}")
    print(f"CUDA Version: {torch.version.cuda}")
    
# Test different models
models = ["base", "small", "medium", "large-v3"]
batch_sizes = [1, 8, 16, 32, 64]

print("\n📊 Model Loading Times:")
print("-" * 50)

for model_name in models:
    try:
        start = time.time()
        model = whisperx.load_model(model_name, "cuda", compute_type="float16")
        load_time = time.time() - start
        print(f"{model_name}: {load_time:.2f}s")
        
        # Test batch processing
        if model_name == "large-v3":
            print(f"\n🚀 Testing {model_name} with different batch sizes:")
            
            # Create dummy audio (30 seconds)
            audio = np.random.randn(30 * 16000).astype(np.float32)
            
            for batch_size in batch_sizes:
                try:
                    start = time.time()
                    result = model.transcribe(audio, batch_size=batch_size)
                    trans_time = time.time() - start
                    rtf = trans_time / 30  # Real-time factor
                    print(f"  Batch {batch_size}: {trans_time:.2f}s (RTF: {rtf:.3f})")
                except Exception as e:
                    print(f"  Batch {batch_size}: Failed - {str(e)}")
                    
        del model
        torch.cuda.empty_cache()
        
    except Exception as e:
        print(f"{model_name}: Failed - {str(e)}")

print("\n💡 Recommendations:")
print("-" * 50)
print("- Use large-v3 for best quality")
print("- Use batch_size=32 or 64 for optimal GPU utilization")
print("- Ensure float16 compute type is used")
print("- RTF < 1.0 means faster than real-time")
EOF

# Run test
python3 /tmp/test_gpu_perf.py