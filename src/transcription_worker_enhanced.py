#!/usr/bin/env python3
"""
Enhanced Transcription Worker with Detailed Progress Logging
Provides real-time progress updates to S3 for monitoring
"""

import os
import sys
import json
import time
import signal
import logging
import argparse
import uuid
from datetime import datetime
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

# Add project root to path
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(project_root)

from queue_metrics import QueueMetricsManager
from transcriber import Transcriber, TranscriptionError
from progress_logger import ProgressLogger

# Try to import GPU optimized transcriber
try:
    from transcriber_gpu_optimized import GPUOptimizedTranscriber
    GPU_OPTIMIZED_AVAILABLE = True
except ImportError:
    GPU_OPTIMIZED_AVAILABLE = False

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class EnhancedTranscriptionWorker:
    """Enhanced worker with detailed progress tracking"""
    
    def __init__(self, queue_url, s3_bucket, region='us-east-1', 
                 model_name='large-v3', device='cuda', idle_timeout_minutes=60,
                 temp_dir='/tmp'):
        self.queue_url = queue_url
        self.s3_bucket = s3_bucket
        self.region = region
        self.model_name = model_name
        self.use_gpu = device == 'cuda'
        self.idle_timeout_minutes = idle_timeout_minutes
        self.temp_dir = temp_dir
        self.worker_id = f"worker-{uuid.uuid4()}"
        
        # Initialize AWS clients
        self.sqs = boto3.client('sqs', region_name=region)
        self.s3 = boto3.client('s3', region_name=region)
        
        # Initialize queue metrics manager
        self.metrics_manager = QueueMetricsManager(
            queue_url=queue_url,
            s3_bucket=s3_bucket,
            region=region
        )
        
        # Select appropriate transcriber
        if self.use_gpu and GPU_OPTIMIZED_AVAILABLE:
            logger.info("🚀 Using GPU-OPTIMIZED transcriber for maximum performance")
            self.transcriber = GPUOptimizedTranscriber(
                model_name=model_name,
                device=device,
                chunk_size=30,
                s3_bucket=s3_bucket,
                region=region,
                batch_size=64,
                num_workers=2
            )
        else:
            logger.info("Using standard transcriber")
            self.transcriber = Transcriber(
                model_name=model_name,
                device=device,
                chunk_size=30,
                s3_bucket=s3_bucket,
                region=region
            )
        
        # Worker state
        self.idle_start = None
        self.shutdown_requested = False
        self.jobs_processed = 0
        
        # Set up signal handlers
        self.setup_signal_handlers()
    
    def setup_signal_handlers(self):
        """Set up signal handlers for graceful shutdown"""
        def signal_handler(signum, frame):
            logger.info(f"Received signal {signum}, initiating graceful shutdown...")
            self.shutdown_requested = True
            
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)
    
    def process_job_with_progress(self, message: dict) -> bool:
        """Process job with detailed progress tracking"""
        try:
            # Parse message
            body = json.loads(message['Body'])
            job_id = body.get('job_id')
            s3_input_path = body.get('s3_input_path')
            s3_output_path = body.get('s3_output_path')
            estimated_duration = body.get('estimated_duration_seconds', 300)
            
            # Initialize progress logger
            progress = ProgressLogger(self.s3_bucket, job_id, self.region)
            
            logger.info(f"🎬 STARTING JOB {job_id}")
            progress.update("STARTED", f"Job {job_id} started processing", 0)
            
            # Download audio
            progress.update("DOWNLOADING", f"Downloading from {s3_input_path}", 5)
            local_audio_path = self.download_audio_from_s3(s3_input_path)
            progress.update("DOWNLOADED", f"Audio downloaded to worker", 10)
            
            try:
                # Get file size for progress estimation
                file_size_mb = os.path.getsize(local_audio_path) / (1024 * 1024)
                progress.update("PREPARING", f"Audio file ready ({file_size_mb:.1f}MB)", 15)
                
                # Load model if needed
                progress.update("MODEL_LOADING", "Loading transcription model", 20)
                self.transcriber.load_model()
                progress.update("MODEL_READY", "Model loaded and ready", 25)
                
                # Enhanced progress tracking for transcription
                start_time = time.time()
                progress.update("TRANSCRIBING", "Starting transcription", 30)
                
                # Create a progress callback for chunk processing
                def chunk_callback(chunk_idx, total_chunks):
                    percentage = 30 + int((chunk_idx / total_chunks) * 60)  # 30-90%
                    progress.update(
                        "TRANSCRIBING", 
                        f"Processing audio chunks",
                        percentage,
                        {"current": chunk_idx, "total": total_chunks}
                    )
                
                # Modify transcriber to accept callback (if possible)
                # For now, we'll do periodic updates
                transcript_result = self.transcriber.transcribe_audio(
                    local_audio_path,
                    job_id=job_id
                )
                
                actual_duration = time.time() - start_time
                segments = len(transcript_result.get('segments', []))
                
                progress.update("TRANSCRIBED", f"Transcription complete - {segments} segments", 90)
                
                # Create output
                output_data = {
                    "job_id": job_id,
                    "s3_input_path": s3_input_path,
                    "s3_output_path": s3_output_path,
                    "estimated_duration_seconds": estimated_duration,
                    "actual_transcription_time_seconds": actual_duration,
                    "processed_at": datetime.utcnow().isoformat() + "Z",
                    "worker_id": self.worker_id,
                    "worker_type": "gpu_optimized" if self.use_gpu and GPU_OPTIMIZED_AVAILABLE else "standard",
                    "model": self.model_name,
                    "segments_count": segments,
                    "transcript": transcript_result
                }
                
                # Save and upload
                progress.update("SAVING", "Saving transcript", 95)
                local_output_path = os.path.join(self.temp_dir, f"{job_id}_transcript.json")
                with open(local_output_path, 'w') as f:
                    json.dump(output_data, f, indent=2)
                
                progress.update("UPLOADING", f"Uploading to {s3_output_path}", 98)
                self.upload_transcript_to_s3(local_output_path, s3_output_path)
                
                # Complete
                progress.complete(True, {"segments": segments, "duration": actual_duration})
                logger.info(f"🎉 Job {job_id} completed in {actual_duration:.1f}s")
                
                # Cleanup
                os.remove(local_audio_path)
                os.remove(local_output_path)
                
                self.jobs_processed += 1
                return True
                
            except Exception as e:
                progress.update("ERROR", f"Transcription failed: {str(e)}", 0)
                logger.error(f"Error processing job {job_id}: {e}")
                return False
                
        except Exception as e:
            logger.error(f"Fatal error in job processing: {e}")
            return False
    
    def download_audio_from_s3(self, s3_path: str) -> str:
        """Download audio file from S3"""
        parsed = urlparse(s3_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        
        # Create local path
        filename = os.path.basename(key)
        local_path = os.path.join(self.temp_dir, f"{uuid.uuid4()}_{filename}")
        
        logger.info(f"Downloading {s3_path} to {local_path}")
        self.s3.download_file(bucket, key, local_path)
        
        return local_path
    
    def upload_transcript_to_s3(self, local_path: str, s3_path: str):
        """Upload transcript to S3"""
        parsed = urlparse(s3_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        
        logger.info(f"Uploading transcript to {s3_path}")
        self.s3.upload_file(local_path, bucket, key)
    
    def should_continue_running(self) -> bool:
        """Check if worker should continue running"""
        if self.shutdown_requested:
            logger.info("Shutdown requested")
            return False
            
        # Check idle timeout
        current_time = time.time()
        
        # If we just processed a job, reset idle timer
        if self.jobs_processed > 0:
            self.idle_start = current_time
            self.jobs_processed = 0
            
        # If no idle start set, set it now
        if self.idle_start is None:
            self.idle_start = current_time
            
        # Check if idle timeout exceeded
        idle_time = current_time - self.idle_start
        if idle_time > (self.idle_timeout_minutes * 60):
            logger.info(f"Idle timeout reached ({self.idle_timeout_minutes} minutes)")
            return False
            
        return True
    
    def run(self):
        """Main worker loop with enhanced monitoring"""
        logger.info(f"🚀 Enhanced Transcription Worker {self.worker_id} starting...")
        logger.info(f"Configuration:")
        logger.info(f"  Queue URL: {self.queue_url}")
        logger.info(f"  S3 Bucket: {self.s3_bucket}")
        logger.info(f"  Model: {self.model_name}")
        logger.info(f"  GPU: {'Enabled (Optimized)' if self.use_gpu and GPU_OPTIMIZED_AVAILABLE else 'Enabled' if self.use_gpu else 'Disabled'}")
        logger.info(f"  Idle timeout: {self.idle_timeout_minutes} minutes")
        
        # Create worker status file in S3
        worker_status_key = f"workers/{self.worker_id}/status.json"
        worker_status = {
            "worker_id": self.worker_id,
            "status": "RUNNING",
            "started_at": datetime.utcnow().isoformat() + "Z",
            "model": self.model_name,
            "gpu_enabled": self.use_gpu,
            "gpu_optimized": self.use_gpu and GPU_OPTIMIZED_AVAILABLE
        }
        
        self.s3.put_object(
            Bucket=self.s3_bucket,
            Key=worker_status_key,
            Body=json.dumps(worker_status),
            ContentType="application/json"
        )
        
        while self.should_continue_running():
            try:
                # Update worker heartbeat
                worker_status["last_heartbeat"] = datetime.utcnow().isoformat() + "Z"
                worker_status["jobs_processed"] = self.jobs_processed
                self.s3.put_object(
                    Bucket=self.s3_bucket,
                    Key=worker_status_key,
                    Body=json.dumps(worker_status),
                    ContentType="application/json"
                )
                
                # Poll for messages
                response = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    MaxNumberOfMessages=1,
                    WaitTimeSeconds=20,
                    VisibilityTimeout=3600  # 1 hour for long podcasts
                )
                
                if 'Messages' in response:
                    for message in response['Messages']:
                        success = self.process_job_with_progress(message)
                        
                        if success:
                            # Delete message from queue
                            self.sqs.delete_message(
                                QueueUrl=self.queue_url,
                                ReceiptHandle=message['ReceiptHandle']
                            )
                        else:
                            # Let message become visible again for retry
                            logger.warning("Job failed, message will become visible for retry")
                            
            except Exception as e:
                logger.error(f"Error in worker loop: {e}")
                time.sleep(10)
        
        # Update worker status to stopped
        worker_status["status"] = "STOPPED"
        worker_status["stopped_at"] = datetime.utcnow().isoformat() + "Z"
        self.s3.put_object(
            Bucket=self.s3_bucket,
            Key=worker_status_key,
            Body=json.dumps(worker_status),
            ContentType="application/json"
        )
        
        logger.info("Worker shutting down gracefully")


def main():
    parser = argparse.ArgumentParser(description='Enhanced Transcription Worker')
    parser.add_argument('--queue-url', required=True, help='SQS queue URL')
    parser.add_argument('--s3-bucket', required=True, help='S3 bucket for metrics')
    parser.add_argument('--region', default='us-east-1', help='AWS region')
    parser.add_argument('--model', default='large-v3', help='Whisper model to use')
    parser.add_argument('--cpu-only', action='store_true', help='Use CPU instead of GPU')
    parser.add_argument('--idle-timeout', type=int, default=60, help='Idle timeout in minutes')
    
    args = parser.parse_args()
    
    device = 'cpu' if args.cpu_only else 'cuda'
    
    worker = EnhancedTranscriptionWorker(
        queue_url=args.queue_url,
        s3_bucket=args.s3_bucket,
        region=args.region,
        model_name=args.model,
        device=device,
        idle_timeout_minutes=args.idle_timeout
    )
    
    worker.run()


if __name__ == '__main__':
    main()