#!/usr/bin/env python3
"""
WhisperX Transcriber - Advanced implementation with speaker diarization and alignment
"""

import os
import time
import logging
import torch
from datetime import datetime
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

class WhisperXTranscriber:
    """
    WhisperX implementation with advanced features:
    - Speaker diarization
    - Word-level alignment
    - VAD filtering
    - Batch processing
    """
    
    def __init__(self, 
                 model_name: str = "large-v3",
                 device: str = "cuda",
                 compute_type: str = "float16",
                 batch_size: int = 16,
                 enable_diarization: bool = False,
                 hf_token: Optional[str] = None,
                 s3_bucket: Optional[str] = None,
                 region: str = "us-east-1"):
        """
        Initialize WhisperX transcriber
        
        Args:
            model_name: Whisper model size
            device: Device to use (cuda, cpu)
            compute_type: Compute precision (float16, int8)
            batch_size: Batch size for processing
            enable_diarization: Enable speaker diarization
            hf_token: HuggingFace token for diarization models
            s3_bucket: S3 bucket for metrics
            region: AWS region
        """
        self.model_name = model_name
        self.device = device
        self.compute_type = compute_type
        self.batch_size = batch_size
        self.enable_diarization = enable_diarization
        self.hf_token = hf_token
        self.s3_bucket = s3_bucket
        self.region = region
        
        self.model = None
        self.align_model = None
        self.align_metadata = None
        self.diarize_model = None
        
        # Performance optimizations
        if device == "cuda":
            torch.backends.cudnn.benchmark = True
            torch.backends.cuda.matmul.allow_tf32 = True
            os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "max_split_size_mb:512"
        
        logger.info(f"🎯 WhisperX Transcriber initialized:")
        logger.info(f"  Model: {model_name}")
        logger.info(f"  Device: {device}")
        logger.info(f"  Compute Type: {compute_type}")
        logger.info(f"  Batch Size: {batch_size}")
        logger.info(f"  Diarization: {enable_diarization}")
    
    def load_model(self):
        """Load the WhisperX model and alignment models"""
        if self.model is not None:
            logger.info("WhisperX model already loaded")
            return
        
        try:
            import whisperx
            
            logger.info(f"Loading WhisperX model: {self.model_name}")
            start_time = time.time()
            
            # Load main whisper model
            self.model = whisperx.load_model(
                self.model_name,
                self.device,
                compute_type=self.compute_type,
                language=None  # Auto-detect
            )
            
            model_load_time = time.time() - start_time
            logger.info(f"✅ WhisperX model loaded in {model_load_time:.2f} seconds")
            
            # Load alignment model (for word-level timestamps)
            logger.info("Loading alignment model...")
            align_start = time.time()
            
            self.align_model, self.align_metadata = whisperx.load_align_model(
                language_code="en",  # Will be updated based on detected language
                device=self.device
            )
            
            align_load_time = time.time() - align_start
            logger.info(f"✅ Alignment model loaded in {align_load_time:.2f} seconds")
            
            # Load diarization model if enabled
            if self.enable_diarization:
                if not self.hf_token:
                    logger.warning("Diarization enabled but no HuggingFace token provided")
                else:
                    logger.info("Loading diarization model...")
                    diarize_start = time.time()
                    
                    self.diarize_model = whisperx.DiarizationPipeline(
                        use_auth_token=self.hf_token,
                        device=self.device
                    )
                    
                    diarize_load_time = time.time() - diarize_start
                    logger.info(f"✅ Diarization model loaded in {diarize_load_time:.2f} seconds")
            
            total_load_time = time.time() - start_time
            logger.info(f"🚀 Total WhisperX setup time: {total_load_time:.2f} seconds")
            
        except ImportError:
            logger.error("whisperx not installed. Install with: pip install whisperx")
            raise
        except Exception as e:
            logger.error(f"Failed to load WhisperX model: {e}")
            raise
    
    def transcribe_audio(self, audio_path: str, job_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Transcribe audio file using WhisperX with full pipeline
        
        Args:
            audio_path: Path to audio file
            job_id: Optional job ID for logging
            
        Returns:
            Dictionary containing transcription results with alignment and optional diarization
        """
        if self.model is None:
            self.load_model()
        
        logger.info(f"🎯 Starting WhisperX transcription: {os.path.basename(audio_path)}")
        total_start = time.time()
        
        try:
            import whisperx
            
            # Step 1: Load and preprocess audio
            logger.info("📁 Loading audio...")
            audio = whisperx.load_audio(audio_path)
            audio_duration = len(audio) / 16000  # 16kHz sample rate
            
            # Step 2: Transcribe with Whisper
            logger.info("🎙️ Transcribing with Whisper...")
            transcribe_start = time.time()
            
            result = self.model.transcribe(
                audio,
                batch_size=self.batch_size,
                language=None,  # Auto-detect
                task="transcribe"
            )
            
            transcribe_time = time.time() - transcribe_start
            detected_language = result["language"]
            
            logger.info(f"✅ Transcription completed in {transcribe_time:.2f}s")
            logger.info(f"🌍 Detected language: {detected_language}")
            logger.info(f"📝 Generated {len(result['segments'])} segments")
            
            # Step 3: Align for word-level timestamps
            logger.info("🎯 Aligning for word-level timestamps...")
            align_start = time.time()
            
            # Update alignment model for detected language if different from English
            if detected_language != "en" and detected_language != self.align_metadata.get("language", "en"):
                logger.info(f"Loading alignment model for {detected_language}...")
                try:
                    self.align_model, self.align_metadata = whisperx.load_align_model(
                        language_code=detected_language,
                        device=self.device
                    )
                except Exception as e:
                    logger.warning(f"Could not load alignment for {detected_language}, using English: {e}")
            
            # Perform alignment
            aligned_result = whisperx.align(
                result["segments"],
                self.align_model,
                self.align_metadata,
                audio,
                self.device,
                return_char_alignments=False
            )
            
            align_time = time.time() - align_start
            logger.info(f"✅ Alignment completed in {align_time:.2f}s")
            
            # Step 4: Speaker diarization (if enabled)
            diarize_time = 0
            if self.enable_diarization and self.diarize_model:
                logger.info("👥 Performing speaker diarization...")
                diarize_start = time.time()
                
                diarize_segments = self.diarize_model(audio_path)
                diarized_result = whisperx.assign_word_speakers(diarize_segments, aligned_result)
                aligned_result = diarized_result
                
                diarize_time = time.time() - diarize_start
                logger.info(f"✅ Diarization completed in {diarize_time:.2f}s")
                
                # Count unique speakers
                speakers = set()
                for segment in aligned_result["segments"]:
                    if "speaker" in segment:
                        speakers.add(segment["speaker"])
                logger.info(f"👥 Identified {len(speakers)} unique speakers")
            
            total_time = time.time() - total_start
            
            # Create comprehensive result
            final_result = {
                "text": " ".join([segment["text"] for segment in aligned_result["segments"]]),
                "segments": aligned_result["segments"],
                "word_segments": aligned_result.get("word_segments", []),
                "language": detected_language,
                "language_probability": result.get("language_probability", 0.0),
                "duration": audio_duration,
                "transcriber": "whisperx",
                "model": self.model_name,
                "compute_type": self.compute_type,
                "batch_size": self.batch_size,
                "processing_time": total_time,
                "transcribe_time": transcribe_time,
                "align_time": align_time,
                "diarize_time": diarize_time,
                "alignment_enabled": True,
                "diarization_enabled": self.enable_diarization,
                "word_timestamps": True,
                "speaker_diarization": self.enable_diarization
            }
            
            # Add performance metrics
            real_time_factor = audio_duration / total_time
            
            logger.info(f"🎉 WhisperX pipeline completed:")
            logger.info(f"  Total Time: {total_time:.2f} seconds")
            logger.info(f"  Audio Duration: {audio_duration:.1f} seconds")
            logger.info(f"  Real-time Factor: {real_time_factor:.2f}x")
            logger.info(f"  Segments: {len(aligned_result['segments'])}")
            logger.info(f"  Word-level timestamps: ✅")
            if self.enable_diarization:
                logger.info(f"  Speaker diarization: ✅")
            
            return final_result
            
        except Exception as e:
            logger.error(f"WhisperX transcription failed: {e}")
            raise
    
    def get_model_info(self) -> Dict[str, Any]:
        """Get information about the loaded models"""
        return {
            "transcriber": "whisperx",
            "model_name": self.model_name,
            "device": self.device,
            "compute_type": self.compute_type,
            "batch_size": self.batch_size,
            "model_loaded": self.model is not None,
            "align_model_loaded": self.align_model is not None,
            "diarize_model_loaded": self.diarize_model is not None,
            "diarization_enabled": self.enable_diarization,
            "supports_gpu": torch.cuda.is_available() if self.device == "cuda" else False,
            "gpu_memory_gb": torch.cuda.get_device_properties(0).total_memory / 1e9 if torch.cuda.is_available() else 0
        }
    
    def cleanup(self):
        """Clean up models and free GPU memory"""
        models_to_cleanup = [
            ("main model", self.model),
            ("alignment model", self.align_model), 
            ("diarization model", self.diarize_model)
        ]
        
        for name, model in models_to_cleanup:
            if model is not None:
                del model
                logger.info(f"Cleaned up {name}")
        
        self.model = None
        self.align_model = None
        self.align_metadata = None
        self.diarize_model = None
        
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            
        logger.info("WhisperX models cleaned up")