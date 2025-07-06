#!/usr/bin/env python3
"""
AWS Lambda function for automatic scaling of transcription workers
"""

import json
import boto3
import math
import logging
from datetime import datetime
from typing import Dict, List

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Configuration
METRICS_BUCKET = "your-metrics-bucket"
QUEUE_URL = "https://sqs.us-east-1.amazonaws.com/account/transcription-queue"
REGION = "us-east-1"
INSTANCE_TYPE = "g4dn.xlarge"
SPOT_PRICE = "0.50"
AMI_ID = "ami-0c7217cdde317cfec"
SECURITY_GROUP_ID = "sg-xxxxxxxxx"
KEY_NAME = "your-key-pair"
LAUNCH_SCRIPT_S3_PATH = "s3://your-scripts/launch-spot-worker.sh"

# Scaling parameters
MIN_INSTANCES = 0
MAX_INSTANCES = 10
MINUTES_PER_INSTANCE_HOUR = 60  # Assume 60 minutes of transcription per hour per instance
SCALE_UP_THRESHOLD = 30  # Scale up if more than 30 minutes pending
SCALE_DOWN_THRESHOLD = 10  # Scale down if less than 10 minutes pending per instance


def get_queue_metrics(s3_client, bucket: str, key: str = "queue-stats.json") -> Dict:
    """Get current queue metrics from S3"""
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        data = json.loads(response['Body'].read().decode('utf-8'))
        return data
    except Exception as e:
        logger.error(f"Error getting queue metrics: {e}")
        return {
            "total_minutes_pending": 0.0,
            "job_count": 0,
            "last_updated": datetime.utcnow().isoformat() + "Z"
        }


def get_running_instances(ec2_client, region: str) -> List[Dict]:
    """Get currently running transcription worker instances"""
    try:
        response = ec2_client.describe_instances(
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


def launch_spot_instance(ec2_client, count: int = 1) -> List[str]:
    """Launch new spot instances"""
    try:
        # Create user data script
        user_data_script = f"""#!/bin/bash
set -e

# Download and run launch script
aws s3 cp {LAUNCH_SCRIPT_S3_PATH} /tmp/launch-worker.sh
chmod +x /tmp/launch-worker.sh

# Set environment variables
export QUEUE_URL="{QUEUE_URL}"
export S3_BUCKET="{METRICS_BUCKET}"
export REGION="{REGION}"

# Run the worker
/tmp/launch-worker.sh
"""
        
        # Request spot instances
        response = ec2_client.request_spot_instances(
            SpotPrice=SPOT_PRICE,
            InstanceCount=count,
            LaunchSpecification={
                'ImageId': AMI_ID,
                'InstanceType': INSTANCE_TYPE,
                'KeyName': KEY_NAME,
                'SecurityGroups': [SECURITY_GROUP_ID],
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


def terminate_excess_instances(ec2_client, instances: List[Dict], target_count: int) -> List[str]:
    """Terminate excess instances"""
    if len(instances) <= target_count:
        return []
    
    # Sort by launch time (terminate newest first to avoid interrupting long-running jobs)
    instances.sort(key=lambda x: x['LaunchTime'], reverse=True)
    
    instances_to_terminate = instances[:len(instances) - target_count]
    instance_ids = [inst['InstanceId'] for inst in instances_to_terminate]
    
    try:
        ec2_client.terminate_instances(InstanceIds=instance_ids)
        logger.info(f"Terminated {len(instance_ids)} instances: {instance_ids}")
        return instance_ids
    except Exception as e:
        logger.error(f"Error terminating instances: {e}")
        return []


def calculate_needed_instances(pending_minutes: float, current_instances: int) -> int:
    """Calculate how many instances we need based on pending work"""
    if pending_minutes <= 0:
        return 0
    
    # Calculate needed instances based on pending work
    needed_instances = math.ceil(pending_minutes / MINUTES_PER_INSTANCE_HOUR)
    
    # Apply scaling thresholds
    if pending_minutes > SCALE_UP_THRESHOLD:
        # Scale up aggressively
        needed_instances = max(needed_instances, current_instances + 1)
    elif pending_minutes < SCALE_DOWN_THRESHOLD and current_instances > 0:
        # Scale down gradually
        needed_instances = min(needed_instances, current_instances - 1)
    else:
        # Maintain current level
        needed_instances = current_instances
    
    # Apply min/max constraints
    needed_instances = max(MIN_INSTANCES, min(MAX_INSTANCES, needed_instances))
    
    return needed_instances


def lambda_handler(event, context):
    """Main Lambda handler function"""
    logger.info(f"Scaling Lambda triggered with event: {json.dumps(event)}")
    
    # Initialize AWS clients
    s3_client = boto3.client('s3', region_name=REGION)
    ec2_client = boto3.client('ec2', region_name=REGION)
    
    try:
        # Get current queue metrics
        metrics = get_queue_metrics(s3_client, METRICS_BUCKET)
        pending_minutes = metrics['total_minutes_pending']
        job_count = metrics['job_count']
        
        logger.info(f"Queue metrics: {pending_minutes:.2f} minutes pending, {job_count} jobs")
        
        # Get current running instances
        instances = get_running_instances(ec2_client, REGION)
        current_count = len(instances)
        
        logger.info(f"Current instances: {current_count}")
        
        # Calculate needed instances
        needed_instances = calculate_needed_instances(pending_minutes, current_count)
        
        logger.info(f"Needed instances: {needed_instances}")
        
        # Scale up or down as needed
        if needed_instances > current_count:
            # Scale up
            instances_to_launch = needed_instances - current_count
            logger.info(f"Scaling up: launching {instances_to_launch} instances")
            
            spot_requests = launch_spot_instance(ec2_client, instances_to_launch)
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'action': 'scale_up',
                    'instances_launched': instances_to_launch,
                    'spot_requests': spot_requests,
                    'pending_minutes': pending_minutes,
                    'current_instances': current_count,
                    'target_instances': needed_instances
                })
            }
            
        elif needed_instances < current_count:
            # Scale down
            instances_to_terminate = current_count - needed_instances
            logger.info(f"Scaling down: terminating {instances_to_terminate} instances")
            
            terminated_instances = terminate_excess_instances(ec2_client, instances, needed_instances)
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'action': 'scale_down',
                    'instances_terminated': len(terminated_instances),
                    'terminated_instance_ids': terminated_instances,
                    'pending_minutes': pending_minutes,
                    'current_instances': current_count,
                    'target_instances': needed_instances
                })
            }
            
        else:
            # No scaling needed
            logger.info("No scaling action needed")
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'action': 'no_change',
                    'pending_minutes': pending_minutes,
                    'current_instances': current_count,
                    'target_instances': needed_instances
                })
            }
            
    except Exception as e:
        logger.error(f"Error in scaling Lambda: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'message': 'Scaling operation failed'
            })
        }


# For testing locally
if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Test scaling logic locally")
    parser.add_argument("--bucket", required=True, help="S3 metrics bucket")
    parser.add_argument("--queue-url", required=True, help="SQS queue URL")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--dry-run", action="store_true", help="Don't actually launch/terminate instances")
    
    args = parser.parse_args()
    
    # Override global configuration
    METRICS_BUCKET = args.bucket
    QUEUE_URL = args.queue_url
    REGION = args.region
    
    # Set up logging for local testing
    logging.basicConfig(level=logging.INFO)
    
    # Mock event and context
    event = {"source": "local-test"}
    context = type('Context', (), {'aws_request_id': 'local-test'})()
    
    # Run the handler
    result = lambda_handler(event, context)
    print(json.dumps(result, indent=2))