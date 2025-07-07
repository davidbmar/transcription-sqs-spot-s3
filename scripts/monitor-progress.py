#!/usr/bin/env python3
"""
Progress Monitor - Watch transcription progress in real-time via S3
"""

import boto3
import json
import time
import sys
import argparse
from datetime import datetime

def load_config():
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

def format_duration(seconds):
    """Format seconds into human readable duration"""
    if seconds < 60:
        return f"{seconds:.1f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}m"
    else:
        return f"{seconds/3600:.1f}h"

def watch_job_progress(s3, bucket, job_id):
    """Watch progress for a specific job"""
    progress_key = f"progress/{job_id}/status.json"
    log_key = f"progress/{job_id}/detailed_log.txt"
    
    print(f"📊 Monitoring job: {job_id}")
    print(f"Progress file: s3://{bucket}/{progress_key}")
    print("=" * 60)
    
    last_percentage = None
    start_time = time.time()
    
    while True:
        try:
            # Get progress status
            try:
                response = s3.get_object(Bucket=bucket, Key=progress_key)
                progress_data = json.loads(response['Body'].read().decode('utf-8'))
                
                status = progress_data.get('status', 'UNKNOWN')
                message = progress_data.get('message', '')
                percentage = progress_data.get('percentage', 0)
                elapsed = progress_data.get('elapsed_seconds', 0)
                timestamp = progress_data.get('timestamp', '')
                chunk_info = progress_data.get('chunk_info', {})
                
                # Only print updates when percentage changes
                if percentage != last_percentage:
                    progress_bar = "█" * int(percentage / 2) + "░" * (50 - int(percentage / 2))
                    
                    print(f"[{timestamp[:19]}] {status}")
                    print(f"Progress: [{progress_bar}] {percentage}%")
                    print(f"Status: {message}")
                    if chunk_info:
                        print(f"Chunks: {chunk_info.get('current', 0)}/{chunk_info.get('total', 0)}")
                    print(f"Elapsed: {format_duration(elapsed)}")
                    print("-" * 60)
                    
                    last_percentage = percentage
                
                # Check if completed
                if status in ['COMPLETED', 'FAILED']:
                    print(f"🎉 Job {status}: {message}")
                    if status == 'COMPLETED':
                        print("✅ Transcription completed successfully!")
                    else:
                        print("❌ Transcription failed!")
                    break
                    
            except s3.exceptions.NoSuchKey:
                elapsed = time.time() - start_time
                print(f"⏳ Waiting for job to start... ({format_duration(elapsed)} elapsed)")
                
        except KeyboardInterrupt:
            print("\n⏹️ Monitoring stopped by user")
            break
        except Exception as e:
            print(f"Error monitoring progress: {e}")
            
        time.sleep(10)  # Check every 10 seconds

def list_active_jobs(s3, bucket):
    """List all active jobs with progress"""
    print("🔍 Scanning for active transcription jobs...")
    
    try:
        # List all progress files
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket, Prefix='progress/')
        
        jobs = []
        for page in pages:
            if 'Contents' in page:
                for obj in page['Contents']:
                    if obj['Key'].endswith('/status.json'):
                        job_id = obj['Key'].split('/')[1]
                        
                        # Get job status
                        try:
                            response = s3.get_object(Bucket=bucket, Key=obj['Key'])
                            progress_data = json.loads(response['Body'].read().decode('utf-8'))
                            
                            jobs.append({
                                'job_id': job_id,
                                'status': progress_data.get('status', 'UNKNOWN'),
                                'percentage': progress_data.get('percentage', 0),
                                'message': progress_data.get('message', ''),
                                'elapsed': progress_data.get('elapsed_seconds', 0),
                                'last_update': obj['LastModified']
                            })
                        except Exception as e:
                            print(f"Error reading progress for {job_id}: {e}")
        
        if not jobs:
            print("📭 No active transcription jobs found")
            return
            
        # Sort by last update
        jobs.sort(key=lambda x: x['last_update'], reverse=True)
        
        print(f"📊 Found {len(jobs)} transcription job(s):")
        print("=" * 80)
        
        for i, job in enumerate(jobs, 1):
            status_emoji = {
                'STARTED': '🏃',
                'DOWNLOADING': '📥',
                'TRANSCRIBING': '🎙️',
                'COMPLETED': '✅',
                'FAILED': '❌'
            }.get(job['status'], '🔄')
            
            print(f"{i}. Job ID: {job['job_id']}")
            print(f"   Status: {status_emoji} {job['status']} ({job['percentage']}%)")
            print(f"   Message: {job['message']}")
            print(f"   Elapsed: {format_duration(job['elapsed'])}")
            print(f"   Last Update: {job['last_update'].strftime('%Y-%m-%d %H:%M:%S UTC')}")
            print()
            
        return jobs
        
    except Exception as e:
        print(f"Error listing jobs: {e}")
        return []

