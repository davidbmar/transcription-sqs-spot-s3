#!/usr/bin/env python3

import os
import logging
from datetime import datetime
from src.transcriber import Transcriber

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def transcribe_local_audio(audio_path, s3_bucket=None, region="us-east-2", use_gpu=True):
    device = "cuda" if use_gpu else "cpu"

    logger.info(f"Initializing Whisper transcriber on device: {device}")

    transcriber = Transcriber(
        model_name="small.en",
        device=device,
        chunk_size=30,
        s3_bucket=s3_bucket,
        region=region
    )

    logger.info(f"Transcribing audio file: {audio_path}")

    try:
        transcription = transcriber.resume_transcription(
            audio_file=audio_path,
            job_id="local_test",
            job_tracker=None,
            video_id="local_audio"
        )
        logger.info("Transcription completed successfully.")

        # Print transcription result to console
        for segment in transcription.get("segments", []):
            logger.info(f"[{segment['start']:.2f}s - {segment['end']:.2f}s]: {segment['text']}")

        return transcription

    except Exception as e:
        logger.error(f"Error during transcription: {str(e)}")
        return None

if __name__ == "__main__":
    # Modify this path to point to your local audio file
    audio_file_path = "./audio.wav"

    if not os.path.exists(audio_file_path):
        logger.error(f"Audio file '{audio_file_path}' does not exist.")
        exit(1)

    transcribe_local_audio(audio_file_path)


