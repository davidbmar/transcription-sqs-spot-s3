# Binary Dependencies

This directory contains instructions for large binary files needed for GPU acceleration.

## cuDNN Installation

To enable optimal GPU acceleration, upload cuDNN 8.9.7 for CUDA 12 to S3:

1. **Download from NVIDIA**: https://developer.nvidia.com/cudnn
   - File: `cudnn-linux-x86_64-8.9.7.29_cuda12-archive.tar.xz`
   - Requires free NVIDIA Developer account
   - Platform: Linux x86_64
   - CUDA: 12.x
   - cuDNN: 8.9.7

2. **Upload to S3**:
   ```bash
   aws s3 cp cudnn-linux-x86_64-8.9.7.29_cuda12-archive.tar.xz s3://dbm-cf-2-web/bintarball/
   ```

3. **Launch workers**: The script will automatically download and install from S3

## Fallback

If cuDNN 8.x is not available in S3, workers will use PyTorch 2.1.0 compatibility mode with DLAMI's cuDNN 9.x (slower but functional).