#!/usr/bin/env python3
"""
Test Dual Container Architecture
Demonstrates Whisper + Voxtral running simultaneously
"""

import asyncio
import aiohttp
import time
import json

async def test_whisper(audio_file_path):
    """Test Whisper container (port 8001)"""
    try:
        async with aiohttp.ClientSession() as session:
            with open(audio_file_path, 'rb') as f:
                data = aiohttp.FormData()
                data.add_field('file', f, filename='test.mp3')
                
                start_time = time.time()
                async with session.post('http://3.137.152.9:8001/transcribe', data=data) as resp:
                    result = await resp.json()
                    end_time = time.time()
                    
                    return {
                        "model": "whisper",
                        "result": result,
                        "duration": end_time - start_time,
                        "status": "success"
                    }
    except Exception as e:
        return {
            "model": "whisper", 
            "error": str(e),
            "status": "failed"
        }

async def test_voxtral(audio_file_path):
    """Test Voxtral container (port 8000)"""
    try:
        async with aiohttp.ClientSession() as session:
            with open(audio_file_path, 'rb') as f:
                data = aiohttp.FormData()
                data.add_field('file', f, filename='test.mp3')
                
                start_time = time.time()
                async with session.post('http://3.137.152.9:8000/transcribe', data=data) as resp:
                    result = await resp.json()
                    end_time = time.time()
                    
                    return {
                        "model": "voxtral",
                        "result": result, 
                        "duration": end_time - start_time,
                        "status": "success"
                    }
    except Exception as e:
        return {
            "model": "voxtral",
            "error": str(e), 
            "status": "failed"
        }

async def test_parallel_processing():
    """Test both containers processing same audio in parallel"""
    audio_file = "/home/ubuntu/transcription-sqs-spot-s3/test-audio/test_30sec.mp3"
    
    print("🚀 Testing Dual Container Architecture")
    print("=" * 50)
    
    # Launch both tasks in parallel
    start_time = time.time()
    
    whisper_task = test_whisper(audio_file)
    voxtral_task = test_voxtral(audio_file)
    
    # Wait for both to complete
    whisper_result, voxtral_result = await asyncio.gather(
        whisper_task, 
        voxtral_task,
        return_exceptions=True
    )
    
    total_time = time.time() - start_time
    
    # Display results
    print(f"⏱️  Total parallel time: {total_time:.2f}s")
    print()
    
    print("📝 Whisper Results:")
    if whisper_result["status"] == "success":
        print(f"   Time: {whisper_result['duration']:.2f}s")
        print(f"   Text: {whisper_result['result'].get('text', 'N/A')[:100]}...")
    else:
        print(f"   Error: {whisper_result['error']}")
    
    print()
    print("🧠 Voxtral Results:")
    if voxtral_result["status"] == "success":
        print(f"   Time: {voxtral_result['duration']:.2f}s") 
        print(f"   Text: {voxtral_result['result'].get('text', 'N/A')[:100]}...")
    else:
        print(f"   Error: {voxtral_result['error']}")
    
    print()
    print("📊 Performance Analysis:")
    if whisper_result["status"] == "success" and voxtral_result["status"] == "success":
        sequential_time = whisper_result['duration'] + voxtral_result['duration']
        speedup = sequential_time / total_time
        print(f"   Sequential would take: {sequential_time:.2f}s")
        print(f"   Parallel took: {total_time:.2f}s")
        print(f"   Speedup: {speedup:.1f}x")
        
        print()
        print("🎯 User Experience:")
        print(f"   Transcription ready in: {whisper_result['duration']:.2f}s")
        print(f"   Analysis ready in: {total_time:.2f}s")
        print(f"   User can start reading transcript {total_time - whisper_result['duration']:.1f}s before analysis finishes")

if __name__ == "__main__":
    asyncio.run(test_parallel_processing())