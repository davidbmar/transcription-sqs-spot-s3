#!/usr/bin/env python3
"""
Health check server for Docker container
Provides HTTP endpoint for container health monitoring
"""

import http.server
import socketserver
import json
import time
import threading
import os
import subprocess
from datetime import datetime

class HealthCheckHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            health_data = {
                'status': 'healthy',
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'uptime': time.time() - start_time,
                'gpu_available': self.check_gpu(),
                'worker_running': self.check_worker_process(),
                'container_id': os.environ.get('HOSTNAME', 'unknown')
            }
            
            self.wfile.write(json.dumps(health_data, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def check_gpu(self):
        try:
            result = subprocess.run(['nvidia-smi'], capture_output=True, text=True)
            return result.returncode == 0
        except:
            return False
    
    def check_worker_process(self):
        try:
            result = subprocess.run(['pgrep', '-f', 'transcription_worker'], capture_output=True)
            return result.returncode == 0
        except:
            return False
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

start_time = time.time()

def run_health_server():
    PORT = 8080
    with socketserver.TCPServer(("", PORT), HealthCheckHandler) as httpd:
        print(f"🏥 Health check server running on port {PORT}")
        httpd.serve_forever()

if __name__ == "__main__":
    run_health_server()
