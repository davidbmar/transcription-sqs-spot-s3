#!/usr/bin/env python3
# scripts/send_to_queue.py - Send audio transcription jobs to SQS queue

import argparse
import boto3
import json
import sys
import re
import os
import uuid
from datetime import datetime
from pathlib import Path

# Add the parent directory to the Python path so we can import from src
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Load configuration from environment file
def load_config():
    config = {}
    config_file = Path(".env")
    if config_file.exists():
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    key = key.replace('export ', '').strip()
                    value = value.strip().strip('"')
                    config[key] = value
    return config

# Load configuration
CONFIG = load_config()

# Now we can import from src if needed
# For example, if you need to use the downloader:
# from src.downloader import YouTubeDownloader

def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description="Send audio transcription jobs to SQS queue for processing."
    )
    
    parser.add_argument(
        "--s3_input_path", "-i",
        type=str,
        required=True,
        help="S3 path to audio file (e.g., s3://bucket/audio/file.mp3)"
    )
    parser.add_argument(
        "--s3_output_path", "-o",
        type=str,
        required=True,
        help="S3 path for output transcript (e.g., s3://bucket/transcripts/file.json)"
    )
    parser.add_argument(
        "--estimated_duration_seconds", "-d",
        type=int,
        default=300,
        help="Estimated audio duration in seconds (default: 300)"
    )
    parser.add_argument(
        "--priority", "-p",
        type=int,
        default=1,
        choices=[1, 2, 3, 4, 5],
        help="Job priority (1=highest, 5=lowest, default: 1)"
    )
    parser.add_argument(
        "--queue_url", "-q",
        type=str,
        default=CONFIG.get('QUEUE_URL', os.environ.get('QUEUE_URL', '')),
        help="URL of the SQS queue (defaults to config file value)"
    )
    parser.add_argument(
        "--region", "-r",
        type=str,
        default=CONFIG.get('AWS_REGION', os.environ.get('AWS_REGION', 'us-east-2')),
        help=f"AWS region for SQS (Default: {CONFIG.get('AWS_REGION', 'us-east-2')})"
    )
    return parser.parse_args()

def validate_s3_path(s3_path):
    """Validate that the path is a valid S3 path"""
    s3_pattern = r'^s3://[a-zA-Z0-9._-]+/.*$'
    match = re.match(s3_pattern, s3_path)
    if not match:
        return False
    return True

def main():
    """Main entry point"""
    args = parse_arguments()
    
    # Validate S3 paths
    if not validate_s3_path(args.s3_input_path):
        print(f"Error: '{args.s3_input_path}' is not a valid S3 path")
        sys.exit(1)
    
    if not validate_s3_path(args.s3_output_path):
        print(f"Error: '{args.s3_output_path}' is not a valid S3 path")
        sys.exit(1)
    
    try:
        # Initialize SQS client
        sqs = boto3.client('sqs', region_name=args.region)
        
        # Create message body with new structure
        message = {
            "job_id": str(uuid.uuid4()),
            "s3_input_path": args.s3_input_path,
            "s3_output_path": args.s3_output_path,
            "estimated_duration_seconds": args.estimated_duration_seconds,
            "priority": args.priority,
            "retry_count": 0,
            "submitted_at": datetime.utcnow().isoformat() + "Z"
        }
            
        message_body = json.dumps(message)
        
        # Send message to SQS queue
        response = sqs.send_message(
            QueueUrl=args.queue_url,
            MessageBody=message_body
        )
        
        print(f"Transcription job sent successfully!")
        print(f"Job ID: {message['job_id']}")
        print(f"S3 Input Path: {args.s3_input_path}")
        print(f"S3 Output Path: {args.s3_output_path}")
        print(f"Estimated Duration: {args.estimated_duration_seconds} seconds")
        print(f"Priority: {args.priority}")
        print(f"Message ID: {response['MessageId']}")
        print(f"Queue URL: {args.queue_url}")
        
    except Exception as e:
        print(f"Error sending message: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
