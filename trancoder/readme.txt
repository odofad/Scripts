The transcode.py script is a Python program designed to batch transcode video files using FFmpeg. Here's a concise summary of its functionality:

Reads Configuration:
Loads settings from transcode_config.conf, specifying:
Input directory (e.g., /mnt/dump/2.Convert) for source videos.
Output directory (e.g., /mnt/dump/3.Converted) for transcoded videos.
Log file path (e.g., /mnt/dump/logs/video_transcode.log) for logging.

Supported video extensions (e.g., .mp4, .mkv, .avi, .mov, .mxf, .flv, .wmv).

Scans Input Directory:
Recursively searches the input directory for video files with supported extensions.

Analyzes Videos:
Uses ffprobe to extract each video’s:
Resolution (e.g., 480p, 720p, 1080p, 4K).
Frame rate (FPS).
Color metadata (primaries, transfer, matrix, including HDR detection).

Transcodes Videos:
Uses ffmpeg to convert each video to:
Video Codec: H.265 (HEVC, 10-bit, libx265) with dynamic bitrate based on resolution and FPS (e.g., 10Mbps for 1080p at ≤30 FPS).
Audio Codec: AAC at 256kbps.
Container: MP4 with proper color metadata and fast decoding settings.
Preserves the input directory structure in the output directory.

Logs Progress:
Writes detailed logs (including FFmpeg output) to both the console and the specified log file.
Tracks and summarizes the number of files processed, failed, and skipped.

Handles Errors:
Skips files with invalid metadata or FFmpeg errors, logging the issues.
Creates output directories as needed and overwrites existing files (-y flag).
Purpose: Automates the conversion of video files to a modern, efficient format (H.265/AAC in MP4) while maintaining quality, supporting HDR, and organizing outputs, ideal for archiving or playback compatibility.

The transcode.py script has the following dependencies:

Python 3:
Required to execute the script.
Uses standard library modules only (os, subprocess, json, configparser, logging), so no additional Python packages are needed.
Version: Python 3.12 is included with Ubuntu 24.04, but any Python 3.6+ should work.

FFmpeg:
Required for video transcoding (ffmpeg) and analysis (ffprobe).
Must include support for:
libx265 (H.265/HEVC encoder).
aac (AAC audio encoder).
Common video/audio codecs for input file compatibility (e.g., H.264, MP3).
Version: The version in Ubuntu 24.04’s repositories (e.g., 6.1.1) is sufficient.

No other external libraries or tools are required. The script also expects a transcode_config.conf file, but this is a configuration file, not a dependency.

To install on ubuntu 24.04:

Install Python:
sudo apt install python3 -y

Install FFmpeg:
sudo apt install ffmpeg -y

Make script executable:
chmod +x transcode.py

Generate Config:
nano transcode_config.conf

Add the following (adjust paths if needed):

[Paths]
input_dir=/home/user/videoin
output_dir=/home/user/videoout
transcode_log=/home/user/videoout/video_transcode.log
video_extensions=.mp4,.mkv,.avi,.mov,.mxf,.flv,.wmv

Run:
./transcode.py
