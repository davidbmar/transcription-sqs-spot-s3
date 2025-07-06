#!/usr/bin/python3
# This is job_tracker.py - S3-based Job Tracking

import json
import time
import uuid
import logging
from datetime import datetime, timedelta
import boto3
import os

logger = logging.getLogger(__name__)

class JobState:
    """Job state constants"""
    QUEUED = "queued"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"

class JobTracker:
    """Simple S3-based job tracking system"""
    
    def __init__(self, s3_bucket, region="us-east-1"):
        """Initialize the job tracker with S3 bucket"""
        self.s3_bucket = s3_bucket
        self.s3 = boto3.client('s3', region_name=region)
        self.worker_id = f"worker-{uuid.uuid4()}"
    
    def create_job(self, job_id, video_id, youtube_url, phrase):
        """Create a new job in the queued state"""
        job = {
            "job_id": job_id,
            "video_id": video_id,
            "youtube_url": youtube_url,
            "phrase": phrase,
            "status": JobState.QUEUED,
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "attempts": 0,
            "error": None
        }
        
        self._save_job(job, JobState.QUEUED)
        return job
    
    def start_processing(self, job_id, worker_id=None):
        """Mark a job as being processed by this worker"""
        job = self.get_job(job_id)
        if not job:
            return None
            
        # Move from queued to processing
        if job.get("status") == JobState.QUEUED:
            self._delete_job(job_id, JobState.QUEUED)
        
        # Update job status
        job["status"] = JobState.PROCESSING
        job["worker_id"] = worker_id or self.worker_id
        job["updated_at"] = datetime.now().isoformat()
        job["lock_until"] = (datetime.now() + timedelta(minutes=10)).isoformat()
        
        self._save_job(job, JobState.PROCESSING)
        return job
    
    def update_progress(self, job_id, total_chunks=None, completed_chunks=None):
        """Update job progress"""
        job = self.get_job_by_status(job_id, JobState.PROCESSING)
        if not job:
            return False
            
        job["updated_at"] = datetime.now().isoformat()
        job["lock_until"] = (datetime.now() + timedelta(minutes=10)).isoformat()
        
        if total_chunks is not None:
            job["total_chunks"] = total_chunks
            
        if completed_chunks is not None:
            job["completed_chunks"] = completed_chunks
            
        self._save_job(job, JobState.PROCESSING)
        return True
    
    def complete_job(self, job_id):
        """Mark job as completed"""
        job = self.get_job_by_status(job_id, JobState.PROCESSING)
        if not job:
            return False
            
        # Remove from processing
        self._delete_job(job_id, JobState.PROCESSING)
        
        # Update and save to completed
        job["status"] = JobState.COMPLETED
        job["updated_at"] = datetime.now().isoformat()
        job["completed_at"] = datetime.now().isoformat()
        
        self._save_job(job, JobState.COMPLETED)
        return True
    
    def fail_job(self, job_id, error):
        """Mark job as failed with error info"""
        job = self.get_job(job_id)
        if not job:
            return False
            
        # Remove from current status
        current_status = job.get("status", JobState.QUEUED)
        self._delete_job(job_id, current_status)
        
        # Update and save to failed
        job["status"] = JobState.FAILED
        job["updated_at"] = datetime.now().isoformat()
        job["error"] = str(error)
        job["attempts"] = job.get("attempts", 0) + 1
        
        self._save_job(job, JobState.FAILED)
        return True
    
    def get_job(self, job_id):
        """Get job from any status folder"""
        for status in [JobState.QUEUED, JobState.PROCESSING, JobState.COMPLETED, JobState.FAILED]:
            job = self.get_job_by_status(job_id, status)
            if job:
                return job
        return None
    
    def get_job_by_status(self, job_id, status):
        """Get job from specific status folder"""
        key = f"jobs/{status}/{job_id}.json"
        try:
            response = self.s3.get_object(Bucket=self.s3_bucket, Key=key)
            job_data = json.loads(response['Body'].read().decode('utf-8'))
            return job_data
        except self.s3.exceptions.NoSuchKey:
            return None
        except Exception as e:
            logger.error(f"Error getting job {job_id}: {str(e)}")
            return None
    
    def list_jobs_by_status(self, status):
        """List all jobs with a specific status"""
        try:
            prefix = f"jobs/{status}/"
            response = self.s3.list_objects_v2(
                Bucket=self.s3_bucket,
                Prefix=prefix
            )
            
            jobs = []
            if 'Contents' in response:
                for item in response['Contents']:
                    job_id = os.path.basename(item['Key']).replace('.json', '')
                    job = self.get_job_by_status(job_id, status)
                    if job:
                        jobs.append(job)
            return jobs
        except Exception as e:
            logger.error(f"Error listing jobs: {str(e)}")
            return []
    
    def find_abandoned_jobs(self):
        """Find processing jobs with expired locks"""
        processing_jobs = self.list_jobs_by_status(JobState.PROCESSING)
        abandoned_jobs = []
        
        for job in processing_jobs:
            lock_until = job.get('lock_until')
            if not lock_until:
                abandoned_jobs.append(job)
                continue
                
            try:
                lock_time = datetime.fromisoformat(lock_until)
                if lock_time < datetime.now():
                    abandoned_jobs.append(job)
            except:
                # If we can't parse the time, consider it abandoned
                abandoned_jobs.append(job)
                
        return abandoned_jobs
    
    def recover_abandoned_jobs(self):
        """Recover abandoned jobs if they're not over max attempts"""
        abandoned_jobs = self.find_abandoned_jobs()
        recovered = 0
        
        for job in abandoned_jobs:
            # Check if we should retry
            attempts = job.get("attempts", 0)
            if attempts >= 3:  # Max 3 attempts
                # Move to failed
                self._delete_job(job["job_id"], JobState.PROCESSING)
                job["status"] = JobState.FAILED
                job["updated_at"] = datetime.now().isoformat()
                job["error"] = "Exceeded maximum retry attempts"
                self._save_job(job, JobState.FAILED)
                logger.info(f"Job {job['job_id']} exceeded max attempts, marked as failed")
            else:
                # Move back to queued for retry
                self._delete_job(job["job_id"], JobState.PROCESSING)
                job["status"] = JobState.QUEUED
                job["updated_at"] = datetime.now().isoformat()
                job["attempts"] = attempts + 1
                self._save_job(job, JobState.QUEUED)
                logger.info(f"Recovered job {job['job_id']} for retry (attempt {attempts + 1})")
                recovered += 1
                
        return recovered
    
    def _save_job(self, job, status):
        """Save job data to S3"""
        job_id = job["job_id"]
        key = f"jobs/{status}/{job_id}.json"
        
        try:
            self.s3.put_object(
                Body=json.dumps(job),
                Bucket=self.s3_bucket,
                Key=key,
                ContentType="application/json"
            )
            return True
        except Exception as e:
            logger.error(f"Error saving job {job_id}: {str(e)}")
            return False
    
    def _delete_job(self, job_id, status):
        """Delete job data from S3"""
        key = f"jobs/{status}/{job_id}.json"
        
        try:
            self.s3.delete_object(
                Bucket=self.s3_bucket,
                Key=key
            )
            return True
        except Exception as e:
            logger.error(f"Error deleting job {job_id}: {str(e)}")
            return False


# Example usage
if __name__ == "__main__":
    # Simple test code
    logging.basicConfig(level=logging.INFO)
    
    # Create job tracker (for testing only)
    tracker = JobTracker("test-bucket")
    
    # Create a job
    job_id = str(uuid.uuid4())
    job = tracker.create_job(
        job_id=job_id,
        video_id="abc123",
        youtube_url="https://www.youtube.com/watch?v=abc123",
        phrase="test phrase"
    )
    
    # Start processing
    tracker.start_processing(job_id)
    
    # Update progress
    tracker.update_progress(job_id, total_chunks=10, completed_chunks=5)
    
    # Complete job
    tracker.complete_job(job_id)
