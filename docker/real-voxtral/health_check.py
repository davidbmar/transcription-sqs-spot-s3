#!/usr/bin/env python3
"""
Health Check Server for Real Voxtral Container
Provides a simple HTTP health check endpoint on port 8080
"""

import json
import time
import os
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading
import torch

class HealthCheckHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            try:
                health_data = {
                    "status": "healthy",
                    "timestamp": datetime.utcnow().isoformat(),
                    "uptime": time.time() - start_time,
                    "gpu_available": torch.cuda.is_available(),
                    "worker_running": True,
                    "container_id": os.uname().nodename,
                    "service": "real-voxtral-gpu",
                    "model": "mistralai/Voxtral-Mini-3B-2507"
                }
                
                # Add GPU info if available
                if torch.cuda.is_available():
                    try:
                        health_data["gpu_count"] = torch.cuda.device_count()
                        health_data["gpu_memory"] = {
                            "allocated": torch.cuda.memory_allocated(0),
                            "reserved": torch.cuda.memory_reserved(0)
                        }
                    except:
                        pass
                
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(health_data, indent=2).encode())
                
            except Exception as e:
                error_data = {
                    "status": "unhealthy",
                    "error": str(e),
                    "timestamp": datetime.utcnow().isoformat()
                }
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(error_data).encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

def run_health_server():
    """Run the health check server"""
    server = HTTPServer(('0.0.0.0', 8080), HealthCheckHandler)
    print(f"🏥 Health check server running on port 8080")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("🏥 Health check server stopping...")
        server.shutdown()

if __name__ == "__main__":
    start_time = time.time()
    run_health_server()