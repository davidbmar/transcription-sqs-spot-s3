# Command Line vs Lambda Interface Design

## 🤔 Two Approaches for Monitoring Interface

### Approach 1: Command Line Interface (CLI)
### Approach 2: Lambda API + CLI Client

Let's compare them for your use case...

## 🖥️ Approach 1: Direct CLI Interface

### Architecture
```
Developer/Ops → CLI Script → AWS Services (CloudWatch/S3/SQS)
```

### Implementation
```bash
# Simple Python CLI script
./transcription-monitor --status              # Overall system status
./transcription-monitor --jobs                # List active jobs  
./transcription-monitor --workers             # List active workers
./transcription-monitor --job-id abc123       # Specific job details
./transcription-monitor --stuck               # Find stuck jobs
./transcription-monitor --kill-job abc123     # Kill stuck job
./transcription-monitor --health-check        # System health check
```

### Code Example
```python
#!/usr/bin/env python3
# transcription-monitor CLI tool

import boto3
import click
import json
from datetime import datetime, timedelta

@click.group()
def cli():
    """Transcription System Monitor"""
    pass

@cli.command()
def status():
    """Show overall system status"""
    # Query CloudWatch logs for recent activity
    logs = boto3.client('logs')
    
    # Get job starts in last hour
    response = logs.filter_log_events(
        logGroupName='/aws/ec2/transcription',
        startTime=int((datetime.now() - timedelta(hours=1)).timestamp() * 1000),
        filterPattern='JOB_START'
    )
    
    jobs_started = len(response['events'])
    
    # Get job completions
    response = logs.filter_log_events(
        logGroupName='/aws/ec2/transcription', 
        startTime=int((datetime.now() - timedelta(hours=1)).timestamp() * 1000),
        filterPattern='JOB_COMPLETE'
    )
    
    jobs_completed = len(response['events'])
    
    click.echo(f"📊 System Status (Last Hour)")
    click.echo(f"Jobs Started: {jobs_started}")
    click.echo(f"Jobs Completed: {jobs_completed}")
    click.echo(f"Success Rate: {jobs_completed/jobs_started*100 if jobs_started > 0 else 0:.1f}%")

@cli.command()
@click.option('--job-id', help='Specific job ID')
def jobs(job_id):
    """List active jobs or get specific job details"""
    if job_id:
        # Get specific job timeline
        logs = boto3.client('logs')
        response = logs.filter_log_events(
            logGroupName='/aws/ec2/transcription',
            filterPattern=f'job_id={job_id}'
        )
        
        click.echo(f"📋 Job Timeline: {job_id}")
        for event in response['events']:
            timestamp = datetime.fromtimestamp(event['timestamp']/1000)
            click.echo(f"  {timestamp}: {event['message']}")
    else:
        # List all active jobs
        # Implementation here...
        pass

@cli.command()
def stuck():
    """Find stuck jobs"""
    logs = boto3.client('logs')
    
    # Find jobs that started but didn't complete
    cutoff_time = int((datetime.now() - timedelta(minutes=30)).timestamp() * 1000)
    
    started_jobs = logs.filter_log_events(
        logGroupName='/aws/ec2/transcription',
        startTime=cutoff_time,
        filterPattern='JOB_START'
    )
    
    # Extract job IDs and check for completion
    stuck_jobs = []
    for event in started_jobs['events']:
        # Parse job_id from log message
        # Check if there's a corresponding JOB_COMPLETE
        # Add to stuck_jobs if not completed
        pass
    
    if stuck_jobs:
        click.echo("⚠️ Stuck Jobs Found:")
        for job in stuck_jobs:
            click.echo(f"  - {job['job_id']} (stuck for {job['duration']} minutes)")
    else:
        click.echo("✅ No stuck jobs found")

if __name__ == '__main__':
    cli()
```

### Pros ✅
- **Simple**: Direct AWS API calls
- **Fast**: No API latency
- **Flexible**: Easy to add new commands
- **Local**: Works from any machine with AWS credentials
- **No Infrastructure**: No servers to maintain

### Cons ❌
- **AWS Credentials Required**: Each user needs AWS access
- **Limited Sharing**: Can't easily share with non-technical users
- **No Caching**: Repeated calls to AWS APIs
- **Rate Limits**: Could hit CloudWatch API limits

---

## ☁️ Approach 2: Lambda API + CLI Client

### Architecture
```
Developer/Ops → CLI Client → API Gateway → Lambda → AWS Services
```

### Implementation
```python
# Lambda function (transcription-monitor-api)
import json
import boto3

def lambda_handler(event, context):
    action = event['pathParameters']['action']
    
    if action == 'status':
        return get_system_status()
    elif action == 'jobs':
        return get_jobs()
    elif action == 'stuck':
        return find_stuck_jobs()
    elif action == 'kill-job':
        job_id = event['queryStringParameters']['job_id']
        return kill_stuck_job(job_id)
    
def get_system_status():
    # Same logic as CLI but in Lambda
    logs = boto3.client('logs')
    # ... implementation
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'jobs_started': jobs_started,
            'jobs_completed': jobs_completed,
            'success_rate': success_rate
        })
    }
```

```python
# CLI client (calls Lambda API)
import requests
import click

API_BASE = 'https://api.transcription.com/monitor'

@click.group()
def cli():
    """Transcription Monitor CLI"""
    pass

@cli.command()
def status():
    """Show system status"""
    response = requests.get(f'{API_BASE}/status')
    data = response.json()
    
    click.echo(f"📊 System Status")
    click.echo(f"Jobs Started: {data['jobs_started']}")
    click.echo(f"Jobs Completed: {data['jobs_completed']}")
    click.echo(f"Success Rate: {data['success_rate']:.1f}%")

@cli.command()
@click.option('--job-id', required=True)
def kill_job(job_id):
    """Kill a stuck job"""
    response = requests.post(f'{API_BASE}/kill-job', json={'job_id': job_id})
    if response.status_code == 200:
        click.echo(f"✅ Job {job_id} killed successfully")
    else:
        click.echo(f"❌ Failed to kill job: {response.text}")
```

### Pros ✅
- **Centralized**: Single API for all services
- **Scalable**: Can handle many concurrent requests
- **Cacheable**: Can cache results for performance
- **Secure**: API authentication/authorization
- **Shareable**: Web dashboard, mobile apps, etc.
- **Cross-Service**: Other services can use same API

### Cons ❌
- **Complex**: More infrastructure to maintain
- **Latency**: API call overhead
- **Cost**: Lambda + API Gateway costs
- **Dependencies**: API must be running

---

## 🎯 **Recommendation: Start with CLI, Upgrade to Lambda**

### Phase 1: CLI First (Week 1)
```bash
# Immediate value, minimal complexity
pip install transcription-monitor
transcription-monitor --stuck
transcription-monitor --kill-job abc123
```

### Phase 2: Add Lambda API (Month 2+)
```bash
# Same CLI, but backed by API
transcription-monitor --stuck  # Now calls Lambda API
```

### Why This Approach?

**Week 1 Needs:**
- You need monitoring **now**
- CLI gives immediate value
- Simple to implement and debug

**Future Needs:**
- Other services might need monitoring
- Web dashboard for non-technical users
- Mobile alerts/notifications

## 🛠️ **Implementation Plan**

### Immediate (Week 1): CLI Tool
```python
# transcription-monitor (single Python file)
#!/usr/bin/env python3

import boto3, click, json
from datetime import datetime, timedelta

# 5-10 commands for essential monitoring
# Direct AWS API calls
# ~200 lines of code
```

**Benefits:**
- ✅ **1 day to implement**
- ✅ **Immediate debugging value**
- ✅ **No infrastructure overhead**
- ✅ **Works from anywhere**

### Future (Month 2): Lambda API
```python
# Wrap existing CLI logic in Lambda functions
# Add API Gateway for HTTP interface
# Keep same CLI interface (now calls API)
```

**Benefits:**
- ✅ **Reuse existing CLI logic**
- ✅ **Enable other services to use**
- ✅ **Foundation for web dashboard**

## 📋 **Essential CLI Commands to Build**

```bash
# Must-have commands
transcription-monitor status           # System overview
transcription-monitor jobs --active    # Active jobs
transcription-monitor jobs --stuck     # Stuck jobs  
transcription-monitor kill --job-id X  # Kill stuck job
transcription-monitor workers          # Worker health
transcription-monitor logs --job-id X  # Job logs

# Nice-to-have commands  
transcription-monitor costs            # Cost analysis
transcription-monitor performance      # Performance metrics
transcription-monitor alerts          # Active alerts
```

**Start with the CLI approach - you'll get immediate value and can always add the Lambda API layer later when you need cross-service access.**

Want me to implement the CLI tool first?