def list_workers(s3, bucket):
    """List active workers"""
    print("👷 Scanning for active workers...")
    
    try:
        # List worker status files
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket, Prefix='workers/')
        
        workers = []
        for page in pages:
            if 'Contents' in page:
                for obj in page['Contents']:
                    if obj['Key'].endswith('/status.json'):
                        worker_id = obj['Key'].split('/')[1]
                        
                        # Get worker status
                        try:
                            response = s3.get_object(Bucket=bucket, Key=obj['Key'])
                            worker_data = json.loads(response['Body'].read().decode('utf-8'))
                            
                            workers.append({
                                'worker_id': worker_id,
                                'status': worker_data.get('status', 'UNKNOWN'),
                                'started_at': worker_data.get('started_at', ''),
                                'last_heartbeat': worker_data.get('last_heartbeat', ''),
                                'jobs_processed': worker_data.get('jobs_processed', 0),
                                'model': worker_data.get('model', ''),
                                'gpu_optimized': worker_data.get('gpu_optimized', False),
                                'last_update': obj['LastModified']
                            })
                        except Exception as e:
                            print(f"Error reading worker status for {worker_id}: {e}")
        
        if not workers:
            print("🚫 No active workers found")
            return
            
        print(f"👷 Found {len(workers)} worker(s):")
        print("=" * 80)
        
        for i, worker in enumerate(workers, 1):
            status_emoji = '🟢' if worker['status'] == 'RUNNING' else '🔴'
            gpu_icon = '🚀' if worker['gpu_optimized'] else '💻'
            
            print(f"{i}. Worker: {worker['worker_id'][:12]}...")
            print(f"   Status: {status_emoji} {worker['status']}")
            print(f"   Type: {gpu_icon} {worker['model']} ({'GPU-Optimized' if worker['gpu_optimized'] else 'Standard'})")
            print(f"   Jobs Processed: {worker['jobs_processed']}")
            print(f"   Started: {worker['started_at'][:19] if worker['started_at'] else 'Unknown'}")
            print(f"   Last Heartbeat: {worker['last_heartbeat'][:19] if worker['last_heartbeat'] else 'Unknown'}")
            print()
            
    except Exception as e:
        print(f"Error listing workers: {e}")

def main():
    parser = argparse.ArgumentParser(description='Monitor transcription progress')
    parser.add_argument('--job-id', help='Specific job ID to monitor')
    parser.add_argument('--list-jobs', action='store_true', help='List all active jobs')
    parser.add_argument('--list-workers', action='store_true', help='List all active workers')
    parser.add_argument('--bucket', help='S3 bucket (override config)')
    parser.add_argument('--region', help='AWS region (override config)')
    
    args = parser.parse_args()
    
    # Load configuration
    config = load_config()
    bucket = args.bucket or config.get('METRICS_BUCKET')
    region = args.region or config.get('AWS_REGION', 'us-east-1')
    
    if not bucket:
        print("Error: No S3 bucket specified. Use --bucket or configure METRICS_BUCKET in .env")
        sys.exit(1)
    
    # Initialize S3 client
    s3 = boto3.client('s3', region_name=region)
    
    if args.list_workers:
        list_workers(s3, bucket)
    elif args.list_jobs:
        jobs = list_active_jobs(s3, bucket)
        
        # Interactive selection
        if jobs and not args.job_id:
            try:
                choice = input("\nEnter job number to monitor (or press Enter to exit): ").strip()
                if choice and choice.isdigit():
                    job_idx = int(choice) - 1
                    if 0 <= job_idx < len(jobs):
                        job_id = jobs[job_idx]['job_id']
                        print(f"\n📊 Monitoring job: {job_id}")
                        watch_job_progress(s3, bucket, job_id)
            except KeyboardInterrupt:
                print("\nExiting...")
    elif args.job_id:
        watch_job_progress(s3, bucket, args.job_id)
    else:
        # Default: show overview
        print("📊 Transcription System Monitor")
        print("=" * 40)
        print()
        
        list_workers(s3, bucket)
        print()
        list_active_jobs(s3, bucket)
        
        print("\nOptions:")
        print("  --list-jobs      List and optionally monitor jobs")
        print("  --list-workers   List active workers")
        print("  --job-id <id>    Monitor specific job")

if __name__ == '__main__':
    main()