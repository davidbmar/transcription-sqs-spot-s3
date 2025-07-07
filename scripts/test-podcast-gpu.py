#!/usr/bin/env python3
"""
Simple GPU Podcast Test - 81 minute episode
"""

import boto3
import json
import time
import subprocess
from datetime import datetime

def load_config():
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

def main():
    print("🎯 GPU PODCAST PERFORMANCE TEST")
    print("Testing 81-minute My First Million episode")
    print("=" * 50)
    
    config = load_config()
    
    # Initialize AWS clients
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
    
    # Launch GPU worker
    print("\n🚀 Launching GPU worker...")
    result = subprocess.run("./scripts/launch-spot-worker.sh", shell=True, capture_output=True, text=True)
    
    instance_id = None
    if result.returncode == 0:
        for line in result.stdout.split('\n'):
            if "spot instance launched:" in line.lower():
                instance_id = line.split(': ')[1].strip()
                print(f"✅ GPU worker launched: {instance_id}")
                break
    
    if not instance_id:
        print("❌ Failed to launch GPU worker")
        return
    
    try:
        # Wait for initialization
        print("⏳ Waiting 6 minutes for GPU worker initialization...")
        time.sleep(360)
        
        # Send podcast job
        job_id = f"gpu_podcast_test_{int(time.time())}"
        s3_input_path = f"s3://{config['AUDIO_BUCKET']}/integration-test-new/mfm-episode-723.mp3"
        output_key = f"benchmarks/podcast/gpu/{job_id}_transcript.json"
        s3_output_path = f"s3://{config['METRICS_BUCKET']}/{output_key}"
        
        message_body = {
            "job_id": job_id,
            "s3_input_path": s3_input_path,
            "s3_output_path": s3_output_path,
            "estimated_duration_seconds": 4860,
            "priority": 1,
            "retry_count": 0,
            "submitted_at": datetime.now().isoformat() + "Z"
        }
        
        print(f"📤 Sending podcast job: {job_id}")
        sqs.send_message(QueueUrl=config['QUEUE_URL'], MessageBody=json.dumps(message_body))
        
        # Monitor transcription with real-time progress
        start_time = time.time()
        print("📊 Monitoring transcription progress...")
        print(f"Progress URL: s3://{config['METRICS_BUCKET']}/progress/{job_id}/")
        print("\nTo monitor in another terminal, run:")
        print(f"  python3 scripts/monitor-progress.py --job-id {job_id}")
        print("=" * 60)
        
        last_percentage = None
        while (time.time() - start_time) < 7200:  # 2 hour timeout
            # Check if transcription is complete first
            try:
                s3.head_object(Bucket=config['METRICS_BUCKET'], Key=output_key)
                
                # Get result
                response = s3.get_object(Bucket=config['METRICS_BUCKET'], Key=output_key)
                result_data = json.loads(response['Body'].read().decode('utf-8'))
                
                # Calculate metrics
                total_time = time.time() - start_time
                transcription_time = result_data.get('actual_transcription_time_seconds', 0)
                audio_duration = 4860  # 81 minutes
                
                print(f"\n🎉 SUCCESS! Podcast transcription completed!")
                print("=" * 50)
                print(f"Audio duration: {audio_duration} seconds (81 minutes)")
                print(f"Transcription time: {transcription_time:.1f} seconds ({transcription_time/60:.1f} minutes)")
                print(f"Total wall time: {total_time:.1f} seconds ({total_time/60:.1f} minutes)")
                print(f"Real-time factor: {transcription_time/audio_duration:.3f}")
                print(f"Processing speed: {audio_duration/transcription_time:.1f}x realtime")
                print(f"Segments generated: {len(result_data.get('transcript', {}).get('segments', []))}")
                
                # Performance grade
                speedup = audio_duration / transcription_time
                if speedup > 25:
                    grade = "🚀 EXCELLENT"
                elif speedup > 10:
                    grade = "✅ VERY GOOD"
                elif speedup > 5:
                    grade = "✅ GOOD"
                elif speedup > 2:
                    grade = "⚠️ FAIR"
                else:
                    grade = "❌ POOR"
                
                print(f"Performance grade: {grade}")
                break
                
            except:
                # Check progress status
                try:
                    progress_key = f"progress/{job_id}/status.json"
                    response = s3.get_object(Bucket=config['METRICS_BUCKET'], Key=progress_key)
                    progress_data = json.loads(response['Body'].read().decode('utf-8'))
                    
                    status = progress_data.get('status', 'UNKNOWN')
                    percentage = progress_data.get('percentage', 0)
                    message = progress_data.get('message', '')
                    elapsed = progress_data.get('elapsed_seconds', 0)
                    
                    # Only print updates when percentage changes
                    if percentage != last_percentage:
                        progress_bar = "█" * int(percentage / 2) + "░" * (50 - int(percentage / 2))
                        print(f"[{status}] [{progress_bar}] {percentage}% - {message}")
                        last_percentage = percentage
                    
                    if status == 'FAILED':
                        print("❌ Transcription failed!")
                        break
                        
                except:
                    elapsed = time.time() - start_time
                    print(f"⏳ Starting transcription... ({elapsed/60:.1f} minutes elapsed)")
                
                time.sleep(30)  # Check every 30 seconds
        else:
            print("❌ Transcription timed out after 2 hours")
            
    finally:
        # Cleanup
        if instance_id:
            print(f"\n🔌 Terminating worker: {instance_id}")
            ec2.terminate_instances(InstanceIds=[instance_id])

if __name__ == "__main__":
    main()