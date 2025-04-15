#!/usr/bin/env python3
import os
import subprocess
import json
import configparser
import logging
from fractions import Fraction
import shutil
from pathlib import Path
import multiprocessing

# Load configuration with defaults
config = configparser.ConfigParser(interpolation=None)
CONFIG_DEFAULTS = {
    'Paths': {
        'input_dir': os.path.join(os.path.expanduser("~"), "Videos", "ToConvert"),
        'output_dir': os.path.join(os.path.expanduser("~"), "Videos", "Converted"),
        'transcode_log': os.path.join(os.path.expanduser("~"), "Videos", "Logs", "video_transcode.log"),
        'video_extensions': '.mp4,.mkv,.avi,.mov,.mxf,.flv,.wmv'
    }
}

if not os.path.exists('transcode_config.conf'):
    logging.warning("Config file not found, using defaults")
    config.read_dict(CONFIG_DEFAULTS)
else:
    config.read('transcode_config.conf')

# Validate and set paths
INPUT_DIR = Path(config['Paths'].get('input_dir', CONFIG_DEFAULTS['Paths']['input_dir']))
OUTPUT_DIR = Path(config['Paths'].get('output_dir', CONFIG_DEFAULTS['Paths']['output_dir']))
LOG_FILE = Path(config['Paths'].get('transcode_log', CONFIG_DEFAULTS['Paths']['transcode_log']))
VIDEO_EXTENSIONS = tuple(ext.strip().lower() for ext in config['Paths'].get('video_extensions', CONFIG_DEFAULTS['Paths']['video_extensions']).split(','))

# Ensure directories exist
INPUT_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

# Configure logging (append mode)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, mode='a'),
        logging.StreamHandler()
    ]
)

FFMPEG_BASE = [
    "ffmpeg", "-y", "-i", "{input}",
    "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "medium", "-tune", "fastdecode",
    "-vtag", "hvc1", "-c:a", "aac", "-b:a", "256k",
    "-map", "0:a", "-map", "0:v", "-threads", "0"
]

stats = {"processed": 0, "failed": 0, "skipped": 0}

