#!/usr/bin/env python3
"""
Comprehensive Transcriber Benchmark
Tests FasterWhisper, WhisperX, and Base Whisper strategies
"""

import os
import sys
import json
import time
import argparse
import boto3
from datetime import datetime
from pathlib import Path

# Add project root to path
project_root = Path(__file__).parent.parent
sys.path.append(str(project_root))

def load_config():
    """Load configuration from .env file"""
    config = {}
    env_path = project_root / '.env'
    
    if not env_path.exists():
        print("❌ Error: .env file not found")
        sys.exit(1)
    
    with open(env_path, 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.replace('export ', '').strip()] = value.strip().strip('"')
    
    return config

def get_test_audio_file():
    """Get the test audio file path"""
    # Use the 81-minute podcast for comprehensive testing
    test_file = project_root / "integration-test-new" / "mfm-episode-723.mp3"
    
    if test_file.exists():
        return str(test_file)
    
    # Fallback to downloading from S3
    config = load_config()
    s3 = boto3.client('s3', region_name=config['AWS_REGION'])
    
    test_file.parent.mkdir(exist_ok=True)
    
    try:
        print("📥 Downloading test audio file...")
        s3.download_file(
            config['AUDIO_BUCKET'],
            'integration-test-new/mfm-episode-723.mp3',
            str(test_file)
        )
        print(f"✅ Downloaded to {test_file}")
        return str(test_file)
    except Exception as e:
        print(f"❌ Failed to download test file: {e}")
        sys.exit(1)

def benchmark_transcriber(transcriber_class, transcriber_name, audio_path, config):
    """Benchmark a specific transcriber"""
    print(f"\n🔥 TESTING {transcriber_name.upper()}")
    print("=" * 50)
    
    try:
        # Initialize transcriber
        if transcriber_name == "faster-whisper":
            transcriber = transcriber_class(
                model_name="large-v3",
                device="cuda",
                compute_type="float16",
                beam_size=5
            )
        elif transcriber_name == "whisperx":
            transcriber = transcriber_class(
                model_name="large-v3",
                device="cuda",
                compute_type="float16",
                batch_size=16,
                enable_diarization=False  # Disable for speed comparison
            )
        else:  # base-whisper
            transcriber = transcriber_class(
                model_name="large-v3",
                device="cuda"
            )
        
        # Get model info
        model_info = transcriber.get_model_info()
        print(f"📋 Model Info: {json.dumps(model_info, indent=2)}")
        
        # Run transcription
        start_time = time.time()
        result = transcriber.transcribe_audio(audio_path)
        total_time = time.time() - start_time
        
        # Calculate metrics
        audio_duration = result.get('duration', 0)
        real_time_factor = audio_duration / total_time if total_time > 0 else 0
        segments_count = len(result.get('segments', []))
        
        # Performance grading
        if real_time_factor > 25:
            grade = "🚀 EXCELLENT"
            grade_score = 5
        elif real_time_factor > 10:
            grade = "✅ VERY GOOD"
            grade_score = 4
        elif real_time_factor > 5:
            grade = "✅ GOOD"
            grade_score = 3
        elif real_time_factor > 2:
            grade = "⚠️ FAIR"
            grade_score = 2
        else:
            grade = "❌ POOR"
            grade_score = 1
        
        benchmark_result = {
            "transcriber": transcriber_name,
            "model_info": model_info,
            "performance": {
                "total_time_seconds": total_time,
                "audio_duration_seconds": audio_duration,
                "real_time_factor": real_time_factor,
                "segments_count": segments_count,
                "grade": grade,
                "grade_score": grade_score,
                "processing_time": result.get('processing_time', total_time)
            },
            "transcription_result": {
                "language": result.get('language', 'unknown'),
                "language_probability": result.get('language_probability', 0.0),
                "text_length": len(result.get('text', '')),
                "has_word_timestamps": result.get('word_timestamps', False),
                "has_diarization": result.get('speaker_diarization', False),
                "text_preview": result.get('text', '')[:200] + "..." if len(result.get('text', '')) > 200 else result.get('text', '')
            },
            "timestamp": datetime.now().isoformat(),
            "test_file": os.path.basename(audio_path)
        }
        
        print(f"\n📊 RESULTS:")
        print(f"  Total Time: {total_time:.1f} seconds ({total_time/60:.1f} minutes)")
        print(f"  Audio Duration: {audio_duration:.1f} seconds ({audio_duration/60:.1f} minutes)")
        print(f"  Real-time Factor: {real_time_factor:.2f}x")
        print(f"  Segments Generated: {segments_count}")
        print(f"  Performance Grade: {grade}")
        print(f"  Language: {result.get('language', 'unknown')} ({result.get('language_probability', 0.0):.2f})")
        
        # Cleanup
        transcriber.cleanup()
        
        return benchmark_result
        
    except ImportError as e:
        print(f"❌ {transcriber_name} not available: {e}")
        return {
            "transcriber": transcriber_name,
            "error": f"ImportError: {str(e)}",
            "timestamp": datetime.now().isoformat(),
            "test_file": os.path.basename(audio_path)
        }
    except Exception as e:
        print(f"❌ {transcriber_name} failed: {e}")
        return {
            "transcriber": transcriber_name,
            "error": f"Error: {str(e)}",
            "timestamp": datetime.now().isoformat(),
            "test_file": os.path.basename(audio_path)
        }

