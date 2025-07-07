#!/usr/bin/env python3
"""
Progress Logger - Writes detailed progress updates to S3 for monitoring
"""

import json
import boto3
import time
from datetime import datetime
import os

class ProgressLogger:
    """Log progress updates to S3 for real-time monitoring"""
    
    def __init__(self, s3_bucket, job_id, region="us-east-1"):
        self.s3_bucket = s3_bucket
        self.job_id = job_id
        self.s3 = boto3.client('s3', region_name=region)
        self.progress_key = f"progress/{job_id}/status.json"
        self.log_key = f"progress/{job_id}/detailed_log.txt"
        self.start_time = time.time()
        self.logs = []
        
    def update(self, status, message, percentage=None, chunk_info=None):
        """Update progress status in S3"""
        try:
            elapsed = time.time() - self.start_time
            timestamp = datetime.now().isoformat()
            
            # Create progress update
            progress_data = {
                "job_id": self.job_id,
                "status": status,
                "message": message,
                "percentage": percentage,
                "elapsed_seconds": elapsed,
                "timestamp": timestamp,
                "last_update": timestamp
            }
            
            if chunk_info:
                progress_data["chunk_info"] = chunk_info
            
            # Log entry
            log_entry = f"[{timestamp}] [{elapsed:.1f}s] {status}: {message}"
            if percentage:
                log_entry += f" ({percentage}%)"
            if chunk_info:
                log_entry += f" - Chunk {chunk_info['current']}/{chunk_info['total']}"
            
            self.logs.append(log_entry)
            
            # Write progress JSON
            self.s3.put_object(
                Bucket=self.s3_bucket,
                Key=self.progress_key,
                Body=json.dumps(progress_data, indent=2),
                ContentType="application/json"
            )
            
            # Write detailed log
            self.s3.put_object(
                Bucket=self.s3_bucket,
                Key=self.log_key,
                Body="\n".join(self.logs),
                ContentType="text/plain"
            )
            
            print(log_entry)
            
        except Exception as e:
            print(f"Failed to update progress: {e}")
    
    def complete(self, success=True, result_data=None):
        """Mark job as complete"""
        status = "COMPLETED" if success else "FAILED"
        message = "Transcription completed successfully" if success else "Transcription failed"
        
        if result_data:
            percentage = 100
            message += f" - {result_data.get('segments', 0)} segments generated"
        else:
            percentage = 0
            
        self.update(status, message, percentage)