def get_video_info(file_path):
    logging.info(f"Analyzing {file_path}...")
    # Check file size (skip if < 1 KB)
    if Path(file_path).stat().st_size < 1024:
        logging.warning(f"Skipping: File {file_path} is too small ({Path(file_path).stat().st_size} bytes)")
        stats["skipped"] += 1
        return None, None, None, None
    
    # Probe video stream
    cmd = [
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-select_streams", "v:0", "-print_format", "json", str(file_path)
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        probe = json.loads(result.stdout)
        if not probe.get("streams"):
            logging.warning(f"No video stream found in {file_path}, trying all streams")
            # Fallback: Probe all streams
            cmd = [
                "ffprobe", "-v", "error", "-show_streams", "-show_format",
                "-print_format", "json", str(file_path)
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            probe = json.loads(result.stdout)
        
        video_stream = None
        for stream in probe.get("streams", []):
            if stream.get("codec_type") == "video":
                video_stream = stream
                break
        
        if not video_stream:
            logging.error(f"No video stream found in {file_path}")
            stats["skipped"] += 1
            return None, None, None, None
        
        width = int(video_stream["width"])
        height = int(video_stream["height"])
        
        # Parse FPS safely
        fps_str = video_stream.get("r_frame_rate", "30/1")
        try:
            num, denom = map(int, fps_str.split('/'))
            fps = num / denom if denom != 0 else 30.0
        except (ValueError, ZeroDivisionError):
            logging.warning(f"Invalid FPS {fps_str}, defaulting to 30")
            fps = 30.0
        
        resolution = "unknown"
        if height <= 480:
            resolution = "480p"
        elif height <= 720:
            resolution = "720p"
        elif height <= 1080:
            resolution = "1080p"
        elif height <= 2160:
            resolution = "4k"
        
        color_info = {
            "colorprim": video_stream.get("color_primaries", "bt709"),
            "transfer": video_stream.get("color_transfer", "bt709"),
            "colormatrix": video_stream.get("color_space", "bt709")
        }
        
        if "side_data_list" in video_stream:
            for side_data in video_stream["side_data_list"]:
                if side_data.get("side_data_type") in ["Mastering display metadata", "Content light level metadata"]:
                    color_info["transfer"] = "smpte2084"
        
        # Get duration from format
        duration = float(probe.get("format", {}).get("duration", 0))
        
        logging.info(f"Detected: Resolution={resolution}, FPS={fps:.2f}, Duration={duration:.2f}s, Color={color_info}")
        return resolution, fps, color_info, duration
    except subprocess.CalledProcessError as e:
        logging.error(f"Could not probe {file_path}: {e.stderr}")
        stats["skipped"] += 1
        return None, None, None, None
    except (json.JSONDecodeError, ValueError, KeyError) as e:
        logging.error(f"Could not parse probe data for {file_path}: {e}")
        stats["skipped"] += 1
        return None, None, None, None

def is_output_valid(output_path, input_duration, resolution, fps):
    logging.info(f"Validating output file: {output_path}")
    try:
        # Check file size (minimum 100 KB)
        if output_path.stat().st_size < 100 * 1024:
            logging.warning(f"File {output_path} is too small ({output_path.stat().st_size} bytes)")
            return False
        
        cmd = [
            "ffprobe", "-v", "error", "-show_streams", "-show_format",
            "-print_format", "json", str(output_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        probe = json.loads(result.stdout)
        
        # Check for video and audio streams
        video_stream = None
        audio_stream = None
        for stream in probe.get("streams", []):
            if stream.get("codec_type") == "video":
                video_stream = stream
            elif stream.get("codec_type") == "audio":
                audio_stream = stream
        
        if not video_stream:
            logging.warning(f"No video stream found in {output_path}")
            return False
        
        if not audio_stream:
            logging.warning(f"No audio stream found in {output_path}")
            return False
        
        # Verify codecs
        if video_stream.get("codec_name") != "hevc":
            logging.warning(f"Invalid video codec {video_stream.get('codec_name')} in {output_path}, expected hevc")
            return False
        
        if audio_stream.get("codec_name") != "aac":
            logging.warning(f"Invalid audio codec {audio_stream.get('codec_name')} in {output_path}, expected aac")
            return False
        
        # Check duration (allow 0.5% tolerance)
        output_duration = float(probe.get("format", {}).get("duration", 0))
        if input_duration > 0 and output_duration < input_duration * 0.995:
            logging.warning(f"Incomplete duration {output_duration:.2f}s vs input {input_duration:.2f}s in {output_path}")
            return False
        
        # Check for basic stream integrity
        if not all(key in video_stream for key in ["width", "height", "pix_fmt"]):
            logging.warning(f"Missing essential video stream metadata in {output_path}")
            return False
        
        if not all(key in audio_stream for key in ["sample_rate", "channels"]):
            logging.warning(f"Missing essential audio stream metadata in {output_path}")
            return False
        
        # Verify approximate bitrate
        expected_bitrate = calculate_bitrate(resolution, fps)
        format_bitrate = int(probe.get("format", {}).get("bit_rate", 0)) // 1000  # Convert to kbps
        if format_bitrate < expected_bitrate * 0.5:
            logging.warning(f"Bitrate {format_bitrate} kbps too low, expected ~{expected_bitrate} kbps in {output_path}")
            return False
        
        logging.info(f"Output file {output_path} is valid and complete")
        return True
    except (subprocess.CalledProcessError, json.JSONDecodeError, ValueError, KeyError) as e:
        logging.warning(f"Output file {output_path} is invalid: {e}")
        return False

def calculate_bitrate(resolution, fps):
    base_bitrates = {"480p": 2000, "720p": 5000, "1080p": 10000, "4k": 35000}
    multiplier = 1.5 if fps > 30 else 1.0
    return int(base_bitrates.get(resolution, 10000) * multiplier)

def transcode_file(input_path):
    input_path = Path(input_path)
    logging.info(f"Processing {input_path}...")
    
    resolution, fps, color_info, input_duration = get_video_info(input_path)
    if not resolution or not fps or not input_duration:
        logging.warning("Skipping: Could not detect resolution, FPS, or duration")
        return
    
    bitrate = calculate_bitrate(resolution, fps)
    
    relative_path = input_path.relative_to(INPUT_DIR)
    output_path = OUTPUT_DIR / relative_path.with_suffix('.mp4')
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Check if output exists and is valid
    if output_path.exists():
        if is_output_valid(output_path, input_duration, resolution, fps):
            logging.info(f"Skipping: Output {output_path} is valid and complete")
            stats["skipped"] += 1
            return
        else:
            logging.info(f"Overwriting: Output {output_path} is invalid or incomplete")
            output_path.unlink()  # Remove invalid file
    
    x265_threads = min(12, multiprocessing.cpu_count())
    x265_params = (
        f"threads={x265_threads}:level=5.1:profile=main10:ctu=64:tu-intra-depth=2:"
        f"colorprim={color_info['colorprim']}:"
        f"transfer={color_info['transfer']}:"
        f"colormatrix={color_info['colormatrix']}"
    )
    
    ffmpeg_cmd = FFMPEG_BASE.copy()
    ffmpeg_cmd[3] = str(input_path)
    ffmpeg_cmd.extend(["-x265-params", x265_params])
    ffmpeg_cmd.extend(["-b:v", f"{bitrate}k", str(output_path)])
    
    logging.info(f"Starting FFmpeg: {input_path} -> {output_path}")
    logging.info(f"Bitrate: {bitrate} kbps, Color={color_info}")
    try:
        # Run FFmpeg verbosely, streaming output
        process = subprocess.Popen(
            ffmpeg_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            universal_newlines=True
        )
        # Stream FFmpeg output in real-time
        while True:
            line = process.stdout.readline()
            if not line and process.poll() is not None:
                break
            if line:
                logging.info(f"FFmpeg: {line.strip()}")
        
        return_code = process.wait()
        if return_code != 0:
            raise subprocess.CalledProcessError(return_code, ffmpeg_cmd, output="", stderr="See logged FFmpeg output")
        
        logging.info(f"Finished: {output_path}")
        stats["processed"] += 1
    except subprocess.CalledProcessError as e:
        logging.error(f"FFmpeg failed with exit code {e.returncode}")
        stats["failed"] += 1
        failed_dir = OUTPUT_DIR / "Failed"
        failed_dir.mkdir(exist_ok=True)
        shutil.move(input_path, failed_dir / input_path.name)
        logging.info(f"Moved failed file to {failed_dir / input_path.name}")

def process_directory(input_dir):
    input_dir = Path(input_dir)
    logging.info(f"Scanning directory: {input_dir}")
    for file_path in input_dir.rglob("*"):
        if file_path.is_file() and file_path.suffix.lower() in VIDEO_EXTENSIONS:
            transcode_file(file_path)

if __name__ == "__main__":
    logging.info(f"Starting transcoding process for all files in {INPUT_DIR}...")
    process_directory(INPUT_DIR)
    logging.info(f"Transcoding complete. Summary: Processed={stats['processed']}, Failed={stats['failed']}, Skipped={stats['skipped']}")