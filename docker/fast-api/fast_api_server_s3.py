#!/usr/bin/env python3
"""
Fast API Server with S3 Support - Real-time Voice-to-Text Transcription API
Enhanced version that supports S3 input/output in addition to file uploads
"""

import os
import torch
import boto3
import json
from fastapi import FastAPI, File, UploadFile, HTTPException, Body
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import uvicorn
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline
import logging
from datetime import datetime
import tempfile
from typing import Optional
from urllib.parse import urlparse

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Fast Real-time Transcription API with S3 Support")

# Request models
class S3TranscriptionRequest(BaseModel):
    s3_input_path: str
    s3_output_path: Optional[str] = None
    return_text: bool = True  # If True, returns text in response. If False, only saves to S3

# Global variables for model
model_id = "openai/whisper-base"
device = "cuda" if torch.cuda.is_available() else "cpu"
torch_dtype = torch.float16 if torch.cuda.is_available() else torch.float32

# Initialize S3 client
s3_client = boto3.client('s3')

logger.info(f"Using device: {device}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")

# Load model
try:
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

def parse_s3_path(s3_path):
    """Parse S3 path into bucket and key"""
    if not s3_path.startswith('s3://'):
        raise ValueError("S3 path must start with s3://")
    
    path = s3_path[5:]  # Remove 's3://'
    parts = path.split('/', 1)
    if len(parts) != 2:
        raise ValueError("Invalid S3 path format")
    
    return parts[0], parts[1]

def download_from_s3(s3_path, local_path):
    """Download file from S3"""
    bucket, key = parse_s3_path(s3_path)
    logger.info(f"Downloading from S3: {bucket}/{key}")
    s3_client.download_file(bucket, key, local_path)

def upload_to_s3(local_path, s3_path, content_type='application/json'):
    """Upload file to S3"""
    bucket, key = parse_s3_path(s3_path)
    logger.info(f"Uploading to S3: {bucket}/{key}")
    s3_client.upload_file(local_path, bucket, key, 
                         ExtraArgs={'ContentType': content_type})

@app.get("/")
async def root():
    return {
        "service": "Fast API Voice-to-Text with S3 Support",
        "status": "ready" if pipe else "model_loading_failed",
        "device": device,
        "model": model_id,
        "features": ["file_upload", "s3_input", "s3_output"],
        "description": "Real-time transcription API with S3 integration"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy" if pipe else "unhealthy",
        "timestamp": datetime.utcnow().isoformat(),
        "gpu_available": torch.cuda.is_available(),
        "device": device,
        "s3_enabled": True
    }

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Transcribe an uploaded audio file"""
    if not pipe:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    # Save uploaded file temporarily
    with tempfile.NamedTemporaryFile(delete=False, suffix=file.filename) as tmp_file:
        content = await file.read()
        tmp_file.write(content)
        tmp_file_path = tmp_file.name
    
    try:
        logger.info(f"Processing uploaded file: {file.filename}")
        
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

@app.post("/transcribe-s3")
async def transcribe_s3(request: S3TranscriptionRequest):
    """Transcribe audio from S3 and optionally save result to S3"""
    if not pipe:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    # Create temporary files
    with tempfile.NamedTemporaryFile(delete=False, suffix='.mp3') as tmp_audio:
        tmp_audio_path = tmp_audio.name
    
    try:
        # Download audio from S3
        download_from_s3(request.s3_input_path, tmp_audio_path)
        
        logger.info(f"Processing S3 file: {request.s3_input_path}")
        
        # Run transcription
        result = pipe(tmp_audio_path)
        
        # Prepare response
        response_data = {
            "s3_input_path": request.s3_input_path,
            "text": result["text"],
            "chunks": result.get("chunks", []),
            "device": device,
            "model": model_id,
            "timestamp": datetime.utcnow().isoformat()
        }
        
        # Save to S3 if output path provided
        if request.s3_output_path:
            with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json') as tmp_result:
                json.dump(response_data, tmp_result, indent=2)
                tmp_result_path = tmp_result.name
            
            upload_to_s3(tmp_result_path, request.s3_output_path)
            os.unlink(tmp_result_path)
            
            response_data["s3_output_path"] = request.s3_output_path
            
            # If user doesn't want text in response, just return status
            if not request.return_text:
                return {
                    "status": "success",
                    "s3_input_path": request.s3_input_path,
                    "s3_output_path": request.s3_output_path,
                    "timestamp": datetime.utcnow().isoformat()
                }
        
        # Clean up
        os.unlink(tmp_audio_path)
        
        return response_data
        
    except Exception as e:
        logger.error(f"S3 transcription error: {e}")
        if os.path.exists(tmp_audio_path):
            os.unlink(tmp_audio_path)
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/transcribe-url")
async def transcribe_url(audio_url: str = Body(..., embed=True)):
    """Transcribe audio from any URL (including S3 presigned URLs)"""
    if not pipe:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    import requests
    
    with tempfile.NamedTemporaryFile(delete=False, suffix='.mp3') as tmp_file:
        tmp_file_path = tmp_file.name
    
    try:
        # Download audio from URL
        logger.info(f"Downloading from URL: {audio_url}")
        response = requests.get(audio_url, stream=True)
        response.raise_for_status()
        
        with open(tmp_file_path, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
        
        # Run transcription
        result = pipe(tmp_file_path)
        
        # Clean up
        os.unlink(tmp_file_path)
        
        return {
            "source_url": audio_url,
            "text": result["text"],
            "chunks": result.get("chunks", []),
            "device": device,
            "model": model_id
        }
        
    except Exception as e:
        logger.error(f"URL transcription error: {e}")
        if os.path.exists(tmp_file_path):
            os.unlink(tmp_file_path)
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import threading
    from http.server import HTTPServer, BaseHTTPRequestHandler
    
    # Health check server on port 8080
    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/health':
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                health_status = {
                    "status": "healthy" if pipe else "unhealthy",
                    "timestamp": datetime.utcnow().isoformat(),
                    "gpu_available": torch.cuda.is_available(),
                    "device": device,
                    "model_loaded": pipe is not None,
                    "s3_enabled": True,
                    "container_id": os.environ.get('HOSTNAME', 'unknown')
                }
                self.wfile.write(json.dumps(health_status).encode())
            else:
                self.send_response(404)
                self.end_headers()
        
        def log_message(self, format, *args):
            pass
    
    # Start health check server
    def run_health_server():
        health_server = HTTPServer(('0.0.0.0', 8080), HealthHandler)
        health_server.serve_forever()
    
    health_thread = threading.Thread(target=run_health_server, daemon=True)
    health_thread.start()
    logger.info("Health check server started on port 8080")
    
    # Start main API server
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)