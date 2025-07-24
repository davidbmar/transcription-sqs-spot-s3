# Fast API S3-Enhanced Transcription Usage Guide

## 🎯 Overview

The S3-enhanced Fast API provides three different endpoints for audio transcription:
- **S3 to S3**: Direct S3 bucket input/output
- **URL input**: HTTP/HTTPS URLs (including presigned S3 URLs)  
- **File upload**: Traditional file upload (backward compatible)

## 📊 Performance Results

### Recent Test Results:
- **30-second audio**: ~1 second (32x real-time)
- **Large podcast (281MB)**: ~8 minutes (estimated 13x real-time)
- **Output**: Full transcript with timestamps in JSON format

## 🚀 API Endpoints

### 1. S3 to S3 Transcription (`/transcribe-s3`)

**Use when**: You have audio files in S3 and want results saved to S3

```bash
curl -X POST http://18.116.238.163:8000/transcribe-s3 \
  -H "Content-Type: application/json" \
  -d '{
    "s3_input_path": "s3://your-bucket/audio.mp3",
    "s3_output_path": "s3://your-bucket/transcript.json",  
    "return_text": true
  }'
```

**Parameters**:
- `s3_input_path` (required): S3 URI like `s3://bucket/path/file.mp3`
- `s3_output_path` (optional): S3 URI for output. If provided, saves JSON to S3
- `return_text` (optional): If `false`, only returns status (useful for fire-and-forget)

**Response**:
```json
{
  "s3_input_path": "s3://bucket/audio.mp3",
  "text": "Full transcription text...",
  "chunks": [...],
  "device": "cuda",
  "model": "openai/whisper-base",
  "timestamp": "2025-07-24T04:56:09.786654",
  "s3_output_path": "s3://bucket/transcript.json"
}
```

### 2. URL Transcription (`/transcribe-url`)

**Use when**: You have HTTP/HTTPS URLs (including presigned S3 URLs)

```bash
curl -X POST http://18.116.238.163:8000/transcribe-url \
  -H "Content-Type: application/json" \
  -d '{
    "audio_url": "https://example.com/podcast.mp3"
  }'
```

**Parameters**:
- `audio_url` (required): Any HTTP/HTTPS URL to audio file

**Response**:
```json
{
  "source_url": "https://example.com/podcast.mp3",
  "text": "Full transcription text...",
  "chunks": [...],
  "device": "cuda", 
  "model": "openai/whisper-base"
}
```

### 3. File Upload (`/transcribe`)

**Use when**: You have local files to upload

```bash
curl -X POST -F 'file=@audio.mp3' http://18.116.238.163:8000/transcribe
```

**Response**:
```json
{
  "filename": "audio.mp3",
  "text": "Full transcription text...",
  "chunks": [...],
  "device": "cuda",
  "model": "openai/whisper-base"
}
```

## 📝 Real Example

### Successful Large File Test:
```bash
# Input: s3://dbm-cf-2-web/integration-test/lex_ai_dhh_david_heinemeier_hansson.mp3
# Size: 281MB podcast
# Processing time: ~8 minutes
# Output: 1.29MB JSON with 359,220 characters and 6,095 timestamp chunks

curl -X POST http://18.116.238.163:8000/transcribe-s3 \
  -H "Content-Type: application/json" \
  -d '{
    "s3_input_path": "s3://dbm-cf-2-web/integration-test/lex_ai_dhh_david_heinemeier_hansson.mp3",
    "s3_output_path": "s3://dbm-cf-2-web/integration-test/lex_ai_dhh_david_heinemeier_hansson.json",
    "return_text": false
  }'
```

## 🔍 Health Check

```bash
curl http://18.116.238.163:8000/health
```

**Response**:
```json
{
  "status": "healthy",
  "timestamp": "2025-07-24T04:45:37.863413", 
  "gpu_available": true,
  "device": "cuda",
  "s3_enabled": true
}
```

Note: `s3_enabled: true` confirms this is the S3-enhanced version.

## 📚 Interactive Documentation

Visit the auto-generated Swagger docs: http://18.116.238.163:8000/docs

## ⚠️ Important Notes

1. **S3 URIs**: Must use exact format `s3://bucket-name/path/file.ext`
2. **HTTP URLs**: Use `/transcribe-url` endpoint, not `/transcribe-s3`
3. **Large files**: May take several minutes, API will wait for completion
4. **GPU acceleration**: ~13x real-time speed on Tesla T4
5. **Supported formats**: MP3, WAV, FLAC, M4A (converts via ffmpeg)

## 🔧 Deployment

Current instance: `http://18.116.238.163:8000`
Container tag: `latest-s3` (S3-enhanced version)
Image includes: boto3, requests, and all three API endpoints

To deploy your own:
```bash
./scripts/step-300-fast-api-smart-deploy.sh --tag=latest-s3
```