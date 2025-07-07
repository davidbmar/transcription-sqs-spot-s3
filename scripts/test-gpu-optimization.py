#!/usr/bin/env python3
"""
Test GPU Optimization Performance
Compare standard vs optimized GPU transcription
"""

import sys
import os
import time
import torch
import logging

# Add src directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from transcriber import Transcriber
from transcriber_gpu_optimized import GPUOptimizedTranscriber

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def test_transcriber(transcriber_class, name, test_file):
    """Test a transcriber implementation"""
    logger.info(f"\n{'='*60}")
    logger.info(f"Testing {name}")
    logger.info(f"{'='*60}")
    
    try:
        # Initialize transcriber
        transcriber = transcriber_class(
            model_name="large-v3",
            device="cuda",
            batch_size=32 if transcriber_class == Transcriber else 64
        )
        
        # Warm up - load model
        logger.info("Loading model...")
        transcriber.load_model()
        
        # Time the transcription
        logger.info(f"Transcribing {test_file}...")
        start_time = time.time()
        
        result = transcriber.transcribe_audio(test_file)
        
        elapsed_time = time.time() - start_time
        
        # Calculate metrics
        num_segments = len(result.get('segments', []))
        
        logger.info(f"\n✅ {name} Results:")
        logger.info(f"  - Transcription time: {elapsed_time:.2f} seconds")
        logger.info(f"  - Segments generated: {num_segments}")
        logger.info(f"  - Time per segment: {elapsed_time/num_segments:.3f} seconds")
        
        return {
            'name': name,
            'time': elapsed_time,
            'segments': num_segments,
            'time_per_segment': elapsed_time/num_segments if num_segments > 0 else 0
        }
        
    except Exception as e:
        logger.error(f"Error testing {name}: {e}")
        return None

def main():
    """Main test function"""
    logger.info("🔬 GPU OPTIMIZATION PERFORMANCE TEST")
    logger.info(f"PyTorch version: {torch.__version__}")
    logger.info(f"CUDA available: {torch.cuda.is_available()}")
    
    if torch.cuda.is_available():
        logger.info(f"GPU: {torch.cuda.get_device_name(0)}")
        logger.info(f"GPU Memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
    else:
        logger.error("❌ CUDA not available! This test requires a GPU.")
        return
    
    # Test file (you'll need to provide a test audio file)
    test_file = "./test_audio.wav"
    
    if not os.path.exists(test_file):
        logger.error(f"Test file not found: {test_file}")
        logger.info("Please provide a test audio file (WAV format preferred)")
        return
    
    # Test both implementations
    results = []
    
    # Test standard transcriber
    standard_result = test_transcriber(Transcriber, "Standard GPU Transcriber", test_file)
    if standard_result:
        results.append(standard_result)
    
    # Test optimized transcriber
    optimized_result = test_transcriber(GPUOptimizedTranscriber, "GPU-Optimized Transcriber", test_file)
    if optimized_result:
        results.append(optimized_result)
    
    # Compare results
    if len(results) == 2:
        logger.info(f"\n{'='*60}")
        logger.info("📊 PERFORMANCE COMPARISON")
        logger.info(f"{'='*60}")
        
        standard = results[0]
        optimized = results[1]
        
        speedup = standard['time'] / optimized['time'] if optimized['time'] > 0 else 0
        
        logger.info(f"Standard GPU time: {standard['time']:.2f} seconds")
        logger.info(f"Optimized GPU time: {optimized['time']:.2f} seconds")
        logger.info(f"🚀 Optimization Speedup: {speedup:.2f}x")
        
        logger.info(f"\nPer-segment performance:")
        logger.info(f"Standard: {standard['time_per_segment']:.3f} seconds/segment")
        logger.info(f"Optimized: {optimized['time_per_segment']:.3f} seconds/segment")
        
        if speedup > 1:
            logger.info(f"\n✅ GPU optimization improved performance by {(speedup-1)*100:.1f}%!")
        else:
            logger.info(f"\n⚠️ GPU optimization did not improve performance")

if __name__ == "__main__":
    main()