def generate_html_report(results, output_path):
    """Generate HTML benchmark report"""
    html_content = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Transcription Benchmark Report</title>
        <style>
            body {{
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                max-width: 1200px;
                margin: 0 auto;
                padding: 20px;
                background-color: #f5f5f5;
            }}
            .header {{
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 30px;
                border-radius: 10px;
                text-align: center;
                margin-bottom: 30px;
            }}
            .summary {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
                gap: 20px;
                margin-bottom: 30px;
            }}
            .summary-card {{
                background: white;
                padding: 20px;
                border-radius: 10px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
                text-align: center;
            }}
            .transcriber-result {{
                background: white;
                margin-bottom: 30px;
                border-radius: 10px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
                overflow: hidden;
            }}
            .transcriber-header {{
                padding: 20px;
                color: white;
                text-align: center;
                font-size: 1.5em;
                font-weight: bold;
            }}
            .faster-whisper {{ background: linear-gradient(135deg, #ff6b6b, #ee5a52); }}
            .whisperx {{ background: linear-gradient(135deg, #4ecdc4, #44a08d); }}
            .base-whisper {{ background: linear-gradient(135deg, #45b7d1, #96c93d); }}
            .error {{ background: linear-gradient(135deg, #ff6b6b, #c92a2a); }}
            .content {{
                padding: 20px;
            }}
            .metrics {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 15px;
                margin-bottom: 20px;
            }}
            .metric {{
                text-align: center;
                padding: 15px;
                background: #f8f9fa;
                border-radius: 8px;
            }}
            .metric-value {{
                font-size: 2em;
                font-weight: bold;
                color: #333;
            }}
            .metric-label {{
                color: #666;
                margin-top: 5px;
            }}
            .grade {{
                font-size: 1.5em;
                padding: 10px;
                border-radius: 8px;
                text-align: center;
                margin: 15px 0;
            }}
            .grade-5 {{ background: #d4edda; color: #155724; }}
            .grade-4 {{ background: #d1ecf1; color: #0c5460; }}
            .grade-3 {{ background: #fff3cd; color: #856404; }}
            .grade-2 {{ background: #f8d7da; color: #721c24; }}
            .grade-1 {{ background: #f8d7da; color: #721c24; }}
            .comparison-table {{
                width: 100%;
                border-collapse: collapse;
                background: white;
                border-radius: 10px;
                overflow: hidden;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            }}
            .comparison-table th,
            .comparison-table td {{
                padding: 15px;
                text-align: left;
                border-bottom: 1px solid #dee2e6;
            }}
            .comparison-table th {{
                background: #343a40;
                color: white;
            }}
            .best-performer {{
                background: #d4edda !important;
                font-weight: bold;
            }}
            .transcription-preview {{
                background: #f8f9fa;
                padding: 15px;
                border-radius: 8px;
                margin-top: 15px;
                border-left: 4px solid #007bff;
            }}
            .error-message {{
                background: #f8d7da;
                color: #721c24;
                padding: 15px;
                border-radius: 8px;
                margin: 10px 0;
            }}
            .timestamp {{
                color: #666;
                font-size: 0.9em;
                text-align: center;
                margin-top: 30px;
                padding: 20px;
            }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1>🎙️ Transcription Benchmark Report</h1>
            <p>Performance comparison of Whisper implementations</p>
            <p><strong>Test Audio:</strong> {results[0].get('test_file', 'Unknown')} 
               | <strong>Generated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}</p>
        </div>
    """
    
    # Summary cards
    successful_results = [r for r in results if 'error' not in r]
    if successful_results:
        best_performer = max(successful_results, key=lambda x: x.get('performance', {}).get('real_time_factor', 0))
        avg_real_time_factor = sum(r.get('performance', {}).get('real_time_factor', 0) for r in successful_results) / len(successful_results)
        
        html_content += f"""
        <div class="summary">
            <div class="summary-card">
                <h3>🏆 Best Performer</h3>
                <div class="metric-value">{best_performer.get('transcriber', 'Unknown')}</div>
                <div class="metric-label">{best_performer.get('performance', {}).get('real_time_factor', 0):.1f}x realtime</div>
            </div>
            <div class="summary-card">
                <h3>📊 Average Performance</h3>
                <div class="metric-value">{avg_real_time_factor:.1f}x</div>
                <div class="metric-label">realtime factor</div>
            </div>
            <div class="summary-card">
                <h3>🧪 Tests Completed</h3>
                <div class="metric-value">{len(successful_results)}/{len(results)}</div>
                <div class="metric-label">transcribers tested</div>
            </div>
        </div>
        """
    
    # Individual results
    for result in results:
        transcriber_name = result.get('transcriber', 'unknown')
        
        if 'error' in result:
            html_content += f"""
            <div class="transcriber-result">
                <div class="transcriber-header error">
                    ❌ {transcriber_name.replace('-', ' ').title()}
                </div>
                <div class="content">
                    <div class="error-message">
                        <strong>Error:</strong> {result['error']}
                    </div>
                </div>
            </div>
            """
            continue
        
        performance = result.get('performance', {})
        transcription = result.get('transcription_result', {})
        
        html_content += f"""
        <div class="transcriber-result">
            <div class="transcriber-header {transcriber_name}">
                {transcriber_name.replace('-', ' ').title()}
            </div>
            <div class="content">
                <div class="metrics">
                    <div class="metric">
                        <div class="metric-value">{performance.get('real_time_factor', 0):.1f}x</div>
                        <div class="metric-label">Real-time Factor</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value">{performance.get('total_time_seconds', 0)/60:.1f}m</div>
                        <div class="metric-label">Processing Time</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value">{performance.get('segments_count', 0)}</div>
                        <div class="metric-label">Segments</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value">{transcription.get('language', 'unknown').upper()}</div>
                        <div class="metric-label">Language ({transcription.get('language_probability', 0):.2f})</div>
                    </div>
                </div>
                
                <div class="grade grade-{performance.get('grade_score', 1)}">
                    {performance.get('grade', 'Unknown')}
                </div>
                
                <div class="transcription-preview">
                    <strong>Transcription Preview:</strong><br>
                    "{transcription.get('text_preview', 'No preview available')}"
                </div>
                
                <p><strong>Features:</strong> 
                   Word timestamps: {'✅' if transcription.get('has_word_timestamps') else '❌'} | 
                   Speaker diarization: {'✅' if transcription.get('has_diarization') else '❌'}
                </p>
            </div>
        </div>
        """
    
    # Comparison table
    if successful_results:
        html_content += """
        <h2>📊 Performance Comparison</h2>
        <table class="comparison-table">
            <thead>
                <tr>
                    <th>Transcriber</th>
                    <th>Real-time Factor</th>
                    <th>Processing Time</th>
                    <th>Grade</th>
                    <th>Segments</th>
                    <th>Language</th>
                </tr>
            </thead>
            <tbody>
        """
        
        # Sort by performance
        sorted_results = sorted(successful_results, key=lambda x: x.get('performance', {}).get('real_time_factor', 0), reverse=True)
        
        for i, result in enumerate(sorted_results):
            performance = result.get('performance', {})
            transcription = result.get('transcription_result', {})
            
            row_class = "best-performer" if i == 0 else ""
            
            html_content += f"""
                <tr class="{row_class}">
                    <td>{result.get('transcriber', 'Unknown').replace('-', ' ').title()}</td>
                    <td>{performance.get('real_time_factor', 0):.2f}x</td>
                    <td>{performance.get('total_time_seconds', 0)/60:.1f} min</td>
                    <td>{performance.get('grade', 'Unknown')}</td>
                    <td>{performance.get('segments_count', 0)}</td>
                    <td>{transcription.get('language', 'unknown').upper()}</td>
                </tr>
            """
        
        html_content += """
            </tbody>
        </table>
        """
    
    html_content += f"""
        <div class="timestamp">
            Report generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}<br>
            Test completed in {sum(r.get('performance', {}).get('total_time_seconds', 0) for r in successful_results if 'error' not in r)/60:.1f} total minutes
        </div>
    </body>
    </html>
    """
    
    with open(output_path, 'w') as f:
        f.write(html_content)
    
    print(f"📄 HTML report generated: {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Benchmark all transcriber strategies')
    parser.add_argument('--output-dir', default='./benchmark_results', help='Output directory for results')
    parser.add_argument('--upload-s3', action='store_true', help='Upload results to S3')
    parser.add_argument('--audio-file', help='Custom audio file to test (defaults to 81-min podcast)')
    
    args = parser.parse_args()
    
    # Setup
    config = load_config()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(exist_ok=True)
    
    # Get test audio
    if args.audio_file:
        audio_path = args.audio_file
        if not os.path.exists(audio_path):
            print(f"❌ Audio file not found: {audio_path}")
            sys.exit(1)
    else:
        audio_path = get_test_audio_file()
    
    print(f"🎵 Test audio: {audio_path}")
    audio_size_mb = os.path.getsize(audio_path) / (1024 * 1024)
    print(f"📁 File size: {audio_size_mb:.1f} MB")
    
    # Test all transcribers
    transcribers = [
        ("faster-whisper", "transcriber_faster_whisper", "FasterWhisperTranscriber"),
        ("whisperx", "transcriber_whisperx", "WhisperXTranscriber"), 
        ("base-whisper", "transcriber_base_whisper", "BaseWhisperTranscriber")
    ]
    
    results = []
    total_start_time = time.time()
    
    for transcriber_name, module_name, class_name in transcribers:
        try:
            # Dynamic import
            module = __import__(f'src.{module_name}', fromlist=[class_name])
            transcriber_class = getattr(module, class_name)
            
            result = benchmark_transcriber(transcriber_class, transcriber_name, audio_path, config)
            results.append(result)
            
        except ImportError as e:
            print(f"⚠️ Skipping {transcriber_name}: {e}")
            results.append({
                "transcriber": transcriber_name,
                "error": f"Module not available: {str(e)}",
                "timestamp": datetime.now().isoformat(),
                "test_file": os.path.basename(audio_path)
            })
        except Exception as e:
            print(f"❌ Error testing {transcriber_name}: {e}")
            results.append({
                "transcriber": transcriber_name,
                "error": f"Unexpected error: {str(e)}",
                "timestamp": datetime.now().isoformat(),
                "test_file": os.path.basename(audio_path)
            })
    
    total_time = time.time() - total_start_time
    
    # Save results
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    
    # JSON results
    json_file = output_dir / f"benchmark_results_{timestamp}.json"
    with open(json_file, 'w') as f:
        json.dump({
            "metadata": {
                "timestamp": datetime.now().isoformat(),
                "test_file": os.path.basename(audio_path),
                "total_benchmark_time": total_time,
                "audio_file_size_mb": audio_size_mb
            },
            "results": results
        }, f, indent=2)
    
    print(f"💾 JSON results saved: {json_file}")
    
    # HTML report
    html_file = output_dir / f"benchmark_report_{timestamp}.html"
    generate_html_report(results, html_file)
    
    # Upload to S3 if requested
    if args.upload_s3:
        try:
            s3 = boto3.client('s3', region_name=config['AWS_REGION'])
            
            # Upload JSON
            s3_json_key = f"benchmarks/reports/benchmark_results_{timestamp}.json"
            s3.upload_file(str(json_file), config['METRICS_BUCKET'], s3_json_key)
            
            # Upload HTML
            s3_html_key = f"benchmarks/reports/benchmark_report_{timestamp}.html"
            s3.upload_file(str(html_file), config['METRICS_BUCKET'], s3_html_key, 
                          ExtraArgs={'ContentType': 'text/html'})
            
            print(f"☁️ Results uploaded to S3:")
            print(f"  JSON: s3://{config['METRICS_BUCKET']}/{s3_json_key}")
            print(f"  HTML: s3://{config['METRICS_BUCKET']}/{s3_html_key}")
            
        except Exception as e:
            print(f"⚠️ Failed to upload to S3: {e}")
    
    # Summary
    print(f"\n🎉 BENCHMARK COMPLETED")
    print(f"Total time: {total_time/60:.1f} minutes")
    print(f"Results saved to: {output_dir}")
    
    successful_results = [r for r in results if 'error' not in r]
    if successful_results:
        best = max(successful_results, key=lambda x: x.get('performance', {}).get('real_time_factor', 0))
        print(f"🏆 Best performer: {best.get('transcriber')} ({best.get('performance', {}).get('real_time_factor', 0):.1f}x)")

if __name__ == '__main__':
    main()