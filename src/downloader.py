#!/usr/bin/python3
#downloader.py - YouTube Downloader with Fallbacks

import os
import subprocess
import logging
import re
import time

logger = logging.getLogger(__name__)

class DownloadError(Exception):
    """Exception raised for errors during download"""
    pass

class TokenError(DownloadError):
    """Exception raised for YouTube token errors"""
    pass

class NetworkError(DownloadError):
    """Exception raised for network-related errors"""
    pass

class YouTubeDownloader:
    """Downloads audio from YouTube videos with fallback mechanisms"""
    
    def __init__(self, temp_dir="./temp"):
        """Initialize the downloader"""
        self.temp_dir = temp_dir
        os.makedirs(temp_dir, exist_ok=True)
    
    def download(self, youtube_url, output_dir):
        """
        Download audio from YouTube URL with fallback mechanisms
        
        Args:
            youtube_url: YouTube video URL
            output_dir: Directory to save the downloaded audio
            
        Returns:
            Path to downloaded MP4 audio file
            
        Raises:
            DownloadError: If all download methods fail
        """
        os.makedirs(output_dir, exist_ok=True)
        output_file = os.path.join(output_dir, "audio.mp4")
        
        # Try multiple download methods with backoff
        methods = [
            self._download_with_ytdlp,
            self._download_with_pytube,
        ]
        
        last_error = None
        for attempt, method in enumerate(methods, 1):
            try:
                logger.info(f"Download attempt {attempt}/{len(methods)} using {method.__name__}")
                return method(youtube_url, output_file)
            except Exception as e:
                last_error = e
                logger.warning(f"Download method {method.__name__} failed: {str(e)}")
                # Small delay between attempts
                time.sleep(2)
        
        # All methods failed
        error_msg = f"All download methods failed for {youtube_url}: {str(last_error)}"
        logger.error(error_msg)
        raise DownloadError(error_msg)
    
    def _download_with_ytdlp(self, youtube_url, output_file):
        """Download using yt-dlp (most reliable)"""
        try:
            result = subprocess.run([
                "yt-dlp", 
                "-f", "bestaudio[ext=m4a]", 
                "-o", output_file,
                youtube_url
            ], capture_output=True, text=True, check=False)
            
            # Check for errors in the output
            if result.returncode != 0:
                error_output = result.stderr.lower()
                
                # Categorize errors for smarter retries
                if "forbidden" in error_output or "token" in error_output:
                    raise TokenError(f"YouTube token error: {result.stderr}")
                elif "network" in error_output or "connection" in error_output:
                    raise NetworkError(f"Network error: {result.stderr}")
                else:
                    raise DownloadError(f"yt-dlp error (code {result.returncode}): {result.stderr}")
            
            if not os.path.exists(output_file):
                raise DownloadError("yt-dlp did not produce output file")
                
            return output_file
            
        except subprocess.SubprocessError as e:
            raise DownloadError(f"yt-dlp subprocess error: {str(e)}")
    
    def _download_with_pytube(self, youtube_url, output_file):
        """Download using PyTubeFix (fallback)"""
        try:
            from pytubefix import YouTube
            yt = YouTube(youtube_url)
            audio_stream = yt.streams.filter(only_audio=True).first()
            
            if not audio_stream:
                raise DownloadError("No audio stream found")
                
            # Extract directory and filename
            output_dir = os.path.dirname(output_file)
            filename = os.path.basename(output_file)
            
            # Download to the specified location
            audio_stream.download(output_path=output_dir, filename=filename)
            
            if not os.path.exists(output_file):
                raise DownloadError("PyTubeFix did not produce output file")
                
            return output_file
            
        except Exception as e:
            error_msg = str(e).lower()
            
            # Categorize errors for smarter retries
            if "token" in error_msg or "botguard" in error_msg:
                raise TokenError(f"YouTube token error: {str(e)}")
            elif "network" in error_msg or "connection" in error_msg:
                raise NetworkError(f"Network error: {str(e)}")
            else:
                raise DownloadError(f"PyTubeFix error: {str(e)}")
    
    def convert_to_wav(self, input_file, output_dir=None):
        """
        Convert MP4 audio to WAV format
        
        Args:
            input_file: Path to MP4 audio file
            output_dir: Directory to save WAV file (defaults to same as input)
            
        Returns:
            Path to WAV audio file
        """
        if output_dir is None:
            output_dir = os.path.dirname(input_file)
            
        output_file = os.path.join(output_dir, "audio.wav")
        
        try:
            # Run ffmpeg with reduced output
            result = subprocess.run([
                "ffmpeg", "-y", "-i", input_file, output_file
            ], capture_output=True, text=True, check=False)
            
            if result.returncode != 0:
                raise Exception(f"ffmpeg error (code {result.returncode}): {result.stderr}")
                
            if not os.path.exists(output_file):
                raise Exception("ffmpeg did not produce output file")
                
            return output_file
            
        except Exception as e:
            logger.error(f"Error converting to WAV: {str(e)}")
            raise
    
    def extract_video_id(self, youtube_url):
        """Extract video ID from YouTube URL"""
        match = re.search(r'(?:v=|\/)([0-9A-Za-z_-]{11}).*', youtube_url)
        if match:
            return match.group(1)
        
        # If we can't extract, return a portion of the URL hash
        import hashlib
        return hashlib.md5(youtube_url.encode()).hexdigest()[:11]


# Example usage
if __name__ == "__main__":
    # Simple test code
    logging.basicConfig(level=logging.INFO)
    
    downloader = YouTubeDownloader()
    try:
        video_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"  # Test video
        temp_dir = "./temp/test"
        
        # Extract video ID
        video_id = downloader.extract_video_id(video_url)
        print(f"Video ID: {video_id}")
        
        # Download audio
        mp4_file = downloader.download(video_url, temp_dir)
        print(f"Downloaded MP4: {mp4_file}")
        
        # Convert to WAV
        wav_file = downloader.convert_to_wav(mp4_file)
        print(f"Converted WAV: {wav_file}")
        
    except Exception as e:
        print(f"Error: {str(e)}")
