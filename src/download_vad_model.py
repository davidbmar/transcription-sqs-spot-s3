#!/usr/bin/env python3
"""
Download VAD model from S3 fallback if not available locally
This ensures the transcription worker can function even if the Docker build failed to download the model
"""

import os
import boto3
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

def download_vad_model_from_s3():
    """Download VAD model from S3 if not already present"""
    
    # Check if model already exists
    model_path = Path("/cache/torch/whisperx-vad-segmentation.bin")
    if model_path.exists() and model_path.stat().st_size > 10000000:  # > 10MB
        logger.info("✅ VAD model already exists locally")
        return True
    
    try:
        # Get bucket from environment
        metrics_bucket = os.environ.get('METRICS_BUCKET')
        if not metrics_bucket:
            logger.warning("⚠️ METRICS_BUCKET not set, cannot download VAD model")
            return False
        
        logger.info("📥 Downloading VAD model from S3...")
        
        # Ensure directory exists
        model_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Download from S3
        s3 = boto3.client('s3')
        s3.download_file(
            metrics_bucket,
            'models/whisperx-vad-segmentation.bin',
            str(model_path)
        )
        
        # Verify download
        if model_path.exists() and model_path.stat().st_size > 10000000:
            logger.info("✅ VAD model downloaded successfully from S3")
            return True
        else:
            logger.error("❌ VAD model download verification failed")
            return False
            
    except Exception as e:
        logger.error(f"❌ Failed to download VAD model from S3: {e}")
        return False

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    success = download_vad_model_from_s3()
    exit(0 if success else 1)