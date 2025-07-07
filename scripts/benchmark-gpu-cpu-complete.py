#!/usr/bin/env python3
"""
Complete GPU vs CPU Transcription Benchmark
Tests all 4 sample files with both GPU and CPU workers
Generates comparison table
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

def send_transcription_jobs(sqs, queue_url, test_files, job_prefix, config):
    """Send all test files to transcription queue"""
    job_ids = []
    output_keys = []
    
    for i, test_file in enumerate(test_files):
        job_id = f"{job_prefix}_test_{i+1}_{int(time.time())}"
        s3_input_path = f"s3://{config['AUDIO_BUCKET']}/{test_file}"
        output_key = f"benchmarks/{job_prefix}/{job_id}_transcript.json"
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
        job_ids.append(job_id)
        output_keys.append(output_key)
        print(f"📤 Sent {job_prefix.upper()} job: {job_id}")
    
    return job_ids, output_keys

def wait_for_completion(s3, bucket, output_keys, timeout=900):
    """Wait for all transcriptions to complete"""
    start_time = time.time()
    completed = set()
    
    while len(completed) < len(output_keys) and (time.time() - start_time) < timeout:
        for key in output_keys:
            if key not in completed:
                try:
                    s3.head_object(Bucket=bucket, Key=key)
                    completed.add(key)
                    print(f"✅ Completed: {key.split('/')[-1]}")
                except:
                    pass
        
        if len(completed) < len(output_keys):
            remaining = len(output_keys) - len(completed)
            elapsed = time.time() - start_time
            print(f"⏳ Waiting... {len(completed)}/{len(output_keys)} complete ({elapsed:.0f}s elapsed, {remaining} remaining)")
            time.sleep(30)
    
    return len(completed) == len(output_keys)

def get_transcription_results(s3, bucket, output_keys):
    """Get transcription results from S3"""
    results = []
    for key in output_keys:
        try:
            response = s3.get_object(Bucket=bucket, Key=key)
            content = response['Body'].read().decode('utf-8')
            data = json.loads(content)
            results.append(data)
        except Exception as e:
            print(f"❌ Error getting {key}: {e}")
            results.append(None)
    return results

def launch_worker(mode, config):
    """Launch GPU or CPU worker"""
    print(f"\n🚀 LAUNCHING {mode.upper()} WORKER")
    print("=" * 50)
    
    if mode == "gpu":
        cmd = "./scripts/launch-spot-worker.sh"
    else:
        cmd = "./scripts/launch-spot-worker-cpu.sh"
    
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        # Extract instance ID
        for line in result.stdout.split('\n'):
            if "spot instance launched:" in line.lower():
                instance_id = line.split(': ')[1].strip()
                print(f"✅ {mode.upper()} worker launched: {instance_id}")
                return instance_id
    
    print(f"❌ Failed to launch {mode} worker")
    print(f"Error: {result.stderr}")
    return None

def benchmark_mode(mode, config, test_files):
    """Run complete benchmark for GPU or CPU mode"""
    print(f"\n🎯 BENCHMARKING {mode.upper()} MODE")
    print("=" * 60)
    
    # Initialize AWS clients
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
    
    # Launch worker
    instance_id = launch_worker(mode, config)
    if not instance_id:
        return None
    
    # Wait for worker to initialize
    print(f"⏳ Waiting 4 minutes for {mode.upper()} worker to initialize...")
    time.sleep(240)
    
    # Send jobs
    start_time = time.time()
    job_ids, output_keys = send_transcription_jobs(
        sqs, config['QUEUE_URL'], test_files, mode, config
    )
    
    print(f"📤 Sent {len(job_ids)} jobs for {mode.upper()} processing")
    
    # Wait for completion
    if wait_for_completion(s3, config['METRICS_BUCKET'], output_keys):
        end_time = time.time()
        total_wall_time = end_time - start_time
        
        # Get results
        results = get_transcription_results(s3, config['METRICS_BUCKET'], output_keys)
        
        print(f"✅ All {mode.upper()} transcriptions completed!")
        
        # Calculate metrics
        transcription_times = []
        for result in results:
            if result:
                transcription_times.append(result.get('actual_transcription_time_seconds', 0))
        
        # Terminate worker
        print(f"🔌 Terminating {mode.upper()} worker: {instance_id}")
        ec2.terminate_instances(InstanceIds=[instance_id])
        
        return {
            'mode': mode,
            'instance_id': instance_id,
            'total_wall_time': total_wall_time,
            'transcription_times': transcription_times,
            'results': results,
            'jobs_completed': len([r for r in results if r is not None])
        }
    else:
        print(f"❌ {mode.upper()} transcription timed out")
        # Terminate worker anyway
        ec2.terminate_instances(InstanceIds=[instance_id])
        return None

def print_results_table(cpu_results, gpu_results, test_files):
    """Print comprehensive results table"""
    print("\n" + "="*80)
    print("🏆 COMPLETE GPU vs CPU TRANSCRIPTION BENCHMARK RESULTS")
    print("="*80)
    
    # File results table
    print("\n📊 PER-FILE TRANSCRIPTION TIMES")
    print("-" * 80)
    print(f"{'File':<35} {'CPU Time (s)':<15} {'GPU Time (s)':<15} {'Speedup':<10}")
    print("-" * 80)
    
    total_cpu_time = 0
    total_gpu_time = 0
    
    for i, test_file in enumerate(test_files):
        filename = test_file.split('/')[-1]
        
        cpu_time = cpu_results['transcription_times'][i] if i < len(cpu_results['transcription_times']) else 0
        gpu_time = gpu_results['transcription_times'][i] if gpu_results and i < len(gpu_results['transcription_times']) else 0
        
        total_cpu_time += cpu_time
        total_gpu_time += gpu_time
        
        if gpu_time > 0:
            speedup = cpu_time / gpu_time
            speedup_str = f"{speedup:.2f}x"
        else:
            speedup_str = "N/A"
        
        print(f"{filename:<35} {cpu_time:<15.2f} {gpu_time:<15.2f} {speedup_str:<10}")
    
    print("-" * 80)
    print(f"{'TOTAL':<35} {total_cpu_time:<15.2f} {total_gpu_time:<15.2f}", end="")
    
    if total_gpu_time > 0:
        overall_speedup = total_cpu_time / total_gpu_time
        print(f" {overall_speedup:.2f}x")
    else:
        print(" N/A")
    
    # Summary table
    print(f"\n📈 SUMMARY STATISTICS")
    print("-" * 50)
    print(f"CPU Results:")
    print(f"  - Jobs Completed: {cpu_results['jobs_completed']}/4")
    print(f"  - Total Transcription Time: {total_cpu_time:.2f} seconds")
    print(f"  - Average per File: {total_cpu_time/4:.2f} seconds")
    print(f"  - Wall Clock Time: {cpu_results['total_wall_time']:.2f} seconds")
    
    if gpu_results:
        print(f"\nGPU Results:")
        print(f"  - Jobs Completed: {gpu_results['jobs_completed']}/4")
        print(f"  - Total Transcription Time: {total_gpu_time:.2f} seconds")
        print(f"  - Average per File: {total_gpu_time/4:.2f} seconds")
        print(f"  - Wall Clock Time: {gpu_results['total_wall_time']:.2f} seconds")
        
        if total_gpu_time > 0:
            print(f"\n🚀 OVERALL GPU SPEEDUP: {overall_speedup:.2f}x")
            
            if overall_speedup > 1:
                print(f"🎉 GPU is {overall_speedup:.1f}x FASTER than CPU!")
            else:
                print(f"🐌 CPU is {1/overall_speedup:.1f}x FASTER than GPU!")
    else:
        print(f"\nGPU Results: FAILED")

def main():
    print("🎯 COMPREHENSIVE GPU vs CPU TRANSCRIPTION BENCHMARK")
    print("Testing all 4 sample files with detailed performance comparison")
    print("=" * 80)
    
    # Load configuration
    config = load_config()
    
    # Test files (all 4 samples)
    test_files = [
        "integration-test/00000-00060.webm",
        "integration-test/00060-00120.webm", 
        "integration-test/00120-00180.webm",
        "integration-test/00180-00240.webm"
    ]
    
    print(f"Test files: {len(test_files)}")
    for i, f in enumerate(test_files, 1):
        print(f"  {i}. {f}")
    
    # Benchmark CPU first
    cpu_results = benchmark_mode("cpu", config, test_files)
    
    if not cpu_results:
        print("❌ CPU benchmark failed!")
        return
    
    # Wait between tests
    print("\n⏳ Waiting 2 minutes before GPU test...")
    time.sleep(120)
    
    # Benchmark GPU
    gpu_results = benchmark_mode("gpu", config, test_files)
    
    # Print comprehensive results
    print_results_table(cpu_results, gpu_results, test_files)
    
    print(f"\n🎉 BENCHMARK COMPLETE!")
    print(f"Results stored in S3 bucket: {config['METRICS_BUCKET']}")

if __name__ == "__main__":
    main()