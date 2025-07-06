#!/usr/bin/python3
#worker.py - Main Worker Implementation
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
import shutil
import socket
import subprocess
from datetime import datetime, timedelta
from src.job_tracker import JobTracker, JobState
from src.downloader import YouTubeDownloader, DownloadError
from src.transcriber import Transcriber, TranscriptionError
from src.scanner import PhraseScanner

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Define constants
DEFAULT_TEMP_DIR = "./temp"
DEFAULT_BATCH_SIZE = 5
DEFAULT_S3_BUCKET = "youtube-transcripts"
DEFAULT_POLL_INTERVAL = 60  # seconds

class Worker:
    """Main worker that processes YouTube videos from SQS queue"""

    def __init__(self,
                 phrase="hustle",
                 temp_dir=DEFAULT_TEMP_DIR,
                 queue_url=None,
                 region="us-east-1",
                 s3_bucket=DEFAULT_S3_BUCKET,
                 batch_size=DEFAULT_BATCH_SIZE,
                 poll_interval=DEFAULT_POLL_INTERVAL,
                 use_gpu=True):
        """Initialize the worker"""
        self.phrase = phrase
        self.temp_dir = temp_dir
        self.queue_url = queue_url
        self.region = region
        self.s3_bucket = s3_bucket
        self.batch_size = batch_size
        self.poll_interval = poll_interval
        self.use_gpu = use_gpu

        # Generate a unique worker ID
        self.worker_id = f"worker-{uuid.uuid4()}"
        logger.info(f"Worker initialized with ID: {self.worker_id}")

        # Initialize AWS clients
        self.s3 = boto3.client('s3', region_name=region)
        self.sqs = boto3.client('sqs', region_name=region) if queue_url else None

        # Initialize components
        self.job_tracker = JobTracker(s3_bucket, region)
        self.downloader = YouTubeDownloader(temp_dir)

        # Initialize transcriber with correct parameters
        device = "cuda" if use_gpu else "cpu"
        self.transcriber = Transcriber(
            model_name="small.en",
            device=device,
            chunk_size=30,
            s3_bucket=s3_bucket,
            region=region
        )

        # Ensure temp directory exists
        os.makedirs(temp_dir, exist_ok=True)

        # Set up termination handling
        self.setup_termination_handler()

        # Track jobs processed
        self.jobs_processed = 0

        # Ensure S3 bucket exists
        self.ensure_bucket_exists()

    def ensure_bucket_exists(self):
        """Ensure the S3 bucket exists"""
        try:
            self.s3.head_bucket(Bucket=self.s3_bucket)
            logger.info(f"S3 bucket '{self.s3_bucket}' exists")
        except self.s3.exceptions.ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == '404':
                logger.info(f"Creating S3 bucket '{self.s3_bucket}'")
                try:
                    if self.region == 'us-east-1':
                        self.s3.create_bucket(Bucket=self.s3_bucket)
                    else:
                        self.s3.create_bucket(
                            Bucket=self.s3_bucket,
                            CreateBucketConfiguration={'LocationConstraint': self.region}
                        )

                    # Create folder structure
                    for folder in ["jobs/queued", "jobs/processing", "jobs/completed", "jobs/failed",
                                   "transcripts", "results", "workers"]:
                        self.s3.put_object(
                            Bucket=self.s3_bucket,
                            Key=f"{folder}/",
                            Body=""
                        )

                    logger.info(f"Created S3 bucket and folders")
                except Exception as e:
                    logger.error(f"Error creating S3 bucket: {str(e)}")
                    raise
            else:
                logger.error(f"Error checking S3 bucket: {str(e)}")
                raise

    def setup_termination_handler(self):
        """Set up handler for graceful termination"""
        def handler(signum, frame):
            logger.warning(f"Received termination signal ({signum}), cleaning up...")
            self.cleanup()
            sys.exit(0)

        # Handle common termination signals
        signal.signal(signal.SIGTERM, handler)
        signal.signal(signal.SIGINT, handler)

        # Start a thread to check for spot termination notice
        def check_termination():
            while True:
                try:
                    response = requests.get(
                        "http://169.254.169.254/latest/meta-data/spot/termination-time",
                        timeout=2
                    )
                    if response.status_code == 200:
                        logger.warning("Spot termination notice detected")
                        handler(None, None)
                except:
                    pass  # Ignore errors, might not be running on EC2

                time.sleep(5)

        try:
            import requests
            threading.Thread(target=check_termination, daemon=True).start()
        except ImportError:
            logger.warning("Requests library not found, spot termination detection disabled")

    def update_heartbeat(self):
        """Update worker heartbeat in S3"""
        heartbeat = {
            "worker_id": self.worker_id,
            "hostname": socket.gethostname(),
            "ip_address": socket.gethostbyname(socket.gethostname()),
            "last_heartbeat": datetime.now().isoformat(),
            "status": "active",
            "jobs_processed": self.jobs_processed,
            "phrase": self.phrase,
            "use_gpu": self.use_gpu
        }

        try:
            self.s3.put_object(
                Body=json.dumps(heartbeat),
                Bucket=self.s3_bucket,
                Key=f"workers/{self.worker_id}.json",
                ContentType="application/json"
            )
            return True
        except Exception as e:
            logger.error(f"Error updating heartbeat: {str(e)}")
            return False

    def start(self):
        """Start the worker's main loop"""
        logger.info(f"Starting worker with poll interval of {self.poll_interval}s")

        # Create health check file for Docker health check
        health_file = '/app/health_check.txt'
        try:
            with open(health_file, 'w') as f:
                f.write(f"Started at {datetime.now().isoformat()}")
        except:
            logger.warning("Could not create health check file")

        while True:
            try:
                # Update health check file
                try:
                    with open(health_file, 'w') as f:
                        f.write(f"Heartbeat at {datetime.now().isoformat()}")
                except:
                    pass

                # 1. Update heartbeat
                self.update_heartbeat()

                # 2. Check for and recover abandoned jobs
                recovered = self.job_tracker.recover_abandoned_jobs()
                if recovered > 0:
                    logger.info(f"Recovered {recovered} abandoned jobs")

                # 3. Process jobs from queue
                self.process_batch()

                # 4. Sleep before next poll
                time.sleep(self.poll_interval)

            except Exception as e:
                logger.error(f"Error in main loop: {str(e)}")
                time.sleep(self.poll_interval)

    def process_batch(self):
        """Process a batch of videos from the SQS queue"""
        if not self.sqs or not self.queue_url:
            logger.error("SQS client or queue URL not configured")
            return

        processed_count = 0

        while processed_count < self.batch_size:

            # Check queue depth
            try:
                response = self.sqs.get_queue_attributes(
                    QueueUrl=self.queue_url,
                    AttributeNames=['ApproximateNumberOfMessages']
                )
                queue_depth = int(response['Attributes'].get('ApproximateNumberOfMessages', '0'))
                logger.info(f"Queue depth: {queue_depth} messages")

                # Add this new code here
                attr_response = self.sqs.get_queue_attributes(
                    QueueUrl=self.queue_url,
                    AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']
                )
                visible = int(attr_response['Attributes'].get('ApproximateNumberOfMessages', '0'))
                not_visible = int(attr_response['Attributes'].get('ApproximateNumberOfMessagesNotVisible', '0'))
                logger.info(f"Queue status: {visible} visible messages, {not_visible} in-flight messages")

                if queue_depth == 0:
                    logger.info("Queue is empty")
                    break
            except Exception as e:
                logger.error(f"Error checking queue depth: {str(e)}")
                break


            # Get message from queue (don't delete yet)
            try:
                response = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    AttributeNames=['All'],
                    MaxNumberOfMessages=1,
                    MessageAttributeNames=['All'],
                    WaitTimeSeconds=5,
                    VisibilityTimeout=600  # 10 minutes
                )

                logger.info(f"SQS response keys: {response.keys()}")
                # Add after receive_message call
                logger.info(f"SQS response keys: {response.keys()}")
                if 'Messages' not in response:
                    logger.info("No messages available in response")
                    # Check if queue is truly empty or if messages are in flight
                    try:
                        attr_response = self.sqs.get_queue_attributes(
                            QueueUrl=self.queue_url,
                            AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']
                        )
                        visible = int(attr_response['Attributes'].get('ApproximateNumberOfMessages', '0'))
                        not_visible = int(attr_response['Attributes'].get('ApproximateNumberOfMessagesNotVisible', '0'))
                        logger.info(f"Queue status: {visible} visible messages, {not_visible} in-flight messages")
                    except Exception as e:
                        logger.error(f"Error checking detailed queue status: {str(e)}")
                    break

                message = response['Messages'][0]
                receipt_handle = message['ReceiptHandle']
                job_id = message.get('MessageId', f"job-{uuid.uuid4()}")

                try:
                    # Parse message body
                    body = json.loads(message['Body'])
                    youtube_url = body.get('youtube_url')
                    custom_phrase = body.get('phrase', self.phrase)

                    if not youtube_url:
                        logger.error("Message does not contain a YouTube URL")
                        self.sqs.delete_message(
                            QueueUrl=self.queue_url,
                            ReceiptHandle=receipt_handle
                        )
                        continue

                    # Extract video ID
                    video_id = self.downloader.extract_video_id(youtube_url)

                    ## Check if already processed
                    #if self.job_exists(video_id):
                    #    logger.info(f"Video {video_id} already processed, skipping")
                    #    self.sqs.delete_message(
                    #        QueueUrl=self.queue_url,
                    #        ReceiptHandle=receipt_handle
                    #    )
                    #    continue

                    # Create job in tracker
                    self.job_tracker.create_job(
                        job_id=job_id,
                        video_id=video_id,
                        youtube_url=youtube_url,
                        phrase=custom_phrase
                    )

                    # Start processing the job
                    self.job_tracker.start_processing(job_id, self.worker_id)

                    # Process the video
                    logger.info(f"Processing video {video_id} (job {job_id}) with phrase '{custom_phrase}'")
                    result = self.process_video(job_id, youtube_url, custom_phrase, video_id)

                    # Mark job as completed
                    if result:
                        self.job_tracker.complete_job(job_id)

                        # Delete from queue
                        self.sqs.delete_message(
                            QueueUrl=self.queue_url,
                            ReceiptHandle=receipt_handle
                        )

                        processed_count += 1
                        self.jobs_processed += 1

                except Exception as e:
                    logger.error(f"Error processing job {job_id}: {str(e)}")
                    self.job_tracker.fail_job(job_id, str(e))

                    # Delete from queue
                    self.sqs.delete_message(
                        QueueUrl=self.queue_url,
                        ReceiptHandle=receipt_handle
                    )

            except Exception as e:
                logger.error(f"Error receiving message: {str(e)}")
                break

        logger.info(f"Processed {processed_count} videos in this batch")

    def job_exists(self, video_id):
        """Check if a job already exists for this video"""
        try:
            # Check for results
            prefix = f"results/{video_id}/"
            response = self.s3.list_objects_v2(
                Bucket=self.s3_bucket,
                Prefix=prefix,
                MaxKeys=1
            )
            return 'Contents' in response and len(response['Contents']) > 0
        except Exception as e:
            logger.error(f"Error checking if job exists: {str(e)}")
            return False

    def process_video(self, job_id, youtube_url, phrase, video_id):
        """Process a single video"""
        # Create a video-specific temp directory
        video_temp_dir = os.path.join(self.temp_dir, video_id)
        os.makedirs(video_temp_dir, exist_ok=True)

        try:
            # Step 1: Download audio
            self.job_tracker.update_progress(job_id, completed_chunks=0, total_chunks=5)
            logger.info(f"Downloading audio from {youtube_url}")

            audio_mp4 = self.downloader.download(youtube_url, video_temp_dir)
            self.job_tracker.update_progress(job_id, completed_chunks=1)

            # Step 2: Convert to WAV
            logger.info("Converting audio to WAV")
            audio_wav = self.downloader.convert_to_wav(audio_mp4, video_temp_dir)
            self.job_tracker.update_progress(job_id, completed_chunks=2)

            # Step 3: Segment audio and transcribe
            # Using the Transcriber's methods directly - it handles segmentation internally
            logger.info("Transcribing audio")

            # Check if we can resume transcription
            transcription = self.transcriber.resume_transcription(
                audio_file=audio_wav,
                job_id=job_id,
                job_tracker=self.job_tracker,
                video_id=video_id
            )

            # Extract segments to text files for scanning
            # We'll save each segment to a separate text file
            segments_dir = os.path.join(video_temp_dir, "segments")
            os.makedirs(segments_dir, exist_ok=True)

            transcript_files = []
            for i, segment in enumerate(transcription.get("segments", [])):
                txt_file = os.path.join(segments_dir, f"segment_{i:03d}.txt")
                with open(txt_file, "w", encoding="utf-8") as f:
                    f.write(segment.get("text", ""))
                transcript_files.append(txt_file)

            # Step 4: Scan transcripts for the phrase
            logger.info(f"Scanning transcripts for phrase '{phrase}'")
            scanner = PhraseScanner(phrase)
            stats = scanner.scan_transcripts(transcript_files)

            # Add video metadata
            stats["video_id"] = video_id
            stats["youtube_url"] = youtube_url
            stats["job_id"] = job_id
            stats["phrase"] = phrase
            stats["processed_at"] = datetime.now().isoformat()

            # Save results to S3
            self.save_results(stats, video_id)

            # Clean up
            logger.info(f"Completed processing video {video_id}")

            return stats

        except Exception as e:
            logger.error(f"Error processing video {video_id}: {str(e)}")
            raise
        finally:
            # Clean up temp directory to save space
            try:
                shutil.rmtree(video_temp_dir)
            except:
                pass

    def upload_transcription(self, txt_file, video_id):
        """Upload a transcription file to S3"""
        segment_name = os.path.basename(txt_file)
        s3_key = f"transcripts/{video_id}/{segment_name}"

        try:
            with open(txt_file, 'rb') as f:
                self.s3.put_object(
                    Body=f.read(),
                    Bucket=self.s3_bucket,
                    Key=s3_key,
                    ContentType="text/plain"
                )
            return True
        except Exception as e:
            logger.error(f"Error uploading to S3: {str(e)}")
            return False

    def save_results(self, results, video_id):
        """Save analysis results to S3"""
        # Create a unique results file with timestamp
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        s3_key = f"results/{video_id}/{timestamp}-results.json"

        try:
            # Convert results to JSON
            results_json = json.dumps(results, indent=2)

            # Upload to S3
            self.s3.put_object(
                Body=results_json,
                Bucket=self.s3_bucket,
                Key=s3_key,
                ContentType="application/json"
            )

            # Update the master video list
            self.update_video_list(video_id)

            logger.info(f"Results saved to s3://{self.s3_bucket}/{s3_key}")
            return True
        except Exception as e:
            logger.error(f"Error saving results to S3: {str(e)}")
            return False

    def get_video_title(self, video_id):
        """Get the title of a YouTube video using yt-dlp"""
        logger.info(f"Attempting to get title for video {video_id}")
        try:
            # Try to get video title using yt-dlp
            cmd = ["yt-dlp", "--get-title", f"https://www.youtube.com/watch?v={video_id}"]
            result = subprocess.run(cmd, capture_output=True, text=True)

            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()

            # Fallback to a generic title if yt-dlp fails
            return f"YouTube Video {video_id}"
        except Exception as e:
            logger.error(f"Error getting video title: {str(e)}")
            return f"YouTube Video {video_id}"

    def update_video_list(self, video_id):
        """Update the youtube_transcriber_2.json file with the new video ID and metadata"""
        logger.info(f"Updating youtube_transcriber_2.json with video {video_id}")
        video_list_key = "youtube_transcriber_2.json"

        try:
            # Try to get the existing video list
            try:
                response = self.s3.get_object(Bucket=self.s3_bucket, Key=video_list_key)
                video_list = json.loads(response['Body'].read().decode('utf-8'))
                logger.info(f"Retrieved existing video list with {len(video_list['videos'])} videos")
            except self.s3.exceptions.NoSuchKey:
                # If the file doesn't exist yet, create an empty structure
                logger.info("No existing video list found, creating new one")
                video_list = {"videos": []}

            # Get video title from YouTube
            video_title = self.get_video_title(video_id)

            # Check if video ID is already in the list
            existing_video = next((item for item in video_list["videos"] if item["id"] == video_id), None)

            if not existing_video:
                # Add the new video with metadata
                new_video = {
                    "id": video_id,
                    "title": video_title,
                    "processed_at": datetime.now().isoformat(),
                    "thumbnail": f"https://img.youtube.com/vi/{video_id}/mqdefault.jpg"
                }

                video_list["videos"].append(new_video)

                # Sort the list by processed date (newest first)
                video_list["videos"].sort(key=lambda x: x.get("processed_at", ""), reverse=True)

                # Convert to JSON and upload back to S3
                video_list_json = json.dumps(video_list, indent=2)
                self.s3.put_object(
                    Body=video_list_json,
                    Bucket=self.s3_bucket,
                    Key=video_list_key,
                    ContentType="application/json"
                )
                logger.info(f"Added video {video_id} to youtube_transcriber_2.json (total: {len(video_list['videos'])})")
            else:
                logger.info(f"Video {video_id} already in youtube_transcriber_2.json")

            return True
        except Exception as e:
            logger.error(f"Error updating video list: {str(e)}")
            return False

    def cleanup(self):
        """Clean up resources before shutdown"""
        logger.info("Cleaning up worker resources")

        try:
            # Update heartbeat with inactive status
            heartbeat = {
                "worker_id": self.worker_id,
                "hostname": socket.gethostname(),
                "last_heartbeat": datetime.now().isoformat(),
                "status": "shutdown",
                "jobs_processed": self.jobs_processed
            }

            self.s3.put_object(
                Body=json.dumps(heartbeat),
                Bucket=self.s3_bucket,
                Key=f"workers/{self.worker_id}.json",
                ContentType="application/json"
            )
        except:
            pass


def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description="Process YouTube videos from an SQS queue, transcribe them, and scan for phrases."
    )
    parser.add_argument(
        "--phrase", "-p",
        type=str,
        default="hustle",
        help="The phrase to search for (Default: 'hustle')"
    )
    parser.add_argument(
        "--temp_dir", "-t",
        type=str,
        default=DEFAULT_TEMP_DIR,
        help=f"Path to the temporary directory (Default: '{DEFAULT_TEMP_DIR}')"
    )
    parser.add_argument(
        "--queue_url", "-q",
        type=str,
        required=True,
        help="URL of the SQS queue to pull YouTube URLs from"
    )
    parser.add_argument(
        "--region", "-r",
        type=str,
        default="us-east-1",
        help="AWS region for AWS services. (Default: 'us-east-1')"
    )
    parser.add_argument(
        "--s3_bucket", "-b",
        type=str,
        default=DEFAULT_S3_BUCKET,
        help=f"S3 bucket to store transcriptions and results. (Default: '{DEFAULT_S3_BUCKET}')"
    )
    parser.add_argument(
        "--batch_size", "-n",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Number of videos to process in one batch. (Default: {DEFAULT_BATCH_SIZE})"
    )
    parser.add_argument(
        "--poll_interval", "-i",
        type=int,
        default=DEFAULT_POLL_INTERVAL,
        help=f"Polling interval in seconds. (Default: {DEFAULT_POLL_INTERVAL})"
    )
    parser.add_argument(
        "--cpu",
        action="store_true",
        help="Use CPU instead of GPU for transcription."
    )
    return parser.parse_args()


def main():
    """Main entry point"""
    args = parse_arguments()

    # Initialize worker
    worker = Worker(
        phrase=args.phrase,
        temp_dir=args.temp_dir,
        queue_url=args.queue_url,
        region=args.region,
        s3_bucket=args.s3_bucket,
        batch_size=args.batch_size,
        poll_interval=args.poll_interval,
        use_gpu=not args.cpu
    )

    # Start worker
    worker.start()


if __name__ == "__main__":
    main()
