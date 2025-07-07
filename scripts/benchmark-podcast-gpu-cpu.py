#!/usr/bin/env python3
"""
Comprehensive GPU vs CPU Benchmark with Real Podcast Episode
Tests 81-minute My First Million episode for realistic performance comparison
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

def send_podcast_job(sqs, queue_url, job_prefix, config):
    """Send podcast transcription job"""
    job_id = f"{job_prefix}_podcast_mfm723_{int(time.time())}"
    s3_input_path = f"s3://{config['AUDIO_BUCKET']}/integration-test-new/mfm-episode-723.mp3"
    output_key = f"benchmarks/podcast/{job_prefix}/{job_id}_transcript.json"
    s3_output_path = f"s3://{config['METRICS_BUCKET']}/{output_key}"
    
    message_body = {
        "job_id": job_id,
        "s3_input_path": s3_input_path,
        "s3_output_path": s3_output_path,
        "estimated_duration_seconds": 4860,  # 81 minutes
        "priority": 1,
        "retry_count": 0,
        "submitted_at": datetime.now().isoformat() + "Z"
    }
    
    sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message_body))
    print(f"📤 Sent {job_prefix.upper()} podcast job: {job_id}")
    return job_id, output_key

def wait_for_podcast_result(s3, bucket, output_key, timeout=7200):  # 2 hour timeout
    """Wait for podcast transcription result"""
    start_time = time.time()
    
    print(f"⏳ Waiting for transcription (timeout: {timeout/60:.0f} minutes)")
    
    while (time.time() - start_time) < timeout:
        try:
            response = s3.head_object(Bucket=bucket, Key=output_key)
            elapsed = time.time() - start_time
            print(f"✅ Podcast transcription completed in {elapsed:.1f} seconds!")
            
            # Get the result
            result = s3.get_object(Bucket=bucket, Key=output_key)
            content = result['Body'].read().decode('utf-8')
            data = json.loads(content)
            return data
        except:
            elapsed = time.time() - start_time
            print(f"⏳ Still processing... ({elapsed:.0f}s elapsed)")
            time.sleep(60)  # Check every minute
    
    print(f"❌ Podcast transcription timed out after {timeout/60:.0f} minutes")
    return None

def launch_worker(mode, config):
    """Launch CPU or GPU worker"""
    print(f"\n🚀 LAUNCHING {mode.upper()} WORKER FOR PODCAST TRANSCRIPTION")
    print("=" * 60)
    
    if mode == "gpu":
        cmd = "./scripts/launch-spot-worker.sh"
    else:
        cmd = "./scripts/launch-spot-worker-cpu.sh"
    
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        for line in result.stdout.split('\n'):
            if "spot instance launched:" in line.lower():
                instance_id = line.split(': ')[1].strip()
                print(f"✅ {mode.upper()} worker launched: {instance_id}")
                return instance_id
    
    print(f"❌ Failed to launch {mode} worker")
    print(f"Error: {result.stderr}")
    return None

def benchmark_podcast_mode(mode, config):
    """Run complete podcast benchmark for GPU or CPU mode"""
    print(f"\n🎯 BENCHMARKING {mode.upper()} MODE - PODCAST EPISODE")
    print("=" * 70)
    print("Podcast: My First Million Episode 723")
    print("Title: How I Bought a $3.4M Business For $200K")  
    print("Duration: 81 minutes (4,860 seconds)")
    print("File size: 66MB MP3")
    
    # Initialize AWS clients
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
    
    # Launch worker
    instance_id = launch_worker(mode, config)
    if not instance_id:
        return None
    
    try:
        # Wait for worker to initialize (longer for large model)
        print(f"⏳ Waiting 5 minutes for {mode.upper()} worker to initialize...")
        time.sleep(300)
        
        # Send podcast job
        wall_start_time = time.time()
        job_id, output_key = send_podcast_job(sqs, config['QUEUE_URL'], mode, config)
        
        print(f"📤 Sent podcast job for {mode.upper()} processing")
        print(f"🎯 This will be the ultimate test of {mode.upper()} performance!")
        
        # Wait for completion (up to 2 hours)
        result = wait_for_podcast_result(s3, config['METRICS_BUCKET'], output_key)
        wall_end_time = time.time()
        
        if result:
            total_wall_time = wall_end_time - wall_start_time
            transcription_time = result.get('actual_transcription_time_seconds', 0)
            audio_duration = 4860  # 81 minutes
            
            # Calculate performance metrics
            rtf = transcription_time / audio_duration
            speedup = audio_duration / transcription_time
            segments = len(result.get('transcript', {}).get('segments', []))
            
            print(f"\n📊 {mode.upper()} PODCAST TRANSCRIPTION RESULTS")
            print("=" * 60)
            print(f"Audio duration: {audio_duration} seconds (81 minutes)")
            print(f"Transcription time: {transcription_time:.2f} seconds ({transcription_time/60:.1f} minutes)")
            print(f"Total wall time: {total_wall_time:.2f} seconds ({total_wall_time/60:.1f} minutes)")
            print(f"Real-time factor: {rtf:.3f}")
            print(f"Processing speed: {speedup:.1f}x realtime")
            print(f"Transcript segments: {segments}")
            print(f"Words per minute: ~{segments * 10}")  # Rough estimate
            
            # Performance classification
            if speedup > 60:
                grade = "🎉 AMAZING"
            elif speedup > 25:
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
            
            return {
                'mode': mode,
                'instance_id': instance_id,
                'total_wall_time': total_wall_time,
                'transcription_time': transcription_time,
                'rtf': rtf,
                'speedup': speedup,
                'segments': segments,
                'result': result
            }
        else:
            print(f"❌ {mode.upper()} podcast transcription failed")
            return None
            
    finally:
        # Always cleanup worker
        print(f"\n🔌 Terminating {mode.upper()} worker: {instance_id}")
        ec2.terminate_instances(InstanceIds=[instance_id])

def compare_results(cpu_results, gpu_results):
    """Compare CPU vs GPU results"""
    print(f"\n" + "=" * 80)
    print("🏆 COMPREHENSIVE PODCAST TRANSCRIPTION COMPARISON")
    print("=" * 80)
    
    audio_duration = 4860  # 81 minutes
    
    print(f"\n📋 PODCAST DETAILS")
    print("-" * 50)
    print(f"Episode: My First Million #723")
    print(f"Title: How I Bought a $3.4M Business For $200K")
    print(f"Duration: {audio_duration} seconds (81 minutes)")
    print(f"File: 66MB MP3")
    
    print(f"\n📊 PERFORMANCE COMPARISON")
    print("-" * 80)
    print(f"{'Metric':<30} {'CPU':<20} {'GPU':<20} {'GPU Advantage':<15}")
    print("-" * 80)
    
    if cpu_results and gpu_results:
        cpu_time = cpu_results['transcription_time']
        gpu_time = gpu_results['transcription_time']
        speedup_factor = cpu_time / gpu_time
        
        cpu_wall = cpu_results['total_wall_time']
        gpu_wall = gpu_results['total_wall_time']
        wall_speedup = cpu_wall / gpu_wall
        
        cpu_rtf = cpu_results['rtf']
        gpu_rtf = gpu_results['rtf']
        
        cpu_speed = cpu_results['speedup']
        gpu_speed = gpu_results['speedup']
        
        print(f"{'Transcription Time':<30} {cpu_time/60:<19.1f}m {gpu_time/60:<19.1f}m {speedup_factor:<14.2f}x")
        print(f"{'Wall Clock Time':<30} {cpu_wall/60:<19.1f}m {gpu_wall/60:<19.1f}m {wall_speedup:<14.2f}x")
        print(f"{'Real-time Factor':<30} {cpu_rtf:<20.3f} {gpu_rtf:<20.3f} {cpu_rtf/gpu_rtf:<14.2f}x")
        print(f"{'Processing Speed':<30} {cpu_speed:<19.1f}x {gpu_speed:<19.1f}x {gpu_speed/cpu_speed:<14.2f}x")
        print(f"{'Segments Generated':<30} {cpu_results['segments']:<20} {gpu_results['segments']:<20} -")
        
        print("-" * 80)
        
        # Cost analysis (rough estimates)
        cpu_cost = (cpu_wall / 3600) * 0.10  # ~$0.10/hour for CPU instance
        gpu_cost = (gpu_wall / 3600) * 0.25  # ~$0.25/hour for GPU instance
        
        print(f"\n💰 COST ANALYSIS (Estimated)")
        print("-" * 50)
        print(f"CPU processing cost: ~${cpu_cost:.3f}")
        print(f"GPU processing cost: ~${gpu_cost:.3f}")
        print(f"Cost difference: ~${abs(gpu_cost - cpu_cost):.3f} ({'GPU cheaper' if gpu_cost < cpu_cost else 'CPU cheaper'})")
        
        # Final verdict
        print(f"\n🎯 FINAL VERDICT")
        print("-" * 50)
        
        if speedup_factor > 10:
            verdict = f"🎉 GPU is {speedup_factor:.1f}x FASTER - Excellent acceleration!"
        elif speedup_factor > 5:
            verdict = f"🚀 GPU is {speedup_factor:.1f}x FASTER - Great performance!"
        elif speedup_factor > 2:
            verdict = f"✅ GPU is {speedup_factor:.1f}x FASTER - Good improvement!"
        else:
            verdict = f"⚠️ GPU is only {speedup_factor:.1f}x FASTER - Needs optimization!"
        
        print(verdict)
        print(f"Time saved: {(cpu_time - gpu_time)/60:.1f} minutes")
        print(f"Efficiency gain: {((cpu_time - gpu_time)/cpu_time)*100:.1f}%")
        
    elif cpu_results:
        print(f"CPU completed: {cpu_results['transcription_time']/60:.1f} minutes")
        print(f"GPU failed: Unable to complete transcription")
    elif gpu_results:
        print(f"GPU completed: {gpu_results['transcription_time']/60:.1f} minutes")
        print(f"CPU failed: Unable to complete transcription")
    else:
        print("Both CPU and GPU failed to complete transcription")

def main():
    print("🎯 COMPREHENSIVE PODCAST GPU vs CPU BENCHMARK")
    print("Testing with real-world 81-minute podcast episode")
    print("=" * 80)
    
    # Load configuration
    config = load_config()
    
    # Ask user what to test
    print("\nWhat would you like to test?")
    print("1. CPU only")
    print("2. GPU only") 
    print("3. Both CPU and GPU (full comparison)")
    
    choice = input("\nEnter your choice (1-3): ").strip()
    
    cpu_results = None
    gpu_results = None
    
    if choice in ['1', '3']:
        print(f"\n{'='*20} STARTING CPU BENCHMARK {'='*20}")
        cpu_results = benchmark_podcast_mode("cpu", config)
        
    if choice in ['2', '3']:
        if choice == '3' and cpu_results:
            print(f"\n⏳ Waiting 3 minutes between tests...")
            time.sleep(180)
            
        print(f"\n{'='*20} STARTING GPU BENCHMARK {'='*20}")
        gpu_results = benchmark_podcast_mode("gpu", config)
    
    # Compare results
    if choice == '3':
        compare_results(cpu_results, gpu_results)
    elif choice == '1' and cpu_results:
        print(f"\n✅ CPU-only test complete!")
        print(f"Processed 81-minute podcast in {cpu_results['transcription_time']/60:.1f} minutes")
    elif choice == '2' and gpu_results:
        print(f"\n✅ GPU-only test complete!")
        print(f"Processed 81-minute podcast in {gpu_results['transcription_time']/60:.1f} minutes")
    
    print(f"\n🎉 PODCAST BENCHMARK COMPLETE!")

if __name__ == "__main__":
    main()