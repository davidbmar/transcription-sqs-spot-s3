# Error Handling & Job Management Design

## 🎯 Design Goals

1. **Detect failures quickly** (within 2-5 minutes)
2. **Automatic recovery** for transient issues
3. **Dead letter queue** for persistent failures  
4. **Notifications** for human intervention
5. **Cost optimization** (terminate failed instances)
6. **Debugging support** (detailed logs and state)

## 🏗️ Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Main Queue    │    │   Worker Pool    │    │  Dead Letter    │
│                 │    │                  │    │     Queue       │
│  ┌───────────┐  │    │  ┌─────────────┐ │    │  ┌───────────┐  │
│  │   Job 1   │──┼────┼─▶│   Worker 1  │ │    │  │ Failed Job│  │
│  └───────────┘  │    │  └─────────────┘ │    │  └───────────┘  │
│  ┌───────────┐  │    │  ┌─────────────┐ │    │                 │
│  │   Job 2   │──┼────┼─▶│   Worker 2  │ │    │                 │
│  └───────────┘  │    │  └─────────────┘ │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                        ▲
         │                       │                        │
         ▼                       ▼                        │
┌─────────────────┐    ┌──────────────────┐               │
│  Job Monitor    │    │  Worker Monitor  │               │
│  - Stuck jobs   │    │  - Heartbeats    │               │
│  - Timeouts     │    │  - Health checks │               │
│  - Progress     │    │  - Auto-scaling  │               │
└─────────────────┘    └──────────────────┘               │
         │                       │                        │
         └───────────────────────┼────────────────────────┘
                                 │
                        ┌──────────────────┐
                        │  Alert System    │
                        │  - Slack/Email   │
                        │  - Auto-remediation │
                        │  - Escalation    │
                        └──────────────────┘
```

## 🔧 Component Design

### 1. Enhanced SQS Configuration
```json
{
  "VisibilityTimeout": 3600,     // 1 hour for long jobs
  "MessageRetentionPeriod": 1209600, // 14 days
  "ReceiveMessageWaitTimeSeconds": 20, // Long polling
  "RedrivePolicy": {
    "deadLetterTargetArn": "arn:aws:sqs:region:account:transcription-dlq",
    "maxReceiveCount": 3         // Retry 3 times before DLQ
  }
}
```

### 2. Job State Machine
```
SUBMITTED → QUEUED → PROCESSING → COMPLETED
    │          │         │            │
    │          │         ▼            ▼
    │          │      FAILED      SUCCESS
    │          │         │
    │          ▼         ▼
    └─────► DEAD_LETTER
```

### 3. Worker Health Monitoring
- **Heartbeat**: Every 30 seconds to S3
- **Progress Updates**: Real-time to S3
- **Timeout Detection**: No heartbeat for 5 minutes = dead worker
- **Resource Monitoring**: CPU, Memory, GPU utilization

### 4. Failure Categories

#### A. Transient Failures (Auto-Retry)
- Network timeouts
- Temporary S3 access issues
- GPU memory spikes
- Instance interruptions

#### B. Permanent Failures (Dead Letter Queue)
- Corrupted audio files
- Unsupported formats
- Missing S3 objects
- Worker crashes after 3 retries

#### C. System Failures (Alert + Auto-Remediate)
- All workers dead
- Queue backlog growing
- Spot instance interruptions
- Dependency failures

## 📊 Monitoring & Alerting

### Real-time Dashboards
1. **Queue Health**: Message counts, age, throughput
2. **Worker Status**: Active workers, processing times, errors
3. **Job Progress**: Success rate, failure rate, average time
4. **Cost Tracking**: Instance costs, efficiency metrics

### Alert Conditions
```python
ALERT_CONDITIONS = {
    "stuck_jobs": {
        "condition": "job_age > 30_minutes AND status != COMPLETED",
        "severity": "HIGH",
        "action": "kill_job_and_worker"
    },
    "dead_workers": {
        "condition": "no_heartbeat > 5_minutes",
        "severity": "HIGH", 
        "action": "terminate_instance"
    },
    "queue_backlog": {
        "condition": "queue_size > 10 AND no_workers",
        "severity": "CRITICAL",
        "action": "launch_workers"
    },
    "high_failure_rate": {
        "condition": "failure_rate > 20% over 1_hour",
        "severity": "MEDIUM",
        "action": "investigate"
    }
}
```

## 🛠️ Auto-Remediation Actions

### 1. Stuck Job Recovery
```python
def handle_stuck_job(job_id, worker_id):
    # 1. Mark job as failed in progress tracking
    progress_logger.update(job_id, "FAILED", "Job stuck - auto-killed")
    
    # 2. Terminate the worker instance
    ec2.terminate_instances(InstanceIds=[worker_id])
    
    # 3. Return message to queue for retry
    sqs.change_message_visibility(ReceiptHandle=receipt_handle, VisibilityTimeout=0)
    
    # 4. Alert operations team
    send_alert(f"Killed stuck job {job_id} on worker {worker_id}")
```

### 2. Dead Worker Recovery
```python
def handle_dead_worker(worker_id):
    # 1. Terminate the instance
    ec2.terminate_instances(InstanceIds=[worker_id])
    
    # 2. Check queue depth
    queue_depth = get_queue_depth()
    
    # 3. Launch replacement if needed
    if queue_depth > 0:
        launch_spot_worker()
    
    # 4. Update monitoring
    update_worker_status(worker_id, "TERMINATED_DEAD")
```

### 3. Auto-Scaling Logic
```python
def auto_scale_workers():
    queue_depth = get_queue_depth()
    active_workers = count_active_workers()
    
    if queue_depth > active_workers * 2:
        # Launch more workers
        workers_needed = min(queue_depth // 2, MAX_WORKERS)
        for _ in range(workers_needed - active_workers):
            launch_spot_worker()
    
    elif queue_depth == 0 and active_workers > 0:
        # Scale down after idle timeout
        idle_workers = get_idle_workers(threshold_minutes=60)
        for worker in idle_workers:
            terminate_worker(worker)
```

## 📝 Implementation Plan

### Phase 1: Basic Error Detection (Week 1)
- [ ] Enhanced worker heartbeats
- [ ] Job timeout detection
- [ ] Dead letter queue setup
- [ ] Basic alerting

### Phase 2: Auto-Remediation (Week 2)  
- [ ] Stuck job killer
- [ ] Dead worker cleanup
- [ ] Auto-scaling logic
- [ ] Progress recovery

### Phase 3: Advanced Monitoring (Week 3)
- [ ] Real-time dashboard
- [ ] Predictive scaling
- [ ] Cost optimization
- [ ] Performance analytics

## 🔍 Key Metrics to Track

### Operational Metrics
- **Job Success Rate**: 99%+ target
- **Average Processing Time**: Baseline per file type
- **Queue Depth**: < 5 jobs during normal hours
- **Worker Utilization**: 70-90% target

### Cost Metrics
- **Cost per Minute Transcribed**: Track efficiency
- **Spot Instance Savings**: vs On-Demand pricing
- **Failed Job Cost**: Money lost on retries

### Performance Metrics
- **GPU Utilization**: 80%+ during processing
- **Throughput**: Jobs per hour
- **Time to Process**: 99th percentile latency

## 🚨 Notification Channels

### Immediate Alerts (< 5 minutes)
- Slack webhook for critical issues
- PagerDuty for after-hours emergencies
- Auto-remediation logs

### Daily Summaries
- Email reports with metrics
- Cost analysis and trends
- Performance recommendations

### Weekly Reviews
- Failure pattern analysis
- Capacity planning
- System optimization opportunities

This design provides robust error handling while maintaining cost efficiency and operational simplicity.