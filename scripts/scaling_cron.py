#!/usr/bin/env python3
"""
Cron-based scaling script for transcription workers
Run this script every 5-10 minutes via cron
"""

import json
import boto3
import math
import logging
import argparse
import os
from datetime import datetime
from typing import Dict, List

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class TranscriptionScaler:
    """Handles scaling of transcription worker instances"""
    
    def __init__(self, 
                 metrics_bucket: str,
                 queue_url: str,
                 region: str = "us-east-1",
                 instance_type: str = "g4dn.xlarge",
                 spot_price: str = "0.50",
                 ami_id: str = "ami-0c7217cdde317cfec",
                 security_group_id: str = None,
                 key_name: str = None,
                 min_instances: int = 0,
                 max_instances: int = 10):
        
        self.metrics_bucket = metrics_bucket
        self.queue_url = queue_url
        self.region = region
        self.instance_type = instance_type
        self.spot_price = spot_price
        self.ami_id = ami_id
        self.security_group_id = security_group_id
        self.key_name = key_name
        self.min_instances = min_instances
        self.max_instances = max_instances
        
        # Scaling parameters
        self.minutes_per_instance_hour = 60
        self.scale_up_threshold = 30
        self.scale_down_threshold = 10
        
        # Initialize AWS clients
        self.s3_client = boto3.client('s3', region_name=region)
        self.ec2_client = boto3.client('ec2', region_name=region)
        self.sqs_client = boto3.client('sqs', region_name=region)
        
    def get_queue_metrics(self) -> Dict:
        """Get current queue metrics from S3"""
        try:
            response = self.s3_client.get_object(Bucket=self.metrics_bucket, Key="queue-stats.json")
            data = json.loads(response['Body'].read().decode('utf-8'))
            return data
        except Exception as e:
            logger.warning(f"Error getting queue metrics from S3: {e}")
            # Fallback to SQS queue attributes
            return self.get_queue_metrics_from_sqs()
    
    def get_queue_metrics_from_sqs(self) -> Dict:
        """Fallback: get queue metrics directly from SQS"""
        try:
            response = self.sqs_client.get_queue_attributes(
                QueueUrl=self.queue_url,
                AttributeNames=['ApproximateNumberOfMessages']
            )
            
            job_count = int(response['Attributes']['ApproximateNumberOfMessages'])
            # Estimate 5 minutes per job if we don't have duration data
            estimated_minutes = job_count * 5.0
            
            return {
                "total_minutes_pending": estimated_minutes,
                "job_count": job_count,
                "last_updated": datetime.utcnow().isoformat() + "Z",
                "source": "sqs_fallback"
            }
        except Exception as e:
            logger.error(f"Error getting queue metrics from SQS: {e}")
            return {
                "total_minutes_pending": 0.0,
                "job_count": 0,
                "last_updated": datetime.utcnow().isoformat() + "Z",
                "source": "default"
            }
    
    def get_running_instances(self) -> List[Dict]:
        """Get currently running transcription worker instances"""
        try:
            response = self.ec2_client.describe_instances(
                Filters=[
                    {'Name': 'tag:Type', 'Values': ['whisper-worker']},
                    {'Name': 'instance-state-name', 'Values': ['running', 'pending']}
                ]
            )
            
            instances = []
            for reservation in response['Reservations']:
                for instance in reservation['Instances']:
                    instances.append({
                        'InstanceId': instance['InstanceId'],
                        'State': instance['State']['Name'],
                        'LaunchTime': instance['LaunchTime'],
                        'InstanceType': instance['InstanceType']
                    })
            
            return instances
        except Exception as e:
            logger.error(f"Error getting running instances: {e}")
            return []
    
    def launch_spot_instance(self, count: int = 1) -> List[str]:
        """Launch new spot instances"""
        if not self.security_group_id or not self.key_name:
            logger.error("Security group ID and key name are required to launch instances")
            return []
        
        try:
            # Create user data script
            user_data_script = f"""#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y python3-pip awscli

# Install Python packages
pip3 install boto3

# Download and run the transcription worker
aws s3 cp s3://{self.metrics_bucket}/scripts/transcription_worker.py /opt/transcription_worker.py
chmod +x /opt/transcription_worker.py

# Set environment variables
export QUEUE_URL="{self.queue_url}"
export S3_BUCKET="{self.metrics_bucket}"
export REGION="{self.region}"

# Run the worker
python3 /opt/transcription_worker.py --queue-url "$QUEUE_URL" --s3-bucket "$S3_BUCKET" --region "$REGION"
"""
            
            # Request spot instances
            response = self.ec2_client.request_spot_instances(
                SpotPrice=self.spot_price,
                InstanceCount=count,
                LaunchSpecification={
                    'ImageId': self.ami_id,
                    'InstanceType': self.instance_type,
                    'KeyName': self.key_name,
                    'SecurityGroups': [self.security_group_id],
                    'UserData': user_data_script,
                    'IamInstanceProfile': {
                        'Name': 'transcription-worker-role'
                    }
                }
            )
            
            spot_request_ids = [req['SpotInstanceRequestId'] for req in response['SpotInstanceRequests']]
            logger.info(f"Launched {count} spot instance requests: {spot_request_ids}")
            
            return spot_request_ids
            
        except Exception as e:
            logger.error(f"Error launching spot instances: {e}")
            return []
    
    def terminate_excess_instances(self, instances: List[Dict], target_count: int) -> List[str]:
        """Terminate excess instances"""
        if len(instances) <= target_count:
            return []
        
        # Sort by launch time (terminate newest first)
        instances.sort(key=lambda x: x['LaunchTime'], reverse=True)
        
        instances_to_terminate = instances[:len(instances) - target_count]
        instance_ids = [inst['InstanceId'] for inst in instances_to_terminate]
        
        try:
            self.ec2_client.terminate_instances(InstanceIds=instance_ids)
            logger.info(f"Terminated {len(instance_ids)} instances: {instance_ids}")
            return instance_ids
        except Exception as e:
            logger.error(f"Error terminating instances: {e}")
            return []
    
    def calculate_needed_instances(self, pending_minutes: float, current_instances: int) -> int:
        """Calculate how many instances we need based on pending work"""
        if pending_minutes <= 0:
            return 0
        
        # Calculate needed instances based on pending work
        needed_instances = math.ceil(pending_minutes / self.minutes_per_instance_hour)
        
        # Apply scaling thresholds
        if pending_minutes > self.scale_up_threshold:
            # Scale up aggressively
            needed_instances = max(needed_instances, current_instances + 1)
        elif pending_minutes < self.scale_down_threshold and current_instances > 0:
            # Scale down gradually
            needed_instances = min(needed_instances, current_instances - 1)
        else:
            # Maintain current level
            needed_instances = current_instances
        
        # Apply min/max constraints
        needed_instances = max(self.min_instances, min(self.max_instances, needed_instances))
        
        return needed_instances
    
    def scale(self, dry_run: bool = False) -> Dict:
        """Main scaling function"""
        logger.info("Starting scaling check...")
        
        # Get current queue metrics
        metrics = self.get_queue_metrics()
        pending_minutes = metrics['total_minutes_pending']
        job_count = metrics['job_count']
        
        logger.info(f"Queue metrics: {pending_minutes:.2f} minutes pending, {job_count} jobs")
        
        # Get current running instances
        instances = self.get_running_instances()
        current_count = len(instances)
        
        logger.info(f"Current instances: {current_count}")
        
        # Calculate needed instances
        needed_instances = self.calculate_needed_instances(pending_minutes, current_count)
        
        logger.info(f"Target instances: {needed_instances}")
        
        result = {
            'timestamp': datetime.utcnow().isoformat() + "Z",
            'pending_minutes': pending_minutes,
            'job_count': job_count,
            'current_instances': current_count,
            'target_instances': needed_instances,
            'action': 'no_change',
            'dry_run': dry_run
        }
        
        # Scale up or down as needed
        if needed_instances > current_count:
            # Scale up
            instances_to_launch = needed_instances - current_count
            logger.info(f"Scaling up: launching {instances_to_launch} instances")
            
            if not dry_run:
                spot_requests = self.launch_spot_instance(instances_to_launch)
                result['spot_requests'] = spot_requests
            
            result['action'] = 'scale_up'
            result['instances_launched'] = instances_to_launch
            
        elif needed_instances < current_count:
            # Scale down
            instances_to_terminate = current_count - needed_instances
            logger.info(f"Scaling down: terminating {instances_to_terminate} instances")
            
            if not dry_run:
                terminated_instances = self.terminate_excess_instances(instances, needed_instances)
                result['terminated_instance_ids'] = terminated_instances
            
            result['action'] = 'scale_down'
            result['instances_terminated'] = instances_to_terminate
            
        else:
            # No scaling needed
            logger.info("No scaling action needed")
        
        return result


def main():
    """Main entry point for cron script"""
    parser = argparse.ArgumentParser(description="Transcription Worker Scaling Script")
    parser.add_argument("--bucket", required=True, help="S3 metrics bucket")
    parser.add_argument("--queue-url", required=True, help="SQS queue URL")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--instance-type", default="g4dn.xlarge", help="EC2 instance type")
    parser.add_argument("--spot-price", default="0.50", help="Spot instance price")
    parser.add_argument("--ami-id", default="ami-0c7217cdde317cfec", help="AMI ID")
    parser.add_argument("--security-group-id", help="Security group ID")
    parser.add_argument("--key-name", help="EC2 key pair name")
    parser.add_argument("--min-instances", type=int, default=0, help="Minimum instances")
    parser.add_argument("--max-instances", type=int, default=10, help="Maximum instances")
    parser.add_argument("--dry-run", action="store_true", help="Don't actually launch/terminate instances")
    parser.add_argument("--log-file", help="Log file path")
    
    args = parser.parse_args()
    
    # Setup file logging if specified
    if args.log_file:
        file_handler = logging.FileHandler(args.log_file)
        file_handler.setLevel(logging.INFO)
        formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    
    # Create scaler
    scaler = TranscriptionScaler(
        metrics_bucket=args.bucket,
        queue_url=args.queue_url,
        region=args.region,
        instance_type=args.instance_type,
        spot_price=args.spot_price,
        ami_id=args.ami_id,
        security_group_id=args.security_group_id,
        key_name=args.key_name,
        min_instances=args.min_instances,
        max_instances=args.max_instances
    )
    
    # Run scaling
    try:
        result = scaler.scale(dry_run=args.dry_run)
        logger.info(f"Scaling completed: {result}")
        
        # Print result for cron output
        print(json.dumps(result, indent=2))
        
    except Exception as e:
        logger.error(f"Scaling failed: {e}")
        exit(1)


if __name__ == "__main__":
    main()