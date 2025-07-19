#!/usr/bin/env python3
"""
Voxtral Server v2 - Voice-to-Text with S3 support
"""

import os
import torch
import boto3
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import uvicorn
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline
import logging
from datetime import datetime
import tempfile
from urllib.parse import urlparse

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Voxtral Voice-to-Text API v2", description="Voice transcription with S3 support")

# Pydantic models for requests
class S3TranscribeRequest(BaseModel):
    s3_uri: str
    output_s3_uri: str = None

class URLTranscribeRequest(BaseModel):
    audio_url: str

# Global variables for model
model_id = "mistralai/Mistral-Small-Instruct-2409"  # Will update when Voxtral is released
device = "cuda" if torch.cuda.is_available() else "cpu"
torch_dtype = torch.float16 if torch.cuda.is_available() else torch.float32

logger.info(f"Using device: {device}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")

# Initialize S3 client
try:
    s3_client = boto3.client('s3')
    logger.info("S3 client initialized successfully")
except Exception as e:
    logger.error(f"Failed to initialize S3 client: {e}")
    s3_client = None

# For now, use Whisper as a placeholder until Voxtral is released
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

def parse_s3_uri(s3_uri):
    """Parse S3 URI into bucket and key"""
    parsed = urlparse(s3_uri)
    if parsed.scheme != 's3':
        raise ValueError("URI must start with s3://")
    bucket = parsed.netloc
    key = parsed.path.lstrip('/')
    return bucket, key

async def download_from_s3(s3_uri):
    """Download file from S3 to local temp file"""
    if not s3_client:
        raise HTTPException(status_code=503, detail="S3 client not available")
    
    try:
        bucket, key = parse_s3_uri(s3_uri)
        
        # Create temp file
        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(key)[1])
        
        # Download from S3
        logger.info(f"Downloading s3://{bucket}/{key}")
        s3_client.download_file(bucket, key, temp_file.name)
        
        return temp_file.name
    except Exception as e:
        logger.error(f"Failed to download from S3: {e}")
        raise HTTPException(status_code=400, detail=f"S3 download failed: {str(e)}")

async def upload_to_s3(local_file, s3_uri):
    """Upload file to S3"""
    if not s3_client:
        raise HTTPException(status_code=503, detail="S3 client not available")
    
    try:
        bucket, key = parse_s3_uri(s3_uri)
        
        logger.info(f"Uploading to s3://{bucket}/{key}")
        s3_client.upload_file(local_file, bucket, key)
        
        return s3_uri
    except Exception as e:
        logger.error(f"Failed to upload to S3: {e}")
        raise HTTPException(status_code=500, detail=f"S3 upload failed: {str(e)}")

def transcribe_audio(audio_path):
    """Core transcription function"""
    if not pipe:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    try:
        logger.info(f"Starting transcription of: {audio_path}")
        start_time = datetime.utcnow()
        
        result = pipe(audio_path)
        
        end_time = datetime.utcnow()
        processing_time = (end_time - start_time).total_seconds()
        
        logger.info(f"Transcription completed in {processing_time:.2f} seconds")
        
        return {
            "text": result["text"],
            "chunks": result.get("chunks", []),
            "device": device,
            "model": model_id,
            "processing_time_seconds": processing_time,
            "timestamp": end_time.isoformat()
        }
        
    except Exception as e:
        logger.error(f"Transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/")
async def root():
    return {
        "service": "Voxtral Voice-to-Text API v2",
        "status": "ready" if pipe else "model_loading_failed",
        "device": device,
        "model": model_id,
        "features": ["file_upload", "s3_input", "s3_output", "url_input"],
        "note": "Currently using Whisper as placeholder for Voxtral"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy" if pipe else "unhealthy",
        "timestamp": datetime.utcnow().isoformat(),
        "gpu_available": torch.cuda.is_available(),
        "device": device,
        "s3_available": s3_client is not None
    }

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Transcribe an uploaded audio file to text"""
    # Save uploaded file temporarily
    with tempfile.NamedTemporaryFile(delete=False, suffix=file.filename) as tmp_file:
        content = await file.read()
        tmp_file.write(content)
        tmp_file_path = tmp_file.name
    
    try:
        result = transcribe_audio(tmp_file_path)
        result["filename"] = file.filename
        return result
        
    finally:
        # Clean up
        if os.path.exists(tmp_file_path):
            os.unlink(tmp_file_path)

@app.post("/transcribe-s3")
async def transcribe_s3(request: S3TranscribeRequest):
    """Transcribe audio file from S3"""
    # Download from S3
    local_file = await download_from_s3(request.s3_uri)
    
    try:
        result = transcribe_audio(local_file)
        result["s3_input_uri"] = request.s3_uri
        
        # If output S3 URI provided, save transcript there
        if request.output_s3_uri:
            import json
            transcript_file = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
            json.dump(result, transcript_file, indent=2)
            transcript_file.close()
            
            await upload_to_s3(transcript_file.name, request.output_s3_uri)
            result["s3_output_uri"] = request.output_s3_uri
            
            # Clean up transcript file
            os.unlink(transcript_file.name)
        
        return result
        
    finally:
        # Clean up audio file
        if os.path.exists(local_file):
            os.unlink(local_file)

@app.post("/transcribe-url")
async def transcribe_url(request: URLTranscribeRequest):
    """Transcribe audio file from URL"""
    import requests
    
    try:
        # Download from URL
        logger.info(f"Downloading from URL: {request.audio_url}")
        response = requests.get(request.audio_url, stream=True)
        response.raise_for_status()
        
        # Save to temp file
        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp3')
        for chunk in response.iter_content(chunk_size=8192):
            temp_file.write(chunk)
        temp_file.close()
        
        result = transcribe_audio(temp_file.name)
        result["source_url"] = request.audio_url
        
        return result
        
    except Exception as e:
        logger.error(f"URL download error: {e}")
        raise HTTPException(status_code=400, detail=f"Failed to download from URL: {str(e)}")
    finally:
        # Clean up
        if 'temp_file' in locals() and os.path.exists(temp_file.name):
            os.unlink(temp_file.name)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)