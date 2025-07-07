# GPU Performance Optimization Guide

## Problem: GPU Only 2x Faster Than CPU

The initial implementation showed GPU performance of only 2x faster than CPU, instead of the expected 25-63x speedup for WhisperX.

## Root Causes Identified

### 1. **Model Size Issue**
- **Problem**: Using "base" model instead of "large-v3"
- **Impact**: Smaller models don't benefit as much from GPU acceleration
- **Solution**: Changed default model to "large-v3" in launch scripts

### 2. **Suboptimal Batch Size**
- **Problem**: Batch size of 16 is too small for GPU
- **Impact**: GPU underutilization
- **Solution**: Increased batch size to 32 (standard) or 64 (optimized)

### 3. **Sequential Processing**
- **Problem**: Processing audio chunks one at a time
- **Impact**: No parallel GPU utilization
- **Solution**: Implemented parallel chunk processing with GPU batching

### 4. **Missing GPU Optimizations**
- **Problem**: Not using GPU-specific optimizations
- **Impact**: Slower inference
- **Solutions**:
  - Enabled `cudnn.benchmark = True`
  - Enabled TF32 for matrix operations
  - Implemented int8_float16 quantization for large models

### 5. **Voice Activity Detection Overhead**
- **Problem**: Conservative VAD parameters
- **Impact**: Extra CPU processing overhead
- **Solution**: Adjusted VAD parameters for better GPU throughput

## Implemented Solutions

### 1. Updated Worker Configuration
```bash
# Changed from:
--model base

# To:
--model large-v3
```

### 2. Created GPU-Optimized Transcriber
- Batch processing of multiple chunks simultaneously
- Parallel audio preprocessing
- Optimized memory management
- Support for int8 quantization on compatible GPUs

### 3. Performance Optimizations
```python
# GPU-specific settings
torch.backends.cudnn.benchmark = True
torch.backends.cuda.matmul.allow_tf32 = True

# Optimal batch size for T4 GPU
batch_size = 64

# Parallel preprocessing
num_workers = 2
```

## Expected Performance After Optimization

### Before Optimization
- Model: base
- Batch size: 16
- Sequential processing
- **Performance**: ~2x faster than CPU

### After Optimization
- Model: large-v3
- Batch size: 64
- Parallel batch processing
- Int8 quantization (when supported)
- **Expected Performance**: 15-30x faster than CPU

## Testing the Optimization

1. **Run the optimization test script**:
```bash
python3 scripts/test-gpu-optimization.py
```

2. **Run full benchmark**:
```bash
python3 scripts/benchmark-gpu-cpu-complete.py
```

## GPU Memory Considerations

### T4 GPU (16GB VRAM)
- Can handle batch_size=64 with large-v3 model
- Supports int8 quantization for faster inference

### Monitoring GPU Usage
```bash
# SSH into worker and run:
nvidia-smi -l 1  # Updates every second

# Check GPU utilization during transcription
watch -n 0.5 nvidia-smi
```

## Troubleshooting

### Issue: Out of Memory (OOM)
- Reduce batch_size to 32 or 16
- Use smaller model (large-v2 instead of large-v3)
- Ensure no other processes are using GPU

### Issue: Still Slow Performance
1. Check GPU utilization with `nvidia-smi`
2. Verify model is loading on GPU (check logs)
3. Ensure audio files are being batched properly
4. Check for CPU bottlenecks in preprocessing

### Issue: Quantization Not Working
- Not all GPUs support int8
- Fallback to float16 is automatic
- Check logs for quantization messages

## Cost-Performance Trade-offs

### g4dn.xlarge (T4 GPU)
- Cost: ~$0.526/hour spot
- Performance: 15-30x faster than CPU
- Best for: Large batches, production workloads

### CPU (c5.2xlarge)
- Cost: ~$0.20/hour spot
- Performance: Baseline
- Best for: Small jobs, testing

## Recommendations

1. **For Production**: Use GPU-optimized transcriber with large-v3 model
2. **For Testing**: Can use standard transcriber with base model
3. **For Cost Optimization**: Monitor queue depth and auto-shutdown after idle period
4. **For Maximum Speed**: Ensure batch_size=64 and int8 quantization

## Monitoring Performance

Check the transcription logs for performance metrics:
```bash
# GPU setup confirmation
grep "GPU test PASSED" /var/log/gpu-test.log

# Transcription performance
grep "GPU batch processing completed" /var/log/transcription-worker.log

# Check actual speedup
grep "Transcription completed in" /var/log/transcription-worker.log
```