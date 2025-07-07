#!/usr/bin/env python3
"""
Benchmark Our Transcription System - CPU vs GPU
Uses our actual SQS queue and transcription worker system
"""

import boto3
import json
import time
import uuid
from datetime import datetime
import subprocess

def load_config():
    """Load configuration from .env file"""
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

def send_transcription_job(sqs, queue_url, s3_input_path, s3_output_path, job_id):
    """Send a transcription job to the queue"""
    message_body = {
        "job_id": job_id,
        "s3_input_path": s3_input_path,
        "s3_output_path": s3_output_path,
        "estimated_duration_seconds": 60,
        "priority": 1,
        "retry_count": 0,
        "submitted_at": datetime.utcnow().isoformat() + "Z"
    }
    
    response = sqs.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(message_body)
    )
    
    print(f"📤 Sent job {job_id} to queue")
    return response

def check_transcription_complete(s3, bucket, output_key):
    """Check if transcription is complete by checking S3"""
    try:
        response = s3.head_object(Bucket=bucket, Key=output_key)
        return True
    except:
        return False

def get_transcription_result(s3, bucket, output_key):
    """Get transcription result from S3"""
    try:
        response = s3.get_object(Bucket=bucket, Key=output_key)
        content = response['Body'].read().decode('utf-8')
        return json.loads(content)
    except Exception as e:
        print(f"Error getting result: {e}")
        return None

def wait_for_completion(s3, bucket, output_keys, timeout=600):
    """Wait for all transcriptions to complete"""
    start_time = time.time()
    completed = set()
    
    while len(completed) < len(output_keys) and (time.time() - start_time) < timeout:
        for key in output_keys:
            if key not in completed and check_transcription_complete(s3, bucket, key):
                completed.add(key)
                print(f"✅ Completed: {key}")
        
        if len(completed) < len(output_keys):
            print(f"⏳ Waiting... {len(completed)}/{len(output_keys)} complete")
            time.sleep(10)
    
    return len(completed) == len(output_keys)

def launch_worker(mode="cpu"):
    """Launch a transcription worker in CPU or GPU mode"""
    print(f"🚀 Launching {mode.upper()} worker...")
    
    if mode == "gpu":
        # Launch with GPU-enabled worker
        cmd = "./scripts/launch-spot-worker.sh"
    else:
        # Launch with CPU-only worker
        cmd = "./scripts/launch-spot-worker-cpu.sh"
    
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        # Extract instance ID from output
        output_lines = result.stdout.split('\n')
        for line in output_lines:
            if "spot instance launched:" in line:
                instance_id = line.split(': ')[1]
                print(f"✅ {mode.upper()} worker launched: {instance_id}")
                return instance_id
    
    print(f"❌ Failed to launch {mode} worker")
    print(f"Error output: {result.stderr}")
    return None

def benchmark_mode(mode, config):
    """Benchmark transcription in CPU or GPU mode"""
    print(f"\n🎯 BENCHMARKING {mode.upper()} MODE")
    print("=" * 60)
    
    # Initialize AWS clients
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    
    queue_url = config['QUEUE_URL']
    metrics_bucket = config['METRICS_BUCKET']
    
    # Test files
    test_files = [
        "integration-test/00000-00060.webm",
        "integration-test/00060-00120.webm", 
        "integration-test/00120-00180.webm",
        "integration-test/00180-00240.webm"
    ]
    
    # Launch worker for this mode
    instance_id = launch_worker(mode)
    if not instance_id:
        return None
    
    # Wait for worker to initialize
    print("⏳ Waiting for worker to initialize (3 minutes)...")
    time.sleep(180)
    
    # Send transcription jobs
    job_ids = []
    output_keys = []
    
    start_time = time.time()
    
    for i, test_file in enumerate(test_files):
        job_id = f"{mode}_test_{i+1}_{int(time.time())}"
        s3_input_path = f"s3://{config['AUDIO_BUCKET']}/{test_file}"
        output_key = f"benchmarks/{mode}/{job_id}_transcript.json"
        s3_output_path = f"s3://{metrics_bucket}/{output_key}"
        
        send_transcription_job(sqs, queue_url, s3_input_path, s3_output_path, job_id)
        job_ids.append(job_id)
        output_keys.append(output_key)
    
    print(f"📤 Sent {len(job_ids)} jobs for {mode.upper()} processing")
    
    # Wait for completion
    print("⏳ Waiting for transcription completion...")
    if wait_for_completion(s3, metrics_bucket, output_keys):
        end_time = time.time()
        total_time = end_time - start_time
        
        print(f"✅ All {mode.upper()} transcriptions completed!")
        
        # Get detailed results
        total_transcription_time = 0
        for output_key in output_keys:
            result = get_transcription_result(s3, metrics_bucket, output_key)
            if result:
                transcription_time = result.get('actual_transcription_time_seconds', 0)
                total_transcription_time += transcription_time
                print(f"   - {result['job_id']}: {transcription_time:.2f}s")
        
        # Terminate the worker
        print(f"🔌 Terminating {mode.upper()} worker: {instance_id}")
        ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
        ec2.terminate_instances(InstanceIds=[instance_id])
        
        return {
            'mode': mode,
            'total_wall_time': total_time,
            'total_transcription_time': total_transcription_time,
            'jobs_completed': len(output_keys),
            'average_per_job': total_transcription_time / len(output_keys) if output_keys else 0
        }
    else:
        print(f"❌ {mode.upper()} transcription timed out")
        # Terminate the worker anyway
        ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
        ec2.terminate_instances(InstanceIds=[instance_id])
        return None

def main():
    print("🎯 TRANSCRIPTION SYSTEM BENCHMARK")
    print("CPU vs GPU Performance Comparison")
    print("=" * 60)
    
    # Load configuration
    config = load_config()
    
    # Test CPU mode first
    cpu_results = benchmark_mode("cpu", config)
    
    if cpu_results:
        print(f"\n✅ CPU Results:")
        print(f"   Total Wall Time: {cpu_results['total_wall_time']:.2f}s")
        print(f"   Total Transcription Time: {cpu_results['total_transcription_time']:.2f}s")
        print(f"   Average per Job: {cpu_results['average_per_job']:.2f}s")
    
    # Wait between tests
    print("\n⏳ Waiting 2 minutes before GPU test...")
    time.sleep(120)
    
    # Test GPU mode
    gpu_results = benchmark_mode("gpu", config)
    
    if gpu_results:
        print(f"\n✅ GPU Results:")
        print(f"   Total Wall Time: {gpu_results['total_wall_time']:.2f}s")
        print(f"   Total Transcription Time: {gpu_results['total_transcription_time']:.2f}s")
        print(f"   Average per Job: {gpu_results['average_per_job']:.2f}s")
    
    # Compare results
    if cpu_results and gpu_results:
        print("\n" + "="*60)
        print("🏆 FINAL COMPARISON")
        print("=" * 60)
        
        cpu_time = cpu_results['total_transcription_time']
        gpu_time = gpu_results['total_transcription_time']
        
        speedup = cpu_time / gpu_time if gpu_time > 0 else 0
        
        print(f"CPU Total Transcription Time: {cpu_time:.2f} seconds")
        print(f"GPU Total Transcription Time: {gpu_time:.2f} seconds")
        print(f"GPU Speedup: {speedup:.2f}x")
        
        if speedup > 1:
            print(f"🚀 GPU is {speedup:.1f}x FASTER than CPU!")
        elif speedup < 1 and speedup > 0:
            print(f"🐌 CPU is {1/speedup:.1f}x FASTER than GPU!")
        
        print(f"\nCPU Average per job: {cpu_results['average_per_job']:.2f}s")
        print(f"GPU Average per job: {gpu_results['average_per_job']:.2f}s")

if __name__ == "__main__":
    main()