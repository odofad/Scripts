#!/usr/bin/env python3
import os
import subprocess
import json
import configparser
import logging

# Load configuration from transcode_config.conf with interpolation disabled
config = configparser.ConfigParser(interpolation=None)
config.read('transcode_config.conf')

# Validate required config sections
if 'Paths' not in config:
    raise ValueError("Configuration file must contain a [Paths] section")

# Read paths and extensions from config
INPUT_DIR = config['Paths'].get('input_dir', '/mnt/dump/2.Convert')
OUTPUT_DIR = config['Paths'].get('output_dir', '/mnt/dump/3.Converted')
LOG_FILE = config['Paths'].get('transcode_log', '/mnt/dump/logs/video_transcode.log')
VIDEO_EXTENSIONS = tuple(
    ext.strip() for ext in config['Paths'].get('video_extensions', '.mp4,.mkv,.avi,.mov,.mxf').split(',')
)

# Ensure log directory exists
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

# Configure logging to file and console
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

# FFmpeg base command with -y to overwrite
FFMPEG_BASE = [
    "ffmpeg", "-y", "-i", "{input}",
    "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "medium", "-tune", "fastdecode",
    "-vtag", "hvc1", "-c:a", "aac", "-b:a", "256k",
    "-map", "0:a", "-map", "0:v", "-threads", "0"
]

# Track processing statistics
stats = {"processed": 0, "failed": 0, "skipped": 0}

def get_video_info(file_path):
    logging.info(f"Analyzing {file_path}...")
    try:
        cmd = [
            "ffprobe", "-v", "error", "-show_streams",
            "-select_streams", "v:0", "-print_format", "json", file_path
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        probe = json.loads(result.stdout)
        
        video_stream = probe["streams"][0]
        width = int(video_stream["width"])
        height = int(video_stream["height"])
        fps = eval(video_stream.get("r_frame_rate", "30/1"))
        
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
            "license": video_stream.get("license", ""),
            "transfer": video_stream.get("color_transfer", "bt709"),
            "colormatrix": video_stream.get("color_space", "bt709")
        }
        
        if "side_data_list" in video_stream:
            for side_data in video_stream["side_data_list"]:
                if side_data.get("side_data_type") == "Mastering display metadata":
                    color_info["transfer"] = "smpte2084"
                elif side_data.get("side_data_type") == "Content light level metadata":
                    color_info["transfer"] = "smpte2084"
        
        logging.info(f"Detected: Resolution={resolution}, FPS={fps}, Color={color_info}")
        return resolution, fps, color_info
    except Exception as e:
        logging.error(f"Could not probe {file_path}: {e}")
        stats["skipped"] += 1
        return None, None, None

def calculate_bitrate(resolution, fps):
    base_bitrates = {"480p": 2000, "720p": 5000, "1080p": 10000, "4k": 35000}
    multiplier = 1.5 if fps > 30 else 1.0
    return int(base_bitrates.get(resolution, 10000) * multiplier)

def transcode_file(input_path):
    logging.info(f"Processing {input_path}...")
    
    resolution, fps, color_info = get_video_info(input_path)
    if not resolution or not fps:
        logging.warning("Skipping: Could not detect resolution or FPS")
        return

    bitrate = calculate_bitrate(resolution, fps)
    
    relative_path = os.path.relpath(input_path, INPUT_DIR)
    base_name = os.path.splitext(relative_path)[0]
    output_path = os.path.join(OUTPUT_DIR, f"{base_name}.mp4")
    output_dir = os.path.dirname(output_path)
    os.makedirs(output_dir, exist_ok=True)

    x265_params = (
        f"threads=12:level=5.1:profile=main10:ctu=64:tu-intra-depth=2:"
        f"colorprim={color_info['colorprim']}:"
        f"transfer={color_info['transfer']}:"
        f"colormatrix={color_info['colormatrix']}"
    )

    ffmpeg_cmd = FFMPEG_BASE.copy()
    ffmpeg_cmd[3] = input_path
    ffmpeg_cmd.extend(["-x265-params", x265_params])
    ffmpeg_cmd.extend(["-b:v", f"{bitrate}k", output_path])
    
    logging.info(f"Starting FFmpeg: {input_path} -> {output_path}")
    logging.info(f"Bitrate: {bitrate} kbps, Color={color_info}")
    try:
        process = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        while True:
            line = process.stdout.readline()
            if not line and process.poll() is not None:
                break
            if line:
                logging.info(line.strip())
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, ffmpeg_cmd)
        logging.info(f"Finished: {output_path}")
        stats["processed"] += 1
    except subprocess.CalledProcessError as e:
        logging.error(f"FFmpeg error: {e}")
        stats["failed"] += 1

def process_directory(input_dir):
    logging.info(f"Scanning directory: {input_dir}")
    for root, dirs, files in os.walk(input_dir):
        logging.info(f"Found directory: {root}")
        for file in files:
            logging.info(f"Found file: {file}")
            if file.lower().endswith(VIDEO_EXTENSIONS):
                input_path = os.path.join(root, file)
                transcode_file(input_path)

if __name__ == "__main__":
    logging.info(f"Starting transcoding process for all files in {INPUT_DIR}...")
    process_directory(INPUT_DIR)
    logging.info(f"Transcoding complete. Summary: Processed={stats['processed']}, Failed={stats['failed']}, Skipped={stats['skipped']}")
