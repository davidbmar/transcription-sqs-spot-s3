#!/usr/bin/env python3
"""
System Health Monitor - Detect stuck workers and failed jobs
"""

import boto3
import json
import time
from datetime import datetime, timedelta
import argparse

def load_config():
    config = {}
    with open(".env", 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    return config

def check_queue_health(sqs, queue_url):
    """Check if messages are stuck in queue"""
    try:
        attrs = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=['All']
        )['Attributes']
        
        visible_messages = int(attrs.get('ApproximateNumberOfMessages', 0))
        inflight_messages = int(attrs.get('ApproximateNumberOfMessagesNotVisible', 0))
        
        print("📊 QUEUE HEALTH CHECK")
        print("=" * 30)
        print(f"Messages in queue: {visible_messages}")
        print(f"Messages in-flight: {inflight_messages}")
        
        # Check for stuck messages (in-flight > 30 minutes)
        if inflight_messages > 0:
            print("⚠️ WARNING: Messages are in-flight")
            print("This could indicate:")
            print("  - Workers are processing (normal)")
            print("  - Workers crashed (problem)")
            print("  - Messages stuck due to errors (problem)")
        
        return {
            'visible': visible_messages,
            'inflight': inflight_messages,
            'healthy': inflight_messages == 0 or visible_messages == 0
        }
    except Exception as e:
        print(f"❌ Error checking queue: {e}")
        return {'healthy': False, 'error': str(e)}

def check_worker_health(s3, bucket):
    """Check worker heartbeats and detect stale workers"""
    try:
        print("\n👷 WORKER HEALTH CHECK")
        print("=" * 30)
        
        # List worker status files
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket, Prefix='workers/')
        
        workers = []
        now = datetime.utcnow()
        
        for page in pages:
            if 'Contents' in page:
                for obj in page['Contents']:
                    if obj['Key'].endswith('/status.json'):
                        worker_id = obj['Key'].split('/')[1]
                        
                        try:
                            response = s3.get_object(Bucket=bucket, Key=obj['Key'])
                            worker_data = json.loads(response['Body'].read().decode('utf-8'))
                            
                            last_heartbeat = worker_data.get('last_heartbeat', '')
                            if last_heartbeat:
                                heartbeat_time = datetime.fromisoformat(last_heartbeat.replace('Z', '+00:00'))
                                age_minutes = (now - heartbeat_time.replace(tzinfo=None)).total_seconds() / 60
                            else:
                                age_minutes = float('inf')
                            
                            workers.append({
                                'worker_id': worker_id,
                                'status': worker_data.get('status', 'UNKNOWN'),
                                'age_minutes': age_minutes,
                                'jobs_processed': worker_data.get('jobs_processed', 0),
                                'healthy': age_minutes < 5  # Heartbeat within 5 minutes
                            })
                            
                        except Exception as e:
                            print(f"Error reading worker {worker_id}: {e}")
        
        if not workers:
            print("🚫 No workers found")
            return {'workers': [], 'healthy': True}  # No workers is fine if no jobs
        
        healthy_workers = [w for w in workers if w['healthy']]
        stale_workers = [w for w in workers if not w['healthy']]
        
        print(f"✅ Healthy workers: {len(healthy_workers)}")
        print(f"⚠️ Stale workers: {len(stale_workers)}")
        
        for worker in stale_workers:
            print(f"  - {worker['worker_id'][:12]}... (stale for {worker['age_minutes']:.1f} min)")
        
        return {
            'workers': workers,
            'healthy_count': len(healthy_workers),
            'stale_count': len(stale_workers),
            'healthy': len(stale_workers) == 0
        }
        
    except Exception as e:
        print(f"❌ Error checking workers: {e}")
        return {'healthy': False, 'error': str(e)}

def check_job_health(s3, bucket):
    """Check for stuck or failed jobs"""
    try:
        print("\n📋 JOB HEALTH CHECK")
        print("=" * 30)
        
        # List progress files
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket, Prefix='progress/')
        
        jobs = []
        now = datetime.utcnow()
        
        for page in pages:
            if 'Contents' in page:
                for obj in page['Contents']:
                    if obj['Key'].endswith('/status.json'):
                        job_id = obj['Key'].split('/')[1]
                        
                        try:
                            response = s3.get_object(Bucket=bucket, Key=obj['Key'])
                            progress_data = json.loads(response['Body'].read().decode('utf-8'))
                            
                            last_update = progress_data.get('last_update', '')
                            if last_update:
                                update_time = datetime.fromisoformat(last_update.replace('Z', '+00:00'))
                                age_minutes = (now - update_time.replace(tzinfo=None)).total_seconds() / 60
                            else:
                                age_minutes = float('inf')
                            
                            status = progress_data.get('status', 'UNKNOWN')
                            percentage = progress_data.get('percentage', 0)
                            
                            jobs.append({
                                'job_id': job_id,
                                'status': status,
                                'percentage': percentage,
                                'age_minutes': age_minutes,
                                'stuck': status not in ['COMPLETED', 'FAILED'] and age_minutes > 10
                            })
                            
                        except Exception as e:
                            print(f"Error reading job {job_id}: {e}")
        
        if not jobs:
            print("📭 No active jobs found")
            return {'jobs': [], 'healthy': True}
        
        active_jobs = [j for j in jobs if j['status'] not in ['COMPLETED', 'FAILED']]
        stuck_jobs = [j for j in jobs if j['stuck']]
        
        print(f"🔄 Active jobs: {len(active_jobs)}")
        print(f"⚠️ Stuck jobs: {len(stuck_jobs)}")
        
        for job in stuck_jobs:
            print(f"  - {job['job_id']} ({job['status']}, {job['percentage']}%, stale {job['age_minutes']:.1f} min)")
        
        return {
            'jobs': jobs,
            'active_count': len(active_jobs),
            'stuck_count': len(stuck_jobs),
            'healthy': len(stuck_jobs) == 0
        }
        
    except Exception as e:
        print(f"❌ Error checking jobs: {e}")
        return {'healthy': False, 'error': str(e)}

def check_ec2_instances(ec2, region):
    """Check running transcription instances"""
    try:
        print("\n🖥️ EC2 INSTANCE CHECK")
        print("=" * 30)
        
        instances = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Type", "Values": ["whisper-worker"]},
                {"Name": "instance-state-name", "Values": ["running", "pending"]}
            ]
        )
        
        running_instances = []
        for reservation in instances['Reservations']:
            for instance in reservation['Instances']:
                name = next((tag['Value'] for tag in instance.get('Tags', []) if tag['Key'] == 'Name'), 'Unknown')
                running_instances.append({
                    'instance_id': instance['InstanceId'],
                    'name': name,
                    'state': instance['State']['Name'],
                    'type': instance['InstanceType'],
                    'launch_time': instance['LaunchTime']
                })
        
        print(f"🖥️ Running instances: {len(running_instances)}")
        for instance in running_instances:
            print(f"  - {instance['name']} ({instance['instance_id']}) - {instance['state']}")
        
        return {
            'instances': running_instances,
            'count': len(running_instances),
            'healthy': True  # Just informational
        }
        
    except Exception as e:
        print(f"❌ Error checking instances: {e}")
        return {'healthy': False, 'error': str(e)}

def send_alert(message):
    """Send alert about system issues (placeholder)"""
    print("\n🚨 SYSTEM ALERT")
    print("=" * 30)
    print(message)
    print("\nActions you can take:")
    print("  1. Check worker logs on EC2 instances")
    print("  2. Restart stuck workers")
    print("  3. Purge stuck messages from SQS")
    print("  4. Review CloudWatch logs")

def main():
    parser = argparse.ArgumentParser(description='Monitor transcription system health')
    parser.add_argument('--continuous', action='store_true', help='Run continuous monitoring')
    parser.add_argument('--interval', type=int, default=60, help='Check interval in seconds')
    
    args = parser.parse_args()
    
    config = load_config()
    
    # Initialize AWS clients
    sqs = boto3.client('sqs', region_name=config['AWS_REGION'])
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    ec2 = boto3.client('ec2', region_name=config['AWS_REGION'])
    
    def run_health_check():
        print(f"\n🔍 TRANSCRIPTION SYSTEM HEALTH CHECK")
        print(f"Timestamp: {datetime.now().isoformat()}")
        print("=" * 60)
        
        # Run all health checks
        queue_health = check_queue_health(sqs, config['QUEUE_URL'])
        worker_health = check_worker_health(s3, config['METRICS_BUCKET'])
        job_health = check_job_health(s3, config['METRICS_BUCKET'])
        instance_health = check_ec2_instances(ec2, config['AWS_REGION'])
        
        # Overall system health
        all_healthy = all([
            queue_health.get('healthy', False),
            worker_health.get('healthy', False),
            job_health.get('healthy', False),
            instance_health.get('healthy', False)
        ])
        
        print(f"\n📊 OVERALL SYSTEM STATUS")
        print("=" * 30)
        if all_healthy:
            print("✅ System is healthy")
        else:
            print("⚠️ System has issues detected")
            
            # Generate alert message
            issues = []
            if not queue_health.get('healthy', False):
                issues.append(f"Queue issues: {queue_health.get('error', 'Messages stuck')}")
            if not worker_health.get('healthy', False):
                issues.append(f"Worker issues: {worker_health.get('stale_count', 0)} stale workers")
            if not job_health.get('healthy', False):
                issues.append(f"Job issues: {job_health.get('stuck_count', 0)} stuck jobs")
            
            alert_message = "System health issues detected:\n" + "\n".join(f"  - {issue}" for issue in issues)
            send_alert(alert_message)
        
        return all_healthy
    
    if args.continuous:
        print("🔄 Starting continuous health monitoring...")
        print(f"Check interval: {args.interval} seconds")
        
        while True:
            try:
                run_health_check()
                time.sleep(args.interval)
            except KeyboardInterrupt:
                print("\n⏹️ Monitoring stopped by user")
                break
            except Exception as e:
                print(f"\n❌ Error in health check: {e}")
                time.sleep(args.interval)
    else:
        run_health_check()

if __name__ == '__main__':
    main()