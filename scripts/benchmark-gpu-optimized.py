#!/usr/bin/env python3
"""
Optimized GPU vs CPU Benchmark - Test the improved performance
"""

import boto3
import json
import time
import subprocess
from datetime import datetime
import os

def load_config():
    """Load configuration from .env file"""
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

def send_test_job(sqs, queue_url, test_file, job_prefix, config):
    """Send a single test job"""
    job_id = f"{job_prefix}_optimized_test_{int(time.time())}"
    s3_input_path = f"s3://{config['AUDIO_BUCKET']}/{test_file}"
    output_key = f"benchmarks/optimized/{job_prefix}/{job_id}_transcript.json"
    s3_output_path = f"s3://{config['METRICS_BUCKET']}/{output_key}"
    
    message_body = {
        "job_id": job_id,
        "s3_input_path": s3_input_path,
        "s3_output_path": s3_output_path,
        "estimated_duration_seconds": 60,
        "priority": 1,
        "retry_count": 0,
        "submitted_at": datetime.now().isoformat() + "Z"
    }
    
    sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message_body))
    print(f"📤 Sent {job_prefix.upper()} job: {job_id}")
    return job_id, output_key

def wait_for_result(s3, bucket, output_key, timeout=300):
    """Wait for transcription result"""
    start_time = time.time()
    while (time.time() - start_time) < timeout:
        try:
            response = s3.head_object(Bucket=bucket, Key=output_key)
            print(f"✅ Job completed: {output_key.split('/')[-1]}")
            
            # Get the result
            result = s3.get_object(Bucket=bucket, Key=output_key)
            content = result['Body'].read().decode('utf-8')
            data = json.loads(content)
            return data
        except:
            time.sleep(10)
    
    print(f"❌ Job timed out: {output_key}")
    return None

def launch_optimized_gpu_worker(config):
    """Launch GPU worker with optimizations"""
    print("\n🚀 LAUNCHING OPTIMIZED GPU WORKER")
    print("=" * 50)
    
    result = subprocess.run("./scripts/launch-spot-worker.sh", shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        for line in result.stdout.split('\n'):
            if "spot instance launched:" in line.lower():
                instance_id = line.split(': ')[1].strip()
                print(f"✅ GPU worker launched: {instance_id}")
                return instance_id
    
    print(f"❌ Failed to launch GPU worker")
    print(f"Error: {result.stderr}")
    return None

def test_single_file_performance(config):
    """Test performance with a single file"""
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
    
    test_file = "integration-test/00060-00120.webm"  # 60 seconds of audio
    
    print("\n🎯 SINGLE FILE GPU OPTIMIZATION TEST")
    print("=" * 60)
    print(f"Test file: {test_file} (60 seconds of audio)")
    
    # Launch optimized GPU worker
    instance_id = launch_optimized_gpu_worker(config)
    if not instance_id:
        return None
    
    try:
        # Wait for worker to initialize
        print("⏳ Waiting 4 minutes for GPU worker initialization...")
        time.sleep(240)
        
        # Send test job
        start_time = time.time()
        job_id, output_key = send_test_job(sqs, config['QUEUE_URL'], test_file, "gpu", config)
        
        # Wait for result
        result = wait_for_result(s3, config['METRICS_BUCKET'], output_key)
        end_time = time.time()
        
        if result:
            total_time = end_time - start_time
            transcription_time = result.get('actual_transcription_time_seconds', 0)
            audio_duration = 60  # seconds
            
            # Calculate performance metrics
            rtf = transcription_time / audio_duration
            speedup = audio_duration / transcription_time
            
            print(f"\n📊 OPTIMIZED GPU PERFORMANCE RESULTS")
            print("=" * 50)
            print(f"Audio duration: {audio_duration} seconds")
            print(f"Transcription time: {transcription_time:.2f} seconds")
            print(f"Total wall time: {total_time:.2f} seconds")
            print(f"Real-time factor: {rtf:.3f}")
            print(f"Speed: {speedup:.1f}x realtime")
            print(f"Segments: {len(result.get('transcript', {}).get('segments', []))}")
            
            # Expected performance check
            print(f"\n💡 PERFORMANCE ANALYSIS:")
            if speedup > 60:
                print(f"🎉 EXCELLENT! {speedup:.0f}x realtime (industry leading)")
            elif speedup > 25:
                print(f"✅ VERY GOOD! {speedup:.0f}x realtime (excellent performance)")
            elif speedup > 10:
                print(f"✅ GOOD! {speedup:.0f}x realtime (solid GPU acceleration)")
            elif speedup > 3:
                print(f"⚠️  FAIR: {speedup:.0f}x realtime (room for improvement)")
            else:
                print(f"❌ POOR: {speedup:.0f}x realtime (GPU not optimized)")
            
            print(f"\nExpected targets:")
            print(f"  - Minimum: 10x realtime (6 seconds for 60s audio)")
            print(f"  - Good: 25x realtime (2.4 seconds for 60s audio)")
            print(f"  - Excellent: 60x realtime (1 second for 60s audio)")
            
            return {
                "transcription_time": transcription_time,
                "rtf": rtf,
                "speedup": speedup,
                "result": result
            }
        
        return None
        
    finally:
        # Cleanup - terminate worker
        print(f"\n🔌 Terminating GPU worker: {instance_id}")
        ec2.terminate_instances(InstanceIds=[instance_id])

def main():
    print("🚀 GPU OPTIMIZATION PERFORMANCE TEST")
    print("Testing optimized GPU transcription performance")
    print("=" * 60)
    
    # Load configuration
    config = load_config()
    
    # Test single file performance
    result = test_single_file_performance(config)
    
    if result:
        print(f"\n🎉 TEST COMPLETE!")
        print(f"Optimized GPU achieved {result['speedup']:.1f}x realtime performance")
        
        if result['speedup'] > 25:
            print("✅ GPU optimization successful - achieved target performance!")
        else:
            print("⚠️  GPU optimization needs further tuning")
    else:
        print("\n❌ Test failed - check logs for issues")

if __name__ == "__main__":
    main()