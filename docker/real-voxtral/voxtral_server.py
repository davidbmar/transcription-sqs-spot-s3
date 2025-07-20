#!/usr/bin/env python3
"""
Real Voxtral Server - Mistral's Voxtral-Mini-3B-2507 Voice-to-Text API
WORKING VERSION with dynamic audio token calculation
"""

import os
import sys
import torch
import logging
from datetime import datetime
import tempfile
import traceback
import json
import io
import librosa
import soundfile as sf
from pathlib import Path
import numpy as np

from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = FastAPI(title="Real Voxtral Voice-to-Text API", version="1.0.0")

# Global variables
model = None
processor = None
model_id = "mistralai/Voxtral-Mini-3B-2507"
device = "cuda" if torch.cuda.is_available() else "cpu"

logger.info(f"🔧 DEVICE DETECTION:")
logger.info(f"  - Requested device: cuda")
logger.info(f"  - CUDA available: {torch.cuda.is_available()}")
logger.info(f"  - Selected device: {device}")

def load_voxtral_model():
    """Load the Real Voxtral model"""
    global model, processor
    
    try:
        logger.info(f"🚀 Loading Real Voxtral model: {model_id}")
        start_time = datetime.now()
        
        from transformers import VoxtralForConditionalGeneration, AutoProcessor
        
        # Load processor
        logger.info("Loading processor...")
        processor = AutoProcessor.from_pretrained(model_id)
        
        # Load model with optimal settings for T4 GPU
        logger.info("Loading model...")
        model = VoxtralForConditionalGeneration.from_pretrained(
            model_id,
            torch_dtype=torch.bfloat16 if device == "cuda" else torch.float32,
            device_map=device,
            low_cpu_mem_usage=True
        )
        
        load_time = (datetime.now() - start_time).total_seconds()
        
        # Get model parameters count
        param_count = sum(p.numel() for p in model.parameters())
        param_count_b = param_count / 1e9
        
        logger.info(f"✅ MODEL LOADED: Real Voxtral successfully loaded")
        logger.info(f"  - Load time: {load_time:.2f} seconds")
        logger.info(f"  - Model parameters: {param_count_b:.1f}B")
        logger.info(f"  - Device: {device}")
        logger.info(f"  - Dtype: {model.dtype}")
        
        return True
        
    except Exception as e:
        logger.error(f"❌ MODEL LOADING FAILED: {e}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return False

def prepare_audio(audio_bytes, filename):
    """Prepare audio for Voxtral processing"""
    try:
        # Load audio using librosa
        with tempfile.NamedTemporaryFile(suffix=Path(filename).suffix) as tmp_file:
            tmp_file.write(audio_bytes)
            tmp_file.flush()
            
            # Load and resample to 16kHz (Voxtral requirement)
            audio, sr = librosa.load(tmp_file.name, sr=16000, mono=True)
            
        logger.info(f"📁 Audio prepared: {len(audio)} samples at {sr}Hz")
        return audio, sr
        
    except Exception as e:
        logger.error(f"❌ Audio preparation failed: {e}")
        raise

def calculate_audio_tokens_needed(audio_features):
    """Calculate how many audio tokens are needed based on audio features"""
    # The audio features are processed into embeddings that need token placeholders
    # Based on Voxtral architecture, this is likely related to the time dimension
    batch_size, n_features, time_steps = audio_features.shape
    
    # Empirical calculation based on error analysis:
    # For 30-second audio: time_steps=3000, needed 375 tokens
    # Ratio: 375/3000 = 0.125 or 1/8
    num_audio_tokens = max(1, time_steps // 8)
    
    return num_audio_tokens

@app.get("/")
async def root():
    return {
        "service": "Real Voxtral Voice-to-Text API",
        "model": model_id,
        "status": "ready" if model else "loading",
        "device": device,
        "cuda_available": torch.cuda.is_available(),
        "note": "WORKING VERSION with dynamic audio token calculation",
        "architecture": "Hybrid text-audio model with placeholder tokens",
        "max_audio_length": "~30 seconds per request",
        "version": "dynamic_audio_tokens_v1"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy" if model else "starting",
        "timestamp": datetime.utcnow().isoformat(),
        "gpu_available": torch.cuda.is_available(),
        "device": device,
        "model_loaded": model is not None,
        "processor_loaded": processor is not None,
        "uptime": datetime.utcnow().isoformat(),
        "container_id": os.uname().nodename
    }

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Transcribe audio using Real Voxtral model"""
    if not model or not processor:
        raise HTTPException(status_code=503, detail="Voxtral model not loaded")
    
    try:
        logger.info(f"🎤 Processing transcription request: {file.filename}")
        start_time = datetime.now()
        
        # Read audio file
        audio_bytes = await file.read()
        logger.info(f"📁 Received audio file: {len(audio_bytes)} bytes")
        
        # Prepare audio
        audio, sample_rate = prepare_audio(audio_bytes, file.filename)
        
        # Extract audio features
        logger.info("🔧 Extracting audio features...")
        audio_features = processor.feature_extractor(
            audio, 
            sampling_rate=sample_rate, 
            return_tensors="pt"
        )
        
        # Calculate required number of audio tokens
        num_audio_tokens = calculate_audio_tokens_needed(audio_features.input_features)
        logger.info(f"📊 Audio tokens needed: {num_audio_tokens}")
        
        # Get special token IDs
        vocab = processor.tokenizer.get_vocab()
        bos_token_id = processor.tokenizer.bos_token_id or 1
        eos_token_id = processor.tokenizer.eos_token_id or 2
        audio_token_id = vocab.get('[AUDIO]', 24)
        
        # Create input sequence with dynamic audio tokens
        transcribe_tokens = processor.tokenizer.encode('Transcribe this audio.', add_special_tokens=False)
        
        input_sequence = ([bos_token_id] + 
                         [audio_token_id] * num_audio_tokens + 
                         transcribe_tokens + 
                         [eos_token_id])
        
        input_ids = torch.tensor([input_sequence])
        
        logger.info(f"Input sequence created:")
        logger.info(f"  Total length: {len(input_sequence)}")
        logger.info(f"  Audio tokens: {num_audio_tokens}")
        logger.info(f"  Audio token ID: {audio_token_id}")
        
        # Create inputs
        inputs = {
            "input_features": audio_features.input_features.to(device),
            "input_ids": input_ids.to(device)
        }
        
        # Log input shapes for debugging
        logger.info("Final input shapes:")
        for k, v in inputs.items():
            logger.info(f"  {k}: {v.shape}")
        
        # Generate transcription
        logger.info("🚀 Generating transcription...")
        with torch.no_grad():
            generated_ids = model.generate(
                **inputs,
                max_new_tokens=512,
                do_sample=False,
                temperature=None,
                top_p=None,
            )
        
        # Decode only the new tokens (skip the input prompt)
        input_length = inputs["input_ids"].shape[1]
        new_tokens = generated_ids[:, input_length:]
        
        transcription = processor.tokenizer.decode(
            new_tokens[0], 
            skip_special_tokens=True
        ).strip()
        
        process_time = (datetime.now() - start_time).total_seconds()
        audio_duration = len(audio) / sample_rate
        real_time_factor = audio_duration / process_time if process_time > 0 else 0
        
        logger.info(f"🎉 SUCCESS: Transcription completed successfully!")
        logger.info(f"  - Process time: {process_time:.2f}s")
        logger.info(f"  - Audio duration: {audio_duration:.2f}s")
        logger.info(f"  - Real-time factor: {real_time_factor:.1f}x")
        logger.info(f"  - Transcription: '{transcription}'")
        
        return {
            "filename": file.filename,
            "text": transcription,
            "model": model_id,
            "device": device,
            "processing_time": process_time,
            "audio_duration": audio_duration,
            "real_time_factor": real_time_factor,
            "timestamp": datetime.utcnow().isoformat(),
            "method": "dynamic_audio_tokens_v1",
            "audio_tokens_used": num_audio_tokens,
            "input_sequence_length": len(input_sequence)
        }
        
    except Exception as e:
        logger.error(f"❌ Transcription error: {e}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")

@app.post("/transcribe-batch")
async def transcribe_batch(files: list[UploadFile] = File(...)):
    """Batch transcribe multiple audio files"""
    if not model or not processor:
        raise HTTPException(status_code=503, detail="Voxtral model not loaded")
    
    results = []
    total_start_time = datetime.now()
    
    for file in files:
        try:
            # Process each file individually for now
            # TODO: Implement true batch processing for efficiency
            single_result = await transcribe(file)
            results.append({
                "filename": file.filename,
                "success": True,
                "result": single_result
            })
        except Exception as e:
            results.append({
                "filename": file.filename,
                "success": False,
                "error": str(e)
            })
    
    total_time = (datetime.now() - total_start_time).total_seconds()
    
    return {
        "batch_results": results,
        "total_files": len(files),
        "successful": sum(1 for r in results if r["success"]),
        "failed": sum(1 for r in results if not r["success"]),
        "total_processing_time": total_time,
        "model": model_id,
        "timestamp": datetime.utcnow().isoformat()
    }

# Load model on startup
@app.on_event("startup")
async def startup_event():
    logger.info("🚀 STARTING REAL VOXTRAL SERVER")
    success = load_voxtral_model()
    if not success:
        logger.error("❌ Failed to load Voxtral model on startup")
        # Don't exit - let the container stay alive for debugging

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)