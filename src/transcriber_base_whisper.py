#!/usr/bin/env python3
"""
Base Whisper Transcriber - Standard OpenAI Whisper implementation
"""

import os
import time
import logging
import torch
from datetime import datetime
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

class BaseWhisperTranscriber:
    """
    Standard OpenAI Whisper implementation
    Simple, reliable, well-tested baseline
    """
    
    def __init__(self, 
                 model_name: str = "large-v3",
                 device: str = "cuda",
                 s3_bucket: Optional[str] = None,
                 region: str = "us-east-1"):
        """
        Initialize Base Whisper transcriber
        
        Args:
            model_name: Whisper model size (tiny, base, small, medium, large, large-v2, large-v3)
            device: Device to use (cuda, cpu)
            s3_bucket: S3 bucket for metrics
            region: AWS region
        """
        self.model_name = model_name
        self.device = device
        self.s3_bucket = s3_bucket
        self.region = region
        self.model = None
        
        # Basic optimizations
        if device == "cuda" and torch.cuda.is_available():
            torch.backends.cudnn.benchmark = True
        
        logger.info(f"📚 Base Whisper Transcriber initialized:")
        logger.info(f"  Model: {model_name}")
        logger.info(f"  Device: {device}")
    
    def load_model(self):
        """Load the base Whisper model"""
        if self.model is not None:
            logger.info("Base Whisper model already loaded")
            return
        
        try:
            import whisper
            
            logger.info(f"Loading Base Whisper model: {self.model_name}")
            start_time = time.time()
            
            # Load model
            self.model = whisper.load_model(
                self.model_name,
                device=self.device,
                download_root=None  # Use default cache
            )
            
            load_time = time.time() - start_time
            logger.info(f"✅ Base Whisper model loaded in {load_time:.2f} seconds")
            
        except ImportError:
            logger.error("openai-whisper not installed. Install with: pip install openai-whisper")
            raise
        except Exception as e:
            logger.error(f"Failed to load Base Whisper model: {e}")
            raise
    
    def transcribe_audio(self, audio_path: str, job_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Transcribe audio file using base Whisper
        
        Args:
            audio_path: Path to audio file
            job_id: Optional job ID for logging
            
        Returns:
            Dictionary containing transcription results
        """
        if self.model is None:
            self.load_model()
        
        logger.info(f"📚 Starting Base Whisper transcription: {os.path.basename(audio_path)}")
        start_time = time.time()
        
        try:
            # Transcribe with base Whisper
            result = self.model.transcribe(
                audio_path,
                language=None,  # Auto-detect
                task="transcribe",
                verbose=False,
                word_timestamps=True,  # Enable word-level timestamps
                condition_on_previous_text=True,
                temperature=0.0,  # Deterministic output
                compression_ratio_threshold=2.4,
                logprob_threshold=-1.0,
                no_speech_threshold=0.6
            )
            
            transcription_time = time.time() - start_time
            
            # Process segments to match other transcriber formats
            processed_segments = []
            for i, segment in enumerate(result["segments"]):
                segment_dict = {
                    "id": i,
                    "seek": segment.get("seek", 0),
                    "start": segment["start"],
                    "end": segment["end"],
                    "text": segment["text"].strip(),
                    "tokens": segment.get("tokens", []),
                    "temperature": segment.get("temperature", 0.0),
                    "avg_logprob": segment.get("avg_logprob", 0.0),
                    "compression_ratio": segment.get("compression_ratio", 0.0),
                    "no_speech_prob": segment.get("no_speech_prob", 0.0)
                }
                
                # Add word-level timestamps if available
                if "words" in segment and segment["words"]:
                    segment_dict["words"] = [
                        {
                            "start": word["start"],
                            "end": word["end"],
                            "word": word["word"],
                            "probability": word.get("probability", 1.0)
                        }
                        for word in segment["words"]
                    ]
                
                processed_segments.append(segment_dict)
            
            # Calculate audio duration from the last segment
            audio_duration = processed_segments[-1]["end"] if processed_segments else 0.0
            
            # Create result structure
            final_result = {
                "text": result["text"],
                "segments": processed_segments,
                "language": result["language"],
                "language_probability": result.get("language_probability", 0.0),
                "duration": audio_duration,
                "transcriber": "base-whisper",
                "model": self.model_name,
                "processing_time": transcription_time,
                "word_timestamps": True,
                "temperature": 0.0,
                "condition_on_previous_text": True
            }
            
            logger.info(f"✅ Base Whisper transcription completed:")
            logger.info(f"  Duration: {transcription_time:.2f} seconds")
            logger.info(f"  Segments: {len(processed_segments)}")
            logger.info(f"  Language: {result['language']} ({result.get('language_probability', 0.0):.2f})")
            logger.info(f"  Audio Length: {audio_duration:.1f} seconds")
            logger.info(f"  Real-time Factor: {audio_duration/transcription_time:.2f}x")
            
            return final_result
            
        except Exception as e:
            logger.error(f"Base Whisper transcription failed: {e}")
            raise
    
    def get_model_info(self) -> Dict[str, Any]:
        """Get information about the loaded model"""
        return {
            "transcriber": "base-whisper",
            "model_name": self.model_name,
            "device": self.device,
            "model_loaded": self.model is not None,
            "supports_gpu": torch.cuda.is_available() if self.device == "cuda" else False,
            "gpu_memory_gb": torch.cuda.get_device_properties(0).total_memory / 1e9 if torch.cuda.is_available() else 0,
            "version": "openai-whisper"
        }
    
    def cleanup(self):
        """Clean up model and free GPU memory"""
        if self.model is not None:
            del self.model
            self.model = None
            
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            
        logger.info("Base Whisper model cleaned up")