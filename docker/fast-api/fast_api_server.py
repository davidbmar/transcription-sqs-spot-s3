#!/usr/bin/env python3
"""
Fast API Server - Real-time Voice-to-Text Transcription API
"""

import os
import torch
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline
import logging
from datetime import datetime
import tempfile

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Fast Real-time Transcription API")

# Global variables for model
model_id = "openai/whisper-base"  # Currently using Whisper for real-time transcription
device = "cuda" if torch.cuda.is_available() else "cpu"
torch_dtype = torch.float16 if torch.cuda.is_available() else torch.float32

logger.info(f"Using device: {device}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")

# For now, use Whisper as a placeholder until Voxtral is released
# This will be replaced with actual Voxtral model
try:
    model_id = "openai/whisper-base"
    
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_id, 
        torch_dtype=torch_dtype, 
        low_cpu_mem_usage=True, 
        use_safetensors=True
    )
    model.to(device)
    
    processor = AutoProcessor.from_pretrained(model_id)
    
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model,
        tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor,
        max_new_tokens=128,
        chunk_length_s=30,
        batch_size=16,
        return_timestamps=True,
        torch_dtype=torch_dtype,
        device=device,
    )
    
    logger.info("Model loaded successfully")
except Exception as e:
    logger.error(f"Failed to load model: {e}")
    pipe = None

@app.get("/")
async def root():
    return {
        "service": "Voxtral Voice-to-Text API",
        "status": "ready" if pipe else "model_loading_failed",
        "device": device,
        "model": model_id,
        "note": "Currently using Whisper as placeholder for Voxtral"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy" if pipe else "unhealthy",
        "timestamp": datetime.utcnow().isoformat(),
        "gpu_available": torch.cuda.is_available(),
        "device": device
    }

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Transcribe an audio file to text"""
    if not pipe:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    # Save uploaded file temporarily
    with tempfile.NamedTemporaryFile(delete=False, suffix=file.filename) as tmp_file:
        content = await file.read()
        tmp_file.write(content)
        tmp_file_path = tmp_file.name
    
    try:
        logger.info(f"Processing file: {file.filename}")
        
        # Run transcription
        result = pipe(tmp_file_path)
        
        # Clean up
        os.unlink(tmp_file_path)
        
        return {
            "filename": file.filename,
            "text": result["text"],
            "chunks": result.get("chunks", []),
            "device": device,
            "model": model_id
        }
        
    except Exception as e:
        logger.error(f"Transcription error: {e}")
        if os.path.exists(tmp_file_path):
            os.unlink(tmp_file_path)
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)