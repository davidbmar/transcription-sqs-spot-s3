#!/usr/bin/env python3
"""
Queue Metrics Manager - Lightweight duration tracking using S3 JSON file
"""

import json
import logging
import boto3
from datetime import datetime
from typing import Dict, Optional
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)


class QueueMetricsManager:
    """Manages queue metrics in a lightweight S3 JSON file"""
    
    def __init__(self, s3_bucket: str, metrics_key: str = "queue-stats.json", region: str = "us-east-1"):
        """
        Initialize the queue metrics manager
        
        Args:
            s3_bucket: S3 bucket for storing metrics
            metrics_key: S3 key for the metrics file
            region: AWS region
        """
        self.s3_bucket = s3_bucket
        self.metrics_key = metrics_key
        self.region = region
        self.s3 = boto3.client('s3', region_name=region)
        
    def get_current_stats(self) -> Dict:
        """
        Get current queue statistics
        
        Returns:
            Dict containing current stats, or default values if file doesn't exist
        """
        try:
            response = self.s3.get_object(Bucket=self.s3_bucket, Key=self.metrics_key)
            data = json.loads(response['Body'].read().decode('utf-8'))
            logger.info(f"Retrieved queue stats: {data}")
            return data
        except ClientError as e:
            if e.response['Error']['Code'] == 'NoSuchKey':
                logger.info("Queue stats file doesn't exist, returning default values")
                return {
                    "total_minutes_pending": 0.0,
                    "job_count": 0,
                    "last_updated": datetime.utcnow().isoformat() + "Z"
                }
            else:
                logger.error(f"Error retrieving queue stats: {e}")
                raise
    
    def update_stats(self, minutes_delta: float = 0.0, job_count_delta: int = 0) -> Dict:
        """
        Update queue statistics atomically
        
        Args:
            minutes_delta: Change in pending minutes (positive to add, negative to subtract)
            job_count_delta: Change in job count (positive to add, negative to subtract)
            
        Returns:
            Updated stats dictionary
        """
        try:
            # Get current stats
            current_stats = self.get_current_stats()
            
            # Update values
            current_stats['total_minutes_pending'] = max(0.0, current_stats['total_minutes_pending'] + minutes_delta)
            current_stats['job_count'] = max(0, current_stats['job_count'] + job_count_delta)
            current_stats['last_updated'] = datetime.utcnow().isoformat() + "Z"
            
            # Write back to S3
            self.s3.put_object(
                Bucket=self.s3_bucket,
                Key=self.metrics_key,
                Body=json.dumps(current_stats, indent=2),
                ContentType='application/json'
            )
            
            logger.info(f"Updated queue stats: {current_stats}")
            return current_stats
            
        except Exception as e:
            logger.error(f"Error updating queue stats: {e}")
            raise
    
    def add_job(self, estimated_duration_seconds: int) -> Dict:
        """
        Add a new job to the queue metrics
        
        Args:
            estimated_duration_seconds: Estimated duration of the job in seconds
            
        Returns:
            Updated stats dictionary
        """
        minutes = estimated_duration_seconds / 60.0
        return self.update_stats(minutes_delta=minutes, job_count_delta=1)
    
    def complete_job(self, actual_duration_seconds: int) -> Dict:
        """
        Mark a job as completed and remove from queue metrics
        
        Args:
            actual_duration_seconds: Actual duration of the completed job in seconds
            
        Returns:
            Updated stats dictionary
        """
        minutes = actual_duration_seconds / 60.0
        return self.update_stats(minutes_delta=-minutes, job_count_delta=-1)
    
    def remove_job(self, estimated_duration_seconds: int) -> Dict:
        """
        Remove a job from queue metrics (for failed/cancelled jobs)
        
        Args:
            estimated_duration_seconds: Estimated duration of the job in seconds
            
        Returns:
            Updated stats dictionary
        """
        minutes = estimated_duration_seconds / 60.0
        return self.update_stats(minutes_delta=-minutes, job_count_delta=-1)
    
    def get_pending_minutes(self) -> float:
        """
        Get the total pending minutes in the queue
        
        Returns:
            Total pending minutes
        """
        stats = self.get_current_stats()
        return stats['total_minutes_pending']
    
    def get_job_count(self) -> int:
        """
        Get the total number of jobs in the queue
        
        Returns:
            Total job count
        """
        stats = self.get_current_stats()
        return stats['job_count']
    
    def reset_stats(self) -> Dict:
        """
        Reset all queue statistics to zero
        
        Returns:
            Reset stats dictionary
        """
        reset_stats = {
            "total_minutes_pending": 0.0,
            "job_count": 0,
            "last_updated": datetime.utcnow().isoformat() + "Z"
        }
        
        self.s3.put_object(
            Bucket=self.s3_bucket,
            Key=self.metrics_key,
            Body=json.dumps(reset_stats, indent=2),
            ContentType='application/json'
        )
        
        logger.info("Queue stats reset to zero")
        return reset_stats


def main():
    """Test the queue metrics manager"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Queue Metrics Manager CLI")
    parser.add_argument("--bucket", required=True, help="S3 bucket name")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--action", choices=["get", "add", "complete", "reset"], 
                       default="get", help="Action to perform")
    parser.add_argument("--duration", type=int, default=300, 
                       help="Duration in seconds (for add/complete actions)")
    
    args = parser.parse_args()
    
    # Setup logging
    logging.basicConfig(level=logging.INFO)
    
    # Create manager
    manager = QueueMetricsManager(args.bucket, region=args.region)
    
    # Perform action
    if args.action == "get":
        stats = manager.get_current_stats()
        print(json.dumps(stats, indent=2))
    elif args.action == "add":
        stats = manager.add_job(args.duration)
        print(f"Added job with {args.duration} seconds")
        print(json.dumps(stats, indent=2))
    elif args.action == "complete":
        stats = manager.complete_job(args.duration)
        print(f"Completed job with {args.duration} seconds")
        print(json.dumps(stats, indent=2))
    elif args.action == "reset":
        stats = manager.reset_stats()
        print("Reset queue stats")
        print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()