#!/usr/bin/env python3
"""
Transcription Worker - Processes audio files from S3 using SQS queue
"""

import os
import sys
import argparse
import json
import boto3
import logging
import time
import uuid
import signal
import threading
import subprocess
from datetime import datetime, timedelta
from typing import Dict, Optional
from urllib.parse import urlparse
from queue_metrics import QueueMetricsManager
# Import GPU-optimized transcriber if available
try:
    from transcriber_gpu_optimized import GPUOptimizedTranscriber
    GPU_OPTIMIZED_AVAILABLE = True
except ImportError:
    GPU_OPTIMIZED_AVAILABLE = False
    
from transcriber import Transcriber, TranscriptionError

# Setup logging with both file and console output
log_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')

# File handler for persistent logs
file_handler = logging.FileHandler('/tmp/transcription_worker.log')
file_handler.setFormatter(log_formatter)
file_handler.setLevel(logging.DEBUG)

# Console handler for immediate output
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)
console_handler.setLevel(logging.INFO)

# Configure root logger
logging.basicConfig(
    level=logging.DEBUG,
    handlers=[file_handler, console_handler]
)
logger = logging.getLogger(__name__)


class TranscriptionWorker:
    """Worker that processes audio transcription jobs from SQS queue"""
    
    def __init__(self, 
                 queue_url: str,
                 s3_bucket: str,
                 region: str = "us-east-1",
                 temp_dir: str = "/tmp",
                 idle_threshold_minutes: int = 60,
                 use_gpu: bool = True,
                 model_name: str = "large-v3"):
        """
        Initialize the transcription worker
        
        Args:
            queue_url: SQS queue URL
            s3_bucket: S3 bucket for metrics
            region: AWS region
            temp_dir: Temporary directory for downloads
            idle_threshold_minutes: Minutes to wait before shutting down when idle
            use_gpu: Whether to use GPU for transcription
            model_name: Whisper model to use
        """
        self.queue_url = queue_url
        self.s3_bucket = s3_bucket
        self.region = region
        self.temp_dir = temp_dir
        self.idle_threshold_minutes = idle_threshold_minutes
        self.use_gpu = use_gpu
        self.model_name = model_name
        
        # Generate unique worker ID
        self.worker_id = f"worker-{uuid.uuid4()}"
        logger.info(f"Transcription worker initialized with ID: {self.worker_id}")
        
        # Initialize AWS clients
        self.s3 = boto3.client('s3', region_name=region)
        self.sqs = boto3.client('sqs', region_name=region)
        
        # Initialize components
        self.metrics_manager = QueueMetricsManager(s3_bucket, region=region)
        
        # Initialize transcriber - use GPU-optimized version if available and using GPU
        device = "cuda" if use_gpu else "cpu"
        
        if use_gpu and GPU_OPTIMIZED_AVAILABLE:
            logger.info("🚀 Using GPU-OPTIMIZED transcriber for maximum performance")
            self.transcriber = GPUOptimizedTranscriber(
                model_name=model_name,
                device=device,
                chunk_size=30,
                s3_bucket=s3_bucket,
                region=region,
                batch_size=64,  # Optimal for GPU
                num_workers=2   # Parallel preprocessing
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
        
        # Ensure temp directory exists
        os.makedirs(temp_dir, exist_ok=True)
        
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
    
    def should_continue_running(self) -> bool:
        """
        Check if we should keep running or shut down
        
        Returns:
            True if should continue, False if should shutdown
        """
        if self.shutdown_requested:
            logger.info("Shutdown requested")
            return False
        
        # Check if it's within operating hours (optional - can be configured)
        # Skip operating hours check for now to allow 24/7 operation
        # hour = datetime.now().hour
        # if hour < 6 or hour > 22:  # Outside 6am-10pm
        #     logger.info("Outside operating hours, shutting down")
        #     return False
        
        # Check queue depth
        try:
            attrs = self.sqs.get_queue_attributes(
                QueueUrl=self.queue_url,
                AttributeNames=['ApproximateNumberOfMessages']
            )
            queue_size = int(attrs['Attributes']['ApproximateNumberOfMessages'])
            
            if queue_size == 0:
                if self.idle_start is None:
                    self.idle_start = time.time()
                    logger.info("Queue is empty, starting idle timer")
                elif time.time() - self.idle_start > self.idle_threshold_minutes * 60:
                    logger.info(f"💤 IDLE SHUTDOWN: Worker idle for {self.idle_threshold_minutes} minutes")
                    logger.info("🔌 Initiating spot instance shutdown to save costs")
                    return False
            else:
                self.idle_start = None  # Reset idle timer
                
        except Exception as e:
            logger.error(f"Error checking queue attributes: {e}")
            # Continue running on error
            
        return True
    
    def download_audio_from_s3(self, s3_input_path: str) -> str:
        """
        Download audio file from S3
        
        Args:
            s3_input_path: S3 path like s3://bucket/path/to/file.mp3
            
        Returns:
            Local file path to downloaded audio
        """
        # Parse S3 path
        parsed = urlparse(s3_input_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        
        # Create local filename
        filename = os.path.basename(key)
        local_path = os.path.join(self.temp_dir, f"{self.worker_id}_{filename}")
        
        # Download file
        logger.info(f"Downloading {s3_input_path} to {local_path}")
        self.s3.download_file(bucket, key, local_path)
        
        return local_path
    
    def upload_transcript_to_s3(self, local_transcript_path: str, s3_output_path: str):
        """
        Upload transcript to S3
        
        Args:
            local_transcript_path: Local path to transcript file
            s3_output_path: S3 path like s3://bucket/path/to/output.json
        """
        # Parse S3 path
        parsed = urlparse(s3_output_path)
        bucket = parsed.netloc
        key = parsed.path.lstrip('/')
        
        # Upload file
        logger.info(f"Uploading transcript to {s3_output_path}")
        self.s3.upload_file(local_transcript_path, bucket, key)
    
    def process_job(self, message: Dict) -> bool:
        """
        Process a single transcription job
        
        Args:
            message: SQS message containing job details
            
        Returns:
            True if successful, False if failed
        """
        try:
            # Parse message body
            body = json.loads(message['Body'])
            job_id = body.get('job_id')
            s3_input_path = body.get('s3_input_path')
            s3_output_path = body.get('s3_output_path')
            estimated_duration_seconds = body.get('estimated_duration_seconds', 300)
            priority = body.get('priority', 1)
            retry_count = body.get('retry_count', 0)
            
            logger.info(f"🎬 STARTING JOB {job_id}")
            logger.info(f"📥 Input: {s3_input_path}")
            logger.info(f"📤 Output: {s3_output_path}")
            logger.info(f"⏱️ Estimated Duration: {estimated_duration_seconds}s")
            logger.info(f"🔄 Retry Count: {retry_count}")
            
            # Download audio file
            logger.info(f"📁 Step 1: Downloading audio from S3...")
            local_audio_path = self.download_audio_from_s3(s3_input_path)
            logger.info(f"✅ Downloaded to: {local_audio_path}")
            
            try:
                # Transcribe audio
                logger.info(f"🎙️ Step 2: Starting transcription...")
                logger.info(f"📋 Audio file: {local_audio_path}")
                start_time = time.time()
                
                # Use the existing transcriber
                transcript_result = self.transcriber.transcribe_audio(local_audio_path)
                
                actual_duration = time.time() - start_time
                logger.info(f"✅ Transcription completed in {actual_duration:.2f} seconds")
                logger.info(f"📊 Generated {len(transcript_result.get('segments', []))} segments")
                
                # Create output transcript
                logger.info(f"📝 Step 3: Creating transcript output...")
                output_data = {
                    "job_id": job_id,
                    "s3_input_path": s3_input_path,
                    "s3_output_path": s3_output_path,
                    "estimated_duration_seconds": estimated_duration_seconds,
                    "actual_transcription_time_seconds": actual_duration,
                    "priority": priority,
                    "retry_count": retry_count,
                    "processed_at": datetime.utcnow().isoformat() + "Z",
                    "worker_id": self.worker_id,
                    "transcript": transcript_result
                }
                
                # Save to local file
                local_output_path = os.path.join(self.temp_dir, f"{job_id}_transcript.json")
                logger.info(f"💾 Saving transcript to: {local_output_path}")
                with open(local_output_path, 'w') as f:
                    json.dump(output_data, f, indent=2)
                
                # Upload to S3
                logger.info(f"☁️ Step 4: Uploading transcript to S3...")
                self.upload_transcript_to_s3(local_output_path, s3_output_path)
                logger.info(f"✅ Uploaded to: {s3_output_path}")
                
                # Update queue metrics
                logger.info(f"📈 Updating queue metrics...")
                self.metrics_manager.complete_job(estimated_duration_seconds)
                
                # Clean up local files
                logger.info(f"🧹 Cleaning up local files...")
                os.remove(local_audio_path)
                os.remove(local_output_path)
                
                logger.info(f"🎉 SUCCESS: Job {job_id} completed successfully!")
                return True
                
            except TranscriptionError as e:
                logger.error(f"❌ TRANSCRIPTION ERROR for job {job_id}: {e}")
                logger.error(f"🔧 This may be due to unsupported audio format or corrupted file")
                # Remove from metrics since it failed
                self.metrics_manager.remove_job(estimated_duration_seconds)
                return False
                
        except Exception as e:
            logger.error(f"💥 UNEXPECTED ERROR processing job {job_id}: {e}")
            logger.error(f"📋 Error details:", exc_info=True)
            # Try to remove from metrics
            try:
                estimated_duration = body.get('estimated_duration_seconds', 300)
                self.metrics_manager.remove_job(estimated_duration)
            except:
                pass
            return False
    
    def run(self):
        """Main worker loop"""
        logger.info(f"Transcription worker {self.worker_id} starting...")
        logger.info(f"Queue URL: {self.queue_url}")
        logger.info(f"S3 Bucket: {self.s3_bucket}")
        logger.info(f"Region: {self.region}")
        logger.info(f"Model: {self.model_name}")
        logger.info(f"GPU enabled: {self.use_gpu}")
        logger.info("Worker initialized successfully, beginning message polling...")
        
        while self.should_continue_running():
            try:
                # Receive messages from SQS
                logger.debug("Polling SQS for messages...")
                response = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    AttributeNames=['All'],
                    MaxNumberOfMessages=1,
                    MessageAttributeNames=['All'],
                    WaitTimeSeconds=20,  # Long polling
                    VisibilityTimeout=1800  # 30 minutes for transcription
                )
                
                if 'Messages' in response:
                    logger.info(f"Received {len(response['Messages'])} message(s) from queue")
                    for message in response['Messages']:
                        # Process the job
                        logger.info(f"Processing message: {message.get('MessageId', 'unknown')}")
                        success = self.process_job(message)
                        
                        if success:
                            # Delete message from queue
                            self.sqs.delete_message(
                                QueueUrl=self.queue_url,
                                ReceiptHandle=message['ReceiptHandle']
                            )
                            self.jobs_processed += 1
                            logger.info(f"Job processed successfully. Total jobs: {self.jobs_processed}")
                        else:
                            logger.error("Job processing failed, leaving message in queue for retry")
                            
                else:
                    logger.debug("No messages in queue, continuing to poll...")
                    
            except Exception as e:
                logger.error(f"Error in worker loop: {e}")
                time.sleep(5)  # Wait before retrying
        
        logger.info(f"Worker {self.worker_id} shutting down gracefully")
        logger.info(f"Total jobs processed: {self.jobs_processed}")
        
        # Shutdown the spot instance to save costs
        if os.path.exists('/var/lib/cloud/instance/sem/config_scripts_user'):
            logger.info("🔌 SPOT SHUTDOWN: Detected cloud instance, initiating shutdown in 1 minute")
            logger.info("💰 This saves GPU costs when no work is available")
            subprocess.run(["sudo", "shutdown", "-h", "+1"], check=False)
        else:
            logger.info("🖥️ Non-cloud environment detected, shutdown skipped")


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description="Transcription Worker")
    parser.add_argument("--queue-url", required=True, help="SQS queue URL")
    parser.add_argument("--s3-bucket", required=True, help="S3 bucket for metrics")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--temp-dir", default="/tmp", help="Temporary directory")
    parser.add_argument("--idle-timeout", type=int, default=5, help="Idle timeout in minutes")
    parser.add_argument("--model", default="large-v3", help="Whisper model to use")
    parser.add_argument("--cpu-only", action="store_true", help="Use CPU only (no GPU)")
    
    args = parser.parse_args()
    
    # Create and run worker
    worker = TranscriptionWorker(
        queue_url=args.queue_url,
        s3_bucket=args.s3_bucket,
        region=args.region,
        temp_dir=args.temp_dir,
        idle_threshold_minutes=args.idle_timeout,
        use_gpu=not args.cpu_only,
        model_name=args.model
    )
    
    worker.run()


if __name__ == "__main__":
    main()