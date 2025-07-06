#!/usr/bin/python3
import os
import re
import logging
from typing import List, Dict, Any
import json
from datetime import datetime

logger = logging.getLogger(__name__)

class PhraseScanner:
    """Scans transcripts for phrases and analyzes results"""
    
    def __init__(self, phrase, case_sensitive=False):
        """
        Initialize the phrase scanner
        
        Args:
            phrase: The phrase to search for
            case_sensitive: Whether to perform case-sensitive matching
        """
        self.phrase = phrase
        self.case_sensitive = case_sensitive
    
    def scan_file(self, transcript_file):
        """
        Scan a single transcript file for occurrences of the phrase
        
        Args:
            transcript_file: Path to transcript text file
            
        Returns:
            Dict with scan results for the file
        """
        # Extract segment number from filename
        segment_name = os.path.basename(transcript_file)
        segment_num = int(segment_name.split('_')[1].split('.')[0])
        
        try:
            with open(transcript_file, "r", encoding="utf-8") as f:
                content = f.read()
                
            # Compile the pattern for the search
            pattern = re.escape(self.phrase)
            flags = 0 if self.case_sensitive else re.IGNORECASE
            
            # Find all occurrences
            occurrences = re.findall(pattern, content, flags)
            count = len(occurrences)
            
            # Calculate some basic stats
            words = content.split()
            word_count = len(words)
            char_count = len(content)
            
            # Return the results for this file
            return {
                "filename": segment_name,
                "minute": segment_num + 1,
                "occurrences": count,
                "word_count": word_count,
                "char_count": char_count,
                "has_phrase": count > 0
            }
            
        except Exception as e:
            logger.error(f"Error scanning transcript {transcript_file}: {str(e)}")
            
            # Return limited information on error
            return {
                "filename": segment_name,
                "minute": segment_num + 1,
                "occurrences": 0,
                "error": str(e)
            }
    
    def scan_directory(self, transcript_dir):
        """
        Scan all transcript files in a directory
        
        Args:
            transcript_dir: Directory containing transcript files
            
        Returns:
            Dict with aggregated scan results
        """
        # Find transcript files
        files = [f for f in os.listdir(transcript_dir) if f.startswith("segment_") and f.endswith(".txt")]
        files = sorted(files)
        
        if not files:
            logger.warning(f"No transcript files found in {transcript_dir}")
            return {"total_occurrences": 0, "segments": [], "error": "No transcript files found"}
        
        # Scan each file
        results = []
        total_occurrences = 0
        total_words = 0
        total_chars = 0
        segments_with_phrase = []
        
        for filename in files:
            file_path = os.path.join(transcript_dir, filename)
            file_result = self.scan_file(file_path)
            
            # Add to totals
            if "occurrences" in file_result:
                total_occurrences += file_result["occurrences"]
                
            if "word_count" in file_result:
                total_words += file_result["word_count"]
                
            if "char_count" in file_result:
                total_chars += file_result["char_count"]
                
            # Track segments that contain the phrase
            if file_result.get("has_phrase", False):
                segments_with_phrase.append(file_result)
            
            results.append(file_result)
        
        # Calculate duration based on segments
        video_duration_sec = len(files) * 60  # Assuming 60-second segments
        
        # Aggregate results
        return {
            "phrase": self.phrase,
            "case_sensitive": self.case_sensitive,
            "video_duration_sec": video_duration_sec,
            "video_duration_min": video_duration_sec / 60,
            "total_occurrences": total_occurrences,
            "total_words": total_words,
            "total_chars": total_chars,
            "segments": results,
            "segments_with_phrase": segments_with_phrase,
            "scanned_at": datetime.now().isoformat()
        }
    
    def scan_transcripts(self, transcript_files):
        """
        Scan a list of transcript files
        
        Args:
            transcript_files: List of paths to transcript files
            
        Returns:
            Dict with aggregated scan results
        """
        if not transcript_files:
            logger.warning("No transcript files provided")
            return {"total_occurrences": 0, "segments": [], "error": "No transcript files provided"}
            
        # Group files by directory to handle segments properly
        files_by_dir = {}
        for file_path in transcript_files:
            dir_path = os.path.dirname(file_path)
            
            if dir_path not in files_by_dir:
                files_by_dir[dir_path] = []
                
            files_by_dir[dir_path].append(file_path)
        
        # Scan each directory
        all_results = []
        for dir_path, files in files_by_dir.items():
            # Determine transcript directory
            transcript_dir = dir_path
            
            # Get just the filenames
            filenames = [os.path.basename(f) for f in files]
            
            # Filter to ensure we only process transcript files
            transcript_files = [f for f in filenames if f.startswith("segment_") and f.endswith(".txt")]
            
            if transcript_files:
                # Create full paths
                file_paths = [os.path.join(transcript_dir, f) for f in transcript_files]
                
                # Scan each file
                results = []
                total_occurrences = 0
                total_words = 0
                total_chars = 0
                segments_with_phrase = []
                
                for file_path in file_paths:
                    file_result = self.scan_file(file_path)
                    
                    # Add to totals
                    total_occurrences += file_result.get("occurrences", 0)
                    total_words += file_result.get("word_count", 0)
                    total_chars += file_result.get("char_count", 0)
                    
                    # Track segments that contain the phrase
                    if file_result.get("has_phrase", False):
                        segments_with_phrase.append(file_result)
                    
                    results.append(file_result)
                
                # Calculate duration based on segments
                video_duration_sec = len(transcript_files) * 60  # Assuming 60-second segments
                
                # Aggregate results
                dir_result = {
                    "directory": dir_path,
                    "phrase": self.phrase,
                    "case_sensitive": self.case_sensitive,
                    "video_duration_sec": video_duration_sec,
                    "video_duration_min": video_duration_sec / 60,
                    "total_occurrences": total_occurrences,
                    "total_words": total_words,
                    "total_chars": total_chars,
                    "segments": results,
                    "segments_with_phrase": segments_with_phrase,
                    "scanned_at": datetime.now().isoformat()
                }
                
                all_results.append(dir_result)
        
        # Return all results (typically just one if all files are in the same directory)
        if len(all_results) == 1:
            return all_results[0]
        else:
            return {"directories": all_results}
    
    def to_json(self, scan_results, indent=2):
        """Convert scan results to JSON string"""
        return json.dumps(scan_results, indent=indent)
    
    def save_results(self, scan_results, output_file):
        """Save scan results to JSON file"""
        try:
            with open(output_file, "w", encoding="utf-8") as f:
                json.dump(scan_results, f, indent=2)
                
            logger.info(f"Saved scan results to {output_file}")
            return True
            
        except Exception as e:
            logger.error(f"Error saving scan results: {str(e)}")
            return False


# Example usage
if __name__ == "__main__":
    # Simple test code
    logging.basicConfig(level=logging.INFO)
    
    try:
        # Create a scanner
        scanner = PhraseScanner("example")
        
        # Define a test directory with transcripts
        test_dir = "./temp/transcripts"
        
        # Create a test transcript if needed
        os.makedirs(test_dir, exist_ok=True)
        test_file = os.path.join(test_dir, "segment_000.txt")
        
        with open(test_file, "w", encoding="utf-8") as f:
            f.write("This is an example transcript with the word example appearing twice as an example.")
        
        # Scan the directory
        results = scanner.scan_directory(test_dir)
        
        # Print the results
        print(json.dumps(results, indent=2))
        
        # Save to file
        scanner.save_results(results, os.path.join(test_dir, "results.json"))
        
    except Exception as e:
        print(f"Error: {str(e)}")
