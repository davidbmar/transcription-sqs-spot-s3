#!/usr/bin/env python3
"""
Fast API Transcription Client - Command-line interface for S3-enhanced Fast API
Supports S3 input/output, URL input, and file upload transcription
"""

import argparse
import requests
import json
import sys
import os
import time
from pathlib import Path

def load_config():
    """Load configuration from .env file"""
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

def get_api_endpoint():
    """Get Fast API endpoint from running instances or config"""
    config = load_config()
    
    # Try to find running Fast API instance
    try:
        import boto3
        ec2 = boto3.client('ec2', region_name=config.get('AWS_REGION', 'us-east-2'))
        
        response = ec2.describe_instances(
            Filters=[
                {'Name': 'tag:Type', 'Values': ['fast-api-worker']},
                {'Name': 'instance-state-name', 'Values': ['running']}
            ]
        )
        
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                public_ip = instance.get('PublicIpAddress')
                if public_ip:
                    return f"http://{public_ip}:8000"
    except:
        pass
    
    # Fallback to environment variable or ask user
    api_endpoint = config.get('FAST_API_ENDPOINT', os.environ.get('FAST_API_ENDPOINT'))
    if not api_endpoint:
        print("❌ No running Fast API instance found. Please specify --api-endpoint")
        return None
    
    return api_endpoint

def transcribe_s3(api_endpoint, s3_input, s3_output=None, return_text=True):
    """Transcribe audio from S3 with optional S3 output"""
    url = f"{api_endpoint}/transcribe-s3"
    
    payload = {
        "s3_input_path": s3_input,
        "return_text": return_text
    }
    
    if s3_output:
        payload["s3_output_path"] = s3_output
    
    print(f"📤 Sending S3 transcription request...")
    print(f"   Input: {s3_input}")
    if s3_output:
        print(f"   Output: {s3_output}")
    
    start_time = time.time()
    
    try:
        response = requests.post(url, json=payload, timeout=1800)  # 30 min timeout
        response.raise_for_status()
        
        elapsed = time.time() - start_time
        print(f"✅ Transcription completed in {elapsed:.1f} seconds")
        
        return response.json()
        
    except requests.exceptions.Timeout:
        print("⏳ Request timed out (30 minutes) - large file may still be processing")
        return None
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        return None

def transcribe_url(api_endpoint, audio_url):
    """Transcribe audio from URL"""
    url = f"{api_endpoint}/transcribe-url"
    
    payload = {"audio_url": audio_url}
    
    print(f"📤 Sending URL transcription request...")
    print(f"   URL: {audio_url}")
    
    start_time = time.time()
    
    try:
        response = requests.post(url, json=payload, timeout=1800)
        response.raise_for_status()
        
        elapsed = time.time() - start_time
        print(f"✅ Transcription completed in {elapsed:.1f} seconds")
        
        return response.json()
        
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        return None

def transcribe_file(api_endpoint, file_path):
    """Transcribe uploaded file"""
    url = f"{api_endpoint}/transcribe"
    
    if not os.path.exists(file_path):
        print(f"❌ File not found: {file_path}")
        return None
    
    file_size = os.path.getsize(file_path) / (1024 * 1024)  # MB
    print(f"📤 Uploading file: {file_path} ({file_size:.1f}MB)")
    
    start_time = time.time()
    
    try:
        with open(file_path, 'rb') as f:
            files = {'file': f}
            response = requests.post(url, files=files, timeout=1800)
            response.raise_for_status()
        
        elapsed = time.time() - start_time
        print(f"✅ Transcription completed in {elapsed:.1f} seconds")
        
        return response.json()
        
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        return None

def main():
    parser = argparse.ArgumentParser(
        description="Fast API Transcription Client - S3-enhanced audio transcription",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # S3 to S3 transcription
  %(prog)s --s3-input s3://bucket/audio.mp3 --s3-output s3://bucket/transcript.json
  
  # S3 input, return text only
  %(prog)s --s3-input s3://bucket/audio.mp3 --no-s3-output
  
  # URL transcription
  %(prog)s --url https://example.com/podcast.mp3
  
  # File upload
  %(prog)s --file /path/to/audio.mp3
  
  # Custom API endpoint
  %(prog)s --api-endpoint http://1.2.3.4:8000 --file audio.mp3
  
  # Save output to file
  %(prog)s --s3-input s3://bucket/audio.mp3 --output-file transcript.json

Endpoints:
  /transcribe-s3   - S3 input/output (use s3:// URIs)
  /transcribe-url  - HTTP/HTTPS URLs 
  /transcribe      - File upload
  /health          - API health check
  /docs            - Interactive API documentation
        """
    )
    
    # Input options (mutually exclusive)
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument(
        "--s3-input", 
        help="S3 URI for input audio (e.g., s3://bucket/audio.mp3)"
    )
    input_group.add_argument(
        "--url",
        help="HTTP/HTTPS URL for input audio"
    )
    input_group.add_argument(
        "--file", 
        help="Local file path for input audio"
    )
    
    # Output options
    parser.add_argument(
        "--s3-output",
        help="S3 URI for output transcript (e.g., s3://bucket/transcript.json)"
    )
    parser.add_argument(
        "--output-file",
        help="Local file to save transcript JSON"
    )
    parser.add_argument(
        "--no-s3-output",
        action="store_true",
        help="Don't save to S3 (return text only)"
    )
    
    # API options
    parser.add_argument(
        "--api-endpoint",
        help="Fast API endpoint (auto-detected if not specified)"
    )
    
    # Output options
    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Quiet mode - only output transcript text"
    )
    parser.add_argument(
        "--json-output",
        action="store_true", 
        help="Output full JSON response"
    )
    
    args = parser.parse_args()
    
    # Get API endpoint
    api_endpoint = args.api_endpoint or get_api_endpoint()
    if not api_endpoint:
        sys.exit(1)
    
    if not args.quiet:
        print(f"🎤 Fast API Transcription Client")
        print(f"🔗 API Endpoint: {api_endpoint}")
        print()
    
    # Determine transcription method and call appropriate function
    result = None
    
    if args.s3_input:
        s3_output = None if args.no_s3_output else args.s3_output
        return_text = True if args.no_s3_output else bool(not args.quiet)
        result = transcribe_s3(api_endpoint, args.s3_input, s3_output, return_text)
        
    elif args.url:
        result = transcribe_url(api_endpoint, args.url)
        
    elif args.file:
        result = transcribe_file(api_endpoint, args.file)
    
    if not result:
        sys.exit(1)
    
    # Handle output
    if args.output_file:
        with open(args.output_file, 'w') as f:
            json.dump(result, f, indent=2)
        if not args.quiet:
            print(f"💾 Saved transcript to: {args.output_file}")
    
    if args.json_output:
        print(json.dumps(result, indent=2))
    elif args.quiet:
        print(result.get('text', ''))
    else:
        # Pretty print key info
        print()
        print("📝 Transcript:")
        print(result.get('text', ''))
        
        if 'chunks' in result and result['chunks']:
            print(f"\n📊 Stats: {len(result['chunks'])} chunks, {len(result.get('text', ''))} characters")
        
        if 's3_output_path' in result:
            print(f"💾 Saved to S3: {result['s3_output_path']}")

if __name__ == "__main__":
    main()