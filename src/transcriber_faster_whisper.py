#!/usr/bin/env python3
"""
FasterWhisper Transcriber - High-performance implementation using faster-whisper
"""

import os
import time
import logging
import torch
from datetime import datetime
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

class FasterWhisperTranscriber:
    """
    FasterWhisper implementation for maximum GPU performance
    Uses CTranslate2 for optimized inference
    """
    
    def __init__(self, 
                 model_name: str = "large-v3",
                 device: str = "cuda",
                 compute_type: str = "float16",
                 beam_size: int = 5,
                 s3_bucket: Optional[str] = None,
                 region: str = "us-east-1"):
        """
        Initialize FasterWhisper transcriber
        
        Args:
            model_name: Whisper model size (tiny, base, small, medium, large-v1, large-v2, large-v3)
            device: Device to use (cuda, cpu)
            compute_type: Compute precision (float16, int8_float16, int8)
            beam_size: Beam search size (1-10, higher = better quality but slower)
            s3_bucket: S3 bucket for metrics
            region: AWS region
        """
        self.model_name = model_name
        self.device = device
        self.compute_type = compute_type
        self.beam_size = beam_size
        self.s3_bucket = s3_bucket
        self.region = region
        self.model = None
        
        # Performance optimizations
        if device == "cuda":
            # Enable optimizations for GPU
            torch.backends.cudnn.benchmark = True
            torch.backends.cuda.matmul.allow_tf32 = True
            
            # Set optimal memory settings
            os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "max_split_size_mb:512"
        
        logger.info(f"🚀 FasterWhisper Transcriber initialized:")
        logger.info(f"  Model: {model_name}")
        logger.info(f"  Device: {device}")
        logger.info(f"  Compute Type: {compute_type}")
        logger.info(f"  Beam Size: {beam_size}")
    
    def load_model(self):
        """Load the FasterWhisper model"""
        if self.model is not None:
            logger.info("Model already loaded")
            return
        
        try:
            from faster_whisper import WhisperModel
            
            logger.info(f"Loading FasterWhisper model: {self.model_name}")
            start_time = time.time()
            
            # Load model with optimizations
            self.model = WhisperModel(
                self.model_name,
                device=self.device,
                compute_type=self.compute_type,
                download_root=None,  # Use default cache
                local_files_only=False
            )
            
            load_time = time.time() - start_time
            logger.info(f"✅ FasterWhisper model loaded in {load_time:.2f} seconds")
            
        except ImportError:
            logger.error("faster-whisper not installed. Install with: pip install faster-whisper")
            raise
        except Exception as e:
            logger.error(f"Failed to load FasterWhisper model: {e}")
            raise
    
    def transcribe_audio(self, audio_path: str, job_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Transcribe audio file using FasterWhisper
        
        Args:
            audio_path: Path to audio file
            job_id: Optional job ID for logging
            
        Returns:
            Dictionary containing transcription results
        """
        if self.model is None:
            self.load_model()
        
        logger.info(f"🎙️ Starting FasterWhisper transcription: {os.path.basename(audio_path)}")
        start_time = time.time()
        
        try:
            # Transcribe with FasterWhisper
            segments, info = self.model.transcribe(
                audio_path,
                beam_size=self.beam_size,
                language=None,  # Auto-detect
                task="transcribe",
                vad_filter=True,  # Voice Activity Detection
                vad_parameters=dict(
                    min_silence_duration_ms=500,
                    threshold=0.5,
                    min_speech_duration_ms=250,
                    max_speech_duration_s=float('inf')
                ),
                word_timestamps=True,  # Enable word-level timestamps
                condition_on_previous_text=True,
                compression_ratio_threshold=2.4,
                log_prob_threshold=-1.0,
                no_speech_threshold=0.6,
                initial_prompt=None
            )
            
            # Convert segments to list (generator to list)
            segments_list = []
            for segment in segments:
                segment_dict = {
                    "id": segment.id,
                    "seek": segment.seek,
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text.strip(),
                    "tokens": segment.tokens,
                    "temperature": segment.temperature,
                    "avg_logprob": segment.avg_logprob,
                    "compression_ratio": segment.compression_ratio,
                    "no_speech_prob": segment.no_speech_prob
                }
                
                # Add word-level timestamps if available
                if hasattr(segment, 'words') and segment.words:
                    segment_dict["words"] = [
                        {
                            "start": word.start,
                            "end": word.end,
                            "word": word.word,
                            "probability": word.probability
                        }
                        for word in segment.words
                    ]
                
                segments_list.append(segment_dict)
            
            transcription_time = time.time() - start_time
            
            # Create result structure
            result = {
                "text": " ".join([segment["text"] for segment in segments_list]),
                "segments": segments_list,
                "language": info.language if hasattr(info, 'language') else "unknown",
                "language_probability": info.language_probability if hasattr(info, 'language_probability') else 0.0,
                "duration": info.duration if hasattr(info, 'duration') else 0.0,
                "transcriber": "faster-whisper",
                "model": self.model_name,
                "compute_type": self.compute_type,
                "beam_size": self.beam_size,
                "processing_time": transcription_time,
                "vad_enabled": True,
                "word_timestamps": True
            }
            
            logger.info(f"✅ FasterWhisper transcription completed:")
            logger.info(f"  Duration: {transcription_time:.2f} seconds")
            logger.info(f"  Segments: {len(segments_list)}")
            logger.info(f"  Language: {result['language']} ({result['language_probability']:.2f})")
            logger.info(f"  Audio Length: {result['duration']:.1f} seconds")
            logger.info(f"  Real-time Factor: {result['duration']/transcription_time:.2f}x")
            
            return result
            
        except Exception as e:
            logger.error(f"FasterWhisper transcription failed: {e}")
            raise
    
    def get_model_info(self) -> Dict[str, Any]:
        """Get information about the loaded model"""
        return {
            "transcriber": "faster-whisper",
            "model_name": self.model_name,
            "device": self.device,
            "compute_type": self.compute_type,
            "beam_size": self.beam_size,
            "model_loaded": self.model is not None,
            "supports_gpu": torch.cuda.is_available() if self.device == "cuda" else False,
            "gpu_memory_gb": torch.cuda.get_device_properties(0).total_memory / 1e9 if torch.cuda.is_available() else 0
        }
    
    def cleanup(self):
        """Clean up model and free GPU memory"""
        if self.model is not None:
            del self.model
            self.model = None
            
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            
        logger.info("FasterWhisper model cleaned up")