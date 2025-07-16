#!/usr/bin/env python3
"""
Patch WhisperX VAD to use our S3 URL as fallback
This modifies the installed whisperx package to use our reliable S3 URL
"""

import os
import re

def patch_whisperx_vad():
    """Patch the whisperx vad.py file to use our S3 URL"""
    
    vad_file = "/venv/lib/python3.10/site-packages/whisperx/vad.py"
    
    if not os.path.exists(vad_file):
        print(f"❌ WhisperX VAD file not found at {vad_file}")
        return False
    
    try:
        # Read the current file
        with open(vad_file, 'r') as f:
            content = f.read()
        
        # Update the URL to use our S3 bucket
        new_url = "https://s3.amazonaws.com/dbm-cf-2-web/bintarball/whisperx-vad-segmentation.bin"
        
        # Replace the URL
        content = re.sub(
            r'VAD_SEGMENTATION_URL = "https://whisperx\.s3\.[^"]*"',
            f'VAD_SEGMENTATION_URL = "{new_url}"',
            content
        )
        
        # Write back the modified content
        with open(vad_file, 'w') as f:
            f.write(content)
        
        print(f"✅ WhisperX VAD patched to use S3 URL: {new_url}")
        return True
        
    except Exception as e:
        print(f"❌ Failed to patch WhisperX VAD: {e}")
        return False

if __name__ == "__main__":
    success = patch_whisperx_vad()
    exit(0 if success else 1)