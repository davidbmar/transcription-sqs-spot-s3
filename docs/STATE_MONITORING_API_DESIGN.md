# State Monitoring & API Design

## 🎯 Core Design Principles

1. **S3 as State Store**: Cheap, durable, globally accessible
2. **Event-Driven Updates**: Real-time state changes 
3. **RESTful API**: Standard HTTP endpoints for querying
4. **Hierarchical State**: System → Worker → Job granularity
5. **Time-Series Data**: Historical state tracking
6. **Query Optimization**: Fast lookups via smart S3 key design

## 🏗️ S3 State Store Architecture

### Directory Structure
```
s3://transcription-state-bucket/
├── system/
│   ├── health.json                    # Overall system health
│   └── metrics/
│       ├── 2025/07/07/hourly/         # Time-series metrics
│       └── daily/
├── workers/
│   ├── active/
│   │   ├── worker-123/
│   │   │   ├── status.json            # Current status
│   │   │   ├── heartbeat.json         # Last heartbeat
│   │   │   └── jobs/
│   │   │       ├── current.json       # Currently processing
│   │   │       └── history/           # Job history
│   │   └── worker-456/
│   └── terminated/
│       └── worker-123-20250707.json   # Final state
├── jobs/
│   ├── active/
│   │   ├── job-abc123/
│   │   │   ├── state.json             # Current state
│   │   │   ├── progress.json          # Progress updates
│   │   │   ├── worker.json            # Assigned worker
│   │   │   └── timeline.json          # State transitions
│   │   └── job-def456/
│   ├── completed/
│   │   └── 2025/07/07/                # Partitioned by date
│   └── failed/
│       └── 2025/07/07/
├── queues/
│   ├── main-queue.json                # Queue statistics
│   └── dead-letter-queue.json
└── alerts/
    ├── active/
    │   ├── alert-001.json             # Active alerts
    │   └── alert-002.json
    └── resolved/
        └── 2025/07/07/
```

## 📊 State Schema Design

### Job State Schema
```json
{
  "job_id": "job-abc123",
  "state": "PROCESSING",
  "created_at": "2025-07-07T19:30:00Z",
  "updated_at": "2025-07-07T19:35:00Z",
  "estimated_completion": "2025-07-07T19:45:00Z",
  "input": {
    "s3_path": "s3://audio/file.mp3",
    "duration_seconds": 4860,
    "file_size_bytes": 75000000
  },
  "output": {
    "s3_path": "s3://transcripts/file.json",
    "segments_count": 0,
    "confidence_score": null
  },
  "worker": {
    "worker_id": "worker-123",
    "instance_id": "i-0123456789",
    "assigned_at": "2025-07-07T19:32:00Z"
  },
  "progress": {
    "percentage": 45,
    "stage": "TRANSCRIBING",
    "current_chunk": 15,
    "total_chunks": 33,
    "eta_seconds": 600
  },
  "performance": {
    "queue_time_seconds": 120,
    "processing_time_seconds": 180,
    "throughput_factor": 3.2
  },
  "state_history": [
    {
      "state": "SUBMITTED",
      "timestamp": "2025-07-07T19:30:00Z",
      "details": "Job submitted to queue"
    },
    {
      "state": "QUEUED", 
      "timestamp": "2025-07-07T19:30:05Z",
      "details": "Message in SQS queue"
    },
    {
      "state": "PROCESSING",
      "timestamp": "2025-07-07T19:32:00Z", 
      "details": "Assigned to worker-123"
    }
  ],
  "retry_info": {
    "attempt": 1,
    "max_attempts": 3,
    "last_error": null
  },
  "cost_tracking": {
    "estimated_cost_usd": 0.05,
    "actual_cost_usd": null,
    "instance_time_seconds": 180
  }
}
```

### Worker State Schema
```json
{
  "worker_id": "worker-123",
  "instance_id": "i-0123456789",
  "state": "ACTIVE",
  "created_at": "2025-07-07T19:25:00Z", 
  "last_heartbeat": "2025-07-07T19:35:00Z",
  "health": {
    "status": "HEALTHY",
    "cpu_usage": 85.5,
    "memory_usage": 65.2,
    "gpu_usage": 95.8,
    "disk_usage": 45.1
  },
  "capabilities": {
    "model": "large-v3",
    "device": "cuda",
    "gpu_optimized": true,
    "batch_size": 64
  },
  "current_job": {
    "job_id": "job-abc123",
    "started_at": "2025-07-07T19:32:00Z",
    "estimated_completion": "2025-07-07T19:45:00Z"
  },
  "performance": {
    "jobs_completed": 15,
    "total_runtime_seconds": 3600,
    "average_job_time": 240,
    "success_rate": 0.98
  },
  "location": {
    "region": "us-east-1",
    "availability_zone": "us-east-1a",
    "instance_type": "g4dn.xlarge",
    "spot_price": 0.35
  }
}
```

### System Health Schema
```json
{
  "timestamp": "2025-07-07T19:35:00Z",
  "overall_status": "HEALTHY",
  "components": {
    "queue": {
      "status": "HEALTHY",
      "messages_visible": 3,
      "messages_inflight": 2,
      "age_oldest_message": 45
    },
    "workers": {
      "status": "HEALTHY", 
      "total_count": 2,
      "healthy_count": 2,
      "active_count": 2,
      "idle_count": 0
    },
    "jobs": {
      "status": "HEALTHY",
      "total_active": 2,
      "success_rate_24h": 0.985,
      "average_completion_time": 240
    }
  },
  "alerts": [
    {
      "id": "alert-001",
      "severity": "WARNING",
      "message": "Queue depth growing",
      "created_at": "2025-07-07T19:30:00Z"
    }
  ],
  "metrics": {
    "throughput_jobs_per_hour": 45,
    "cost_per_hour_usd": 2.10,
    "efficiency_score": 0.85
  }
}
```

## 🔄 State Update Patterns

### 1. Event-Driven Updates
```python
class StateManager:
    def update_job_state(self, job_id, new_state, details=None):
        # Read current state
        current_state = self.get_job_state(job_id)
        
        # Update state with transition
        current_state['state'] = new_state
        current_state['updated_at'] = datetime.utcnow().isoformat() + 'Z'
        current_state['state_history'].append({
            'state': new_state,
            'timestamp': current_state['updated_at'],
            'details': details or f'Transitioned to {new_state}'
        })
        
        # Write atomically to S3
        self.write_state(f'jobs/active/{job_id}/state.json', current_state)
        
        # Update system-level aggregates
        self.update_system_metrics()
        
        # Trigger alerts if needed
        self.check_alert_conditions(job_id, new_state)
```

### 2. Batch State Reconciliation
```python
class StateReconciler:
    def reconcile_worker_states(self):
        # Compare S3 state vs actual AWS resources
        s3_workers = self.list_s3_workers()
        ec2_instances = self.list_ec2_instances()
        
        # Find orphaned states
        orphaned = s3_workers - ec2_instances
        for worker_id in orphaned:
            self.archive_worker_state(worker_id)
        
        # Find missing states  
        missing = ec2_instances - s3_workers
        for instance_id in missing:
            self.create_worker_state(instance_id)
```

## 🚀 API Design

### RESTful Endpoints

#### System Level
```
GET  /api/v1/system/health              # Overall system health
GET  /api/v1/system/metrics             # Current metrics
GET  /api/v1/system/alerts              # Active alerts
POST /api/v1/system/alerts/{id}/resolve # Resolve alert
```

#### Jobs
```
GET    /api/v1/jobs                     # List all jobs (paginated)
GET    /api/v1/jobs/{job_id}            # Get job details
GET    /api/v1/jobs/{job_id}/progress   # Get job progress
GET    /api/v1/jobs/{job_id}/timeline   # Get state history
POST   /api/v1/jobs                     # Submit new job
DELETE /api/v1/jobs/{job_id}            # Cancel job
```

#### Workers
```
GET  /api/v1/workers                    # List all workers
GET  /api/v1/workers/{worker_id}        # Get worker details
GET  /api/v1/workers/{worker_id}/jobs   # Get worker job history
POST /api/v1/workers/{worker_id}/restart # Restart worker
POST /api/v1/workers                    # Launch new worker
```

#### Queues
```
GET  /api/v1/queues/main               # Main queue stats
GET  /api/v1/queues/dlq                # Dead letter queue
POST /api/v1/queues/main/purge         # Purge queue
```

### Query Optimization Strategies

#### 1. Smart S3 Key Design
```
# Time-based partitioning for analytics
jobs/completed/2025/07/07/hour=19/job-abc123.json

# Status-based partitioning for operations  
jobs/active/job-abc123/state.json
jobs/failed/job-abc123/state.json

# Worker-centric organization
workers/active/worker-123/jobs/current.json
workers/active/worker-123/jobs/history/job-abc123.json
```

#### 2. Caching Strategy
```python
class StateAPI:
    def __init__(self):
        self.redis = Redis()  # Hot cache for active jobs
        self.s3 = S3Client()  # Cold storage for all states
    
    def get_job_state(self, job_id):
        # Try cache first
        cached = self.redis.get(f'job:{job_id}')
        if cached:
            return json.loads(cached)
        
        # Fallback to S3
        state = self.s3.get_object(f'jobs/active/{job_id}/state.json')
        
        # Cache for future requests
        self.redis.setex(f'job:{job_id}', 300, json.dumps(state))
        return state
```

#### 3. Aggregation Views
```python
# Pre-computed aggregations stored in S3
class AggregationManager:
    def update_hourly_metrics(self):
        # Aggregate job completion data
        hourly_stats = {
            'jobs_completed': count_completed_jobs_last_hour(),
            'average_processing_time': avg_processing_time(),
            'cost_total': sum_instance_costs(),
            'success_rate': calculate_success_rate()
        }
        
        # Store time-series data
        key = f'metrics/hourly/{datetime.now().strftime("%Y/%m/%d/%H")}.json'
        self.s3.put_object(key, hourly_stats)
```

## 📱 Client SDK Design

### Python SDK
```python
from transcription_monitor import TranscriptionAPI

api = TranscriptionAPI(
    base_url='https://api.transcription.com',
    api_key='your-api-key'
)

# Submit job
job = api.jobs.submit(
    audio_url='s3://bucket/audio.mp3',
    output_format='json',
    priority='high'
)

# Monitor progress
for update in api.jobs.watch(job.id):
    print(f"Progress: {update.percentage}% - {update.stage}")
    if update.state in ['COMPLETED', 'FAILED']:
        break

# Get system health
health = api.system.health()
if health.status != 'HEALTHY':
    print(f"Alerts: {health.alerts}")
```

### WebSocket Real-time Updates
```javascript
const ws = new WebSocket('wss://api.transcription.com/ws');

// Subscribe to job updates
ws.send(JSON.stringify({
    action: 'subscribe',
    resource: 'job',
    job_id: 'job-abc123'
}));

// Receive real-time updates
ws.onmessage = (event) => {
    const update = JSON.parse(event.data);
    updateProgressBar(update.percentage);
    showStatus(update.stage);
};
```

## 🔍 Analytics & Insights

### Cost Analytics
```sql
-- Query pattern for cost analysis
SELECT 
    DATE(completed_at) as date,
    COUNT(*) as jobs_completed,
    AVG(processing_time_seconds) as avg_time,
    SUM(cost_usd) as total_cost,
    AVG(cost_usd / duration_seconds * 60) as cost_per_minute
FROM job_states 
WHERE state = 'COMPLETED'
GROUP BY DATE(completed_at)
ORDER BY date DESC;
```

### Performance Insights
```python
class PerformanceAnalyzer:
    def analyze_bottlenecks(self):
        # Identify slow jobs
        slow_jobs = self.query_jobs(
            filter="processing_time > avg_processing_time * 2"
        )
        
        # Analyze patterns
        patterns = {
            'large_files': [j for j in slow_jobs if j.file_size > 100_000_000],
            'gpu_issues': [j for j in slow_jobs if j.worker.gpu_usage < 50],
            'network_issues': [j for j in slow_jobs if j.download_time > 300]
        }
        
        return patterns
```

This design provides:
- **Real-time state tracking** via S3 + caching
- **Scalable query patterns** with smart partitioning  
- **Event-driven updates** for immediate consistency
- **Rich analytics** for performance optimization
- **Multiple access patterns** (REST, WebSocket, SDK)
- **Cost-effective storage** using S3 lifecycle policies