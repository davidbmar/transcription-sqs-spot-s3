#!/usr/bin/python3
# transcriber.py - WhisperX Transcription Module

import os
import json
import logging
import numpy as np
import torch
import whisperx
from datetime import datetime
import tempfile
import boto3
import soundfile as sf
import subprocess
from pathlib import Path

logger = logging.getLogger(__name__)

class TranscriptionError(Exception):
    """Exception raised for errors during transcription"""
    pass

class ModelLoadError(TranscriptionError):
    """Exception raised for errors loading the model"""
    pass

class AudioProcessingError(TranscriptionError):
    """Exception raised for errors processing audio"""
    pass

class Transcriber:
    """Handles audio transcription using WhisperX with chunking and progress tracking"""

    def __init__(self, model_name="large-v3", device="cuda", chunk_size=30,
                 s3_bucket=None, region="us-east-1", batch_size=32, vad_onset=0.10, vad_offset=0.80):
        """
        Initialize the transcriber
        
        Args:
            model_name: WhisperX model to use
            device: Device to run model on ('cuda' or 'cpu')
            chunk_size: Size of audio chunks in seconds
            s3_bucket: S3 bucket for storing intermediate results
            region: AWS region
            batch_size: Batch size for processing (32 optimal for GPU)
            vad_onset: Voice activity detection onset threshold (0-1)
            vad_offset: Voice activity detection offset threshold (0-1)
        """
        self.model_name = model_name
        # Determine actual device to use with detailed logging
        cuda_available = torch.cuda.is_available()
        requested_device = device
        self.device = "cuda" if cuda_available and device == "cuda" else "cpu"
        
        logger.info(f"🔧 DEVICE DETECTION:")
        logger.info(f"  - Requested device: {requested_device}")
        logger.info(f"  - CUDA available: {cuda_available}")
        logger.info(f"  - Selected device: {self.device}")
        if cuda_available:
            logger.info(f"  - CUDA devices: {torch.cuda.device_count()}")
            logger.info(f"  - Current CUDA device: {torch.cuda.current_device()}")
        
        self.chunk_size = chunk_size
        self.s3_bucket = s3_bucket
        self.s3 = boto3.client('s3', region_name=region) if s3_bucket else None
        self.batch_size = batch_size
        self.vad_onset = vad_onset
        self.vad_offset = vad_offset
        self.model = None

        logger.info(f"🔧 TRANSCRIBER INIT: model={model_name}, device={self.device}, chunk_size={chunk_size}s")

    def load_model(self):
        """Load the WhisperX model"""
        if self.model is not None:
            return

        try:
            logger.info(f"🔧 MODEL LOADING: Starting WhisperX model {self.model_name} on {self.device}")
            
            # Use float32 for CPU to avoid float16 computation issues
            compute_type = "float32" if self.device == "cpu" else "float16"
            logger.info(f"🔧 COMPUTE TYPE: Selected {compute_type} for device {self.device}")
            logger.info(f"🔧 TORCH CUDA: Available={torch.cuda.is_available()}, Device Count={torch.cuda.device_count() if torch.cuda.is_available() else 0}")
            
            self.model = whisperx.load_model(self.model_name, self.device, compute_type=compute_type)
            logger.info(f"✅ MODEL LOADED: WhisperX {self.model_name} successfully loaded")

            # Load alignment model for improved word-level timestamps
            logger.info("🔧 ALIGNMENT MODEL: Loading alignment model for English")
            self.alignment_model, self.metadata = whisperx.load_align_model(
                language_code="en",
                device=self.device
            )

            logger.info("✅ ALL MODELS LOADED: WhisperX and alignment models ready for transcription")
        except Exception as e:
            error_msg = f"Failed to load WhisperX model: {str(e)}"
            logger.error(error_msg)
            raise ModelLoadError(error_msg)

    def convert_webm_to_wav(self, input_file):
        """
        Convert webm file to wav format using ffmpeg
        
        Args:
            input_file: Path to webm file
            
        Returns:
            Path to converted wav file
        """
        try:
            # Create temporary wav file
            input_path = Path(input_file)
            wav_file = input_path.with_suffix('.wav')
            
            logger.info(f"🎥 FFMPEG CONVERSION: {input_file} → {wav_file}")
            
            # Use ffmpeg to convert webm to wav
            cmd = [
                'ffmpeg', '-i', input_file,
                '-acodec', 'pcm_s16le',  # 16-bit PCM
                '-ar', '16000',          # 16kHz sample rate for Whisper
                '-ac', '1',              # Mono
                '-y',                    # Overwrite output file
                str(wav_file)
            ]
            
            logger.info(f"🔧 FFMPEG COMMAND: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            logger.info(f"✅ FFMPEG SUCCESS: Converted to {wav_file}")
            logger.info(f"📊 FFMPEG OUTPUT: {result.stderr[-200:] if result.stderr else 'No stderr'}")
            return str(wav_file)
            
        except subprocess.CalledProcessError as e:
            error_msg = f"FFmpeg conversion failed: {e.stderr}"
            logger.error(error_msg)
            raise AudioProcessingError(error_msg)
        except Exception as e:
            error_msg = f"Error converting webm file: {str(e)}"
            logger.error(error_msg)
            raise AudioProcessingError(error_msg)

    def segment_audio(self, audio_file, output_dir):
        """
        Split audio file into chunks for processing
        
        Args:
            audio_file: Path to audio file
            output_dir: Directory to save chunks
            
        Returns:
            List of chunk file paths
        """
        try:
            os.makedirs(output_dir, exist_ok=True)

            # Check if we need to convert webm to wav
            audio_path = audio_file
            if audio_file.lower().endswith('.webm'):
                logger.info(f"🎬 WEBM DETECTED: {audio_file}")
                logger.info(f"🔄 Converting webm to wav format...")
                audio_path = self.convert_webm_to_wav(audio_file)
                logger.info(f"✅ WEBM CONVERSION COMPLETE: {audio_path}")

            # Load audio file
            logger.info(f"Loading audio file: {audio_path}")
            audio_data, sample_rate = sf.read(audio_path)

            # Calculate chunk size in samples
            chunk_samples = int(self.chunk_size * sample_rate)
            total_samples = len(audio_data)

            # Create chunks
            chunk_files = []
            for i, start_idx in enumerate(range(0, total_samples, chunk_samples)):
                end_idx = min(start_idx + chunk_samples, total_samples)
                chunk_data = audio_data[start_idx:end_idx]

                # Save chunk
                chunk_file = os.path.join(output_dir, f"chunk_{i:04d}.wav")
                sf.write(chunk_file, chunk_data, sample_rate)
                chunk_files.append(chunk_file)

            logger.info(f"Created {len(chunk_files)} audio chunks")
            
            # Clean up converted wav file if we created one
            if audio_path != audio_file and os.path.exists(audio_path):
                logger.info(f"Cleaning up converted file: {audio_path}")
                os.remove(audio_path)
            
            return chunk_files

        except Exception as e:
            # Clean up converted wav file if we created one
            if 'audio_path' in locals() and audio_path != audio_file and os.path.exists(audio_path):
                logger.info(f"Cleaning up converted file after error: {audio_path}")
                os.remove(audio_path)
            
            error_msg = f"Error segmenting audio: {str(e)}"
            logger.error(error_msg)
            raise AudioProcessingError(error_msg)

    def transcribe_audio(self, audio_file, job_id=None, job_tracker=None, video_id=None, language="en"):
        """
        Transcribe audio file with progress tracking
        
        Args:
            audio_file: Path to audio file
            job_id: Job ID for tracking
            job_tracker: JobTracker instance for progress updates
            video_id: YouTube video ID
            language: Language code
            
        Returns:
            Transcription result with word-level timestamps
        """
        try:
            # Ensure model is loaded
            self.load_model()

            # Create temporary directory for chunks
            with tempfile.TemporaryDirectory() as temp_dir:
                logger.info(f"Created temporary directory: {temp_dir}")

                # Segment audio
                chunk_files = self.segment_audio(audio_file, temp_dir)

                if job_tracker and job_id:
                    job_tracker.update_progress(job_id, total_chunks=len(chunk_files), completed_chunks=0)

                # Process each chunk
                all_segments = []

                # This is to be passed to the self.model.transcribe as in 
                # something like:   result = self.model.transcribe(audio, vad_options=vad_options)
                vad_options = {
                    "vad_onset": self.vad_onset,
                    "vad_offset": self.vad_offset,
                }

                for i, chunk_file in enumerate(chunk_files):
                    logger.info(f"Processing chunk {i+1}/{len(chunk_files)}")

                    # Transcribe chunk
                    try:
                        # Try with vad_options first (newer WhisperX versions)
                        result = self.model.transcribe(
                            chunk_file,
                            batch_size=self.batch_size,
                            language=language,
                            vad_options=vad_options
                        )
                    except TypeError as e:
                        if "vad_options" in str(e):
                            logger.info("⚠️ VAD options not supported, using basic transcription")
                            # Fallback for older WhisperX versions
                            result = self.model.transcribe(
                                chunk_file,
                                batch_size=self.batch_size,
                                language=language
                            )
                        else:
                            raise

                    # Align words for precise timestamps
                    result = whisperx.align(
                        result["segments"],
                        self.alignment_model,
                        self.metadata,
                        chunk_file,
                        device=self.device
                    )

                    # Adjust timestamps for chunk position
                    chunk_start_time = i * self.chunk_size
                    for segment in result["segments"]:
                        segment["start"] += chunk_start_time
                        segment["end"] += chunk_start_time

                        for word in segment["words"]:
                            word["start"] += chunk_start_time
                            word["end"] += chunk_start_time

                    # Add to results
                    all_segments.extend(result["segments"])

                    # Save progress to S3 if needed
                    if self.s3_bucket and video_id:
                        segment_key = f"transcripts/{video_id}/segments/chunk_{i:04d}.json"
                        self.s3.put_object(
                            Body=json.dumps(result["segments"]),
                            Bucket=self.s3_bucket,
                            Key=segment_key,
                            ContentType="application/json"
                        )

                    # Update progress
                    if job_tracker and job_id:
                        job_tracker.update_progress(job_id, completed_chunks=i+1)

                # Combine results
                final_result = {
                    "segments": sorted(all_segments, key=lambda x: x["start"]),
                    "language": language,
                    "video_id": video_id,
                    "transcribed_at": datetime.now().isoformat()
                }

                # Save complete transcript
                if self.s3_bucket and video_id:
                    transcript_key = f"transcripts/{video_id}/full_transcript.json"
                    self.s3.put_object(
                        Body=json.dumps(final_result),
                        Bucket=self.s3_bucket,
                        Key=transcript_key,
                        ContentType="application/json"
                    )

                return final_result

        except Exception as e:
            error_msg = f"Error transcribing audio: {str(e)}"
            logger.error(error_msg)
            raise TranscriptionError(error_msg)

    def load_transcript_from_s3(self, video_id):
        """
        Load transcript from S3 if it exists
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            Transcript data or None if not found
        """
        if not self.s3_bucket:
            return None

        try:
            transcript_key = f"transcripts/{video_id}/full_transcript.json"
            response = self.s3.get_object(Bucket=self.s3_bucket, Key=transcript_key)
            transcript_data = json.loads(response['Body'].read().decode('utf-8'))
            return transcript_data

        except self.s3.exceptions.NoSuchKey:
            return None
        except Exception as e:
            logger.error(f"Error loading transcript from S3: {str(e)}")
            return None

    def load_segment_from_s3(self, video_id, chunk_index):
        """
        Load specific segment from S3
        
        Args:
            video_id: YouTube video ID
            chunk_index: Chunk index to load
            
        Returns:
            Segment data or None if not found
        """
        if not self.s3_bucket:
            return None

        try:
            segment_key = f"transcripts/{video_id}/segments/chunk_{chunk_index:04d}.json"
            response = self.s3.get_object(Bucket=self.s3_bucket, Key=segment_key)
            segment_data = json.loads(response['Body'].read().decode('utf-8'))
            return segment_data

        except self.s3.exceptions.NoSuchKey:
            return None
        except Exception as e:
            logger.error(f"Error loading segment from S3: {str(e)}")
            return None

    def get_completed_segments(self, video_id):
        """
        Get list of completed segment indices from S3
        
        Args:
            video_id: YouTube video ID
            
        Returns:
            List of completed segment indices
        """
        if not self.s3_bucket:
            return []

        try:
            prefix = f"transcripts/{video_id}/segments/"
            response = self.s3.list_objects_v2(
                Bucket=self.s3_bucket,
                Prefix=prefix
            )

            completed = []
            if 'Contents' in response:
                for item in response['Contents']:
                    key = item['Key']
                    # Extract index from chunk_XXXX.json
                    chunk_file = os.path.basename(key)
                    if chunk_file.startswith('chunk_') and chunk_file.endswith('.json'):
                        idx_str = chunk_file[6:10]  # Extract XXXX part
                        completed.append(int(idx_str))

            return sorted(completed)

        except Exception as e:
            logger.error(f"Error listing completed segments: {str(e)}")
            return []

    def resume_transcription(self, audio_file, job_id, job_tracker, video_id, language="en"):
        """
        Resume transcription from where it left off
        
        Args:
            audio_file: Path to audio file
            job_id: Job ID for tracking
            job_tracker: JobTracker instance
            video_id: YouTube video ID
            language: Language code
            
        Returns:
            Transcription result
        """
        # Check if full transcript already exists
        full_transcript = self.load_transcript_from_s3(video_id)
        if full_transcript:
            logger.info(f"Found complete transcript for {video_id}, skipping transcription")
            return full_transcript

        # Get list of segments already processed
        completed_segments = self.get_completed_segments(video_id)
        logger.info(f"Found {len(completed_segments)} completed segments for {video_id}")

        # Continue with normal transcription but skip completed chunks
        try:
            # Ensure model is loaded
            self.load_model()

            # Create temporary directory for chunks
            with tempfile.TemporaryDirectory() as temp_dir:
                # Segment audio
                chunk_files = self.segment_audio(audio_file, temp_dir)

                if job_tracker:
                    job_tracker.update_progress(job_id, total_chunks=len(chunk_files),
                                             completed_chunks=len(completed_segments))

                # Process each chunk that hasn't been completed
                all_segments = []

                # First load all completed segments
                for idx in completed_segments:
                    segment_data = self.load_segment_from_s3(video_id, idx)
                    if segment_data:
                        all_segments.extend(segment_data)

                # Define VAD options for resume transcription
                vad_options = {
                    "vad_onset": self.vad_onset,
                    "vad_offset": self.vad_offset,
                }

                # Process remaining chunks
                for i, chunk_file in enumerate(chunk_files):
                    if i in completed_segments:
                        logger.info(f"Skipping already processed chunk {i}")
                        continue

                    logger.info(f"Processing chunk {i+1}/{len(chunk_files)}")

                    # Transcribe chunk
                    try:
                        # Try with vad_options first (newer WhisperX versions)
                        result = self.model.transcribe(
                            chunk_file,
                            batch_size=self.batch_size,
                            language=language,
                            vad_options=vad_options
                        )
                    except TypeError as e:
                        if "vad_options" in str(e):
                            logger.info("⚠️ VAD options not supported, using basic transcription")
                            # Fallback for older WhisperX versions
                            result = self.model.transcribe(
                                chunk_file,
                                batch_size=self.batch_size,
                                language=language
                            )
                        else:
                            raise

                    # Align words for precise timestamps
                    result = whisperx.align(
                        result["segments"],
                        self.alignment_model,
                        self.metadata,
                        chunk_file,
                        device=self.device
                    )

                    # Adjust timestamps for chunk position
                    chunk_start_time = i * self.chunk_size
                    for segment in result["segments"]:
                        segment["start"] += chunk_start_time
                        segment["end"] += chunk_start_time

                        for word in segment["words"]:
                            word["start"] += chunk_start_time
                            word["end"] += chunk_start_time

                    # Add to results
                    all_segments.extend(result["segments"])

                    # Save progress to S3
                    if self.s3_bucket:
                        segment_key = f"transcripts/{video_id}/segments/chunk_{i:04d}.json"
                        self.s3.put_object(
                            Body=json.dumps(result["segments"]),
                            Bucket=self.s3_bucket,
                            Key=segment_key,
                            ContentType="application/json"
                        )

                    # Update progress
                    if job_tracker:
                        job_tracker.update_progress(
                            job_id,
                            completed_chunks=len(completed_segments) + i + 1
                        )

                # Combine results
                final_result = {
                    "segments": sorted(all_segments, key=lambda x: x["start"]),
                    "language": language,
                    "video_id": video_id,
                    "transcribed_at": datetime.now().isoformat()
                }

                # Save complete transcript
                if self.s3_bucket:
                    transcript_key = f"transcripts/{video_id}/full_transcript.json"
                    self.s3.put_object(
                        Body=json.dumps(final_result),
                        Bucket=self.s3_bucket,
                        Key=transcript_key,
                        ContentType="application/json"
                    )

                return final_result

        except Exception as e:
            error_msg = f"Error resuming transcription: {str(e)}"
            logger.error(error_msg)
            raise TranscriptionError(error_msg)


# Example usage
if __name__ == "__main__":
    # Simple test code
    logging.basicConfig(level=logging.INFO)

    # Create transcriber (for testing only)
    transcriber = Transcriber(model_name="base", device="cuda")

    # Test with a local WAV file
    try:
        result = transcriber.transcribe_audio("./temp/test/audio.wav")
        print(f"Transcription result: {len(result['segments'])} segments")

        # Print first few segments
        for i, segment in enumerate(result['segments'][:3]):
            print(f"Segment {i}: {segment['start']:.2f}s - {segment['end']:.2f}s")
            print(f"Text: {segment['text']}")
            print("Words:", [word['word'] for word in segment['words']])
            print()

    except Exception as e:
        print(f"Error: {str(e)}")
