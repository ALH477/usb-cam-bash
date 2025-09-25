#!/bin/bash

# Optimized FFmpeg recording script for Linux laptops (optimized for NixOS and similar)
# Records raw footage from multiple USB cameras (dynamically detected via v4l2-ctl) and audio from a USB mic (dynamically detected).
# Outputs to separate files: one AVI/MKV per video stream (AVI for raw copy, MKV for compressed) and one audio file (WAV for raw PCM or FLAC for lossless).
# "Raw footage" here means capturing without re-encoding where possible (-c:v copy), but falls back to lossless FFV1 for efficiency (default).
# Adjust resolution, etc., based on your setup.
# To check camera formats: v4l2-ctl -d /dev/video0 --list-formats-ext
# On NixOS: Ensure sound.enable = true; and hardware.pulseaudio.enable = true; (or pipewire) in configuration.nix for audio.
# Run with: ./record.sh [base_name] [--raw] [--duration SECONDS] [--config config.json] (default base: recording)
# --raw: Uses raw copy mode (AVI); default is lossless FFV1 in MKV.
# --duration: Auto-stop after specified seconds (overrides manual stop).
# --config: Path to JSON config file (overrides defaults).
# Recordings start simultaneously in background. Press 'q' and Enter to stop all recordings cleanly.
# Added: Prompt to preview live footage in separate windows using ffplay.
# Added: Prompt to auto-detect max resolution and FPS for each camera using v4l2-ctl.
# Added: Prompt to add overlay text (default: "DeMoD LLC") with timestamp underneath (requires re-encoding to FFV1 lossless).
# Improvements: Dependency checks, font file validation, multiple audio selection, enhanced stop logic, duration support.
# New: Outputs saved to script's directory. Confirmation prompts for camera specs and end session. Default mono font.
# Default: FFV1 codec in MKV container for lossless video.
# Enhanced: Final confirmation prompt ensures session end and file saving. JSON config parsing with jq. Preview/recording conflict warning.
# New: Prompt for preview scale (e.g., 0.5 for half size) to reduce load.

# Dependency checks
REQUIRED_CMDS=("ffmpeg" "v4l2-ctl")
OPTIONAL_CMDS=("ffplay" "pactl" "arecord" "lsusb" "udevadm" "jq")
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' not found. Install it via your package manager (e.g., apt install $cmd)."
    exit 1
  fi
done
for cmd in "${OPTIONAL_CMDS[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Warning: Optional command '$cmd' not found. Some features may be limited."
  fi
done

# Default configuration
DEFAULT_FRAMERATE=30
DEFAULT_VIDEO_SIZE="1920x1080"
INPUT_FORMAT="mjpeg"
THREAD_QUEUE_SIZE=1024
USE_RAW=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_NAME="${1:-recording}"
DURATION=""
CONFIG_FILE=""
OVERLAY_TEXT=""
FONT_FILE="/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
DEFAULT_OVERLAY_TEXT="DeMoD LLC"
AUDIO_SKIP=false
PREVIEW_SCALE=1.0  # Default full scale

# Parse arguments
shift  # Consume base_name
while [[ $# -gt 0 ]]; do
  case $1 in
    --raw)
      USE_RAW=true
      shift
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Load JSON config if provided and jq available
if [ -n "$CONFIG_FILE" ] && command -v jq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
  echo "Loading config from $CONFIG_FILE..."
  DEFAULT_FRAMERATE=$(jq -r '.default_framerate // '"$DEFAULT_FRAMERATE"'' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_FRAMERATE")
  DEFAULT_VIDEO_SIZE=$(jq -r '.default_video_size // '"$DEFAULT_VIDEO_SIZE"'' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_VIDEO_SIZE")
  INPUT_FORMAT=$(jq -r '.input_format // '"$INPUT_FORMAT"'' "$CONFIG_FILE" 2>/dev/null || echo "$INPUT_FORMAT")
  THREAD_QUEUE_SIZE=$(jq -r '.thread_queue_size // '"$THREAD_QUEUE_SIZE"'' "$CONFIG_FILE" 2>/dev/null || echo "$THREAD_QUEUE_SIZE")
  FONT_FILE=$(jq -r '.font_file // '"$FONT_FILE"'' "$CONFIG_FILE" 2>/dev/null || echo "$FONT_FILE")
  DEFAULT_OVERLAY_TEXT=$(jq -r '.default_overlay_text // '"$DEFAULT_OVERLAY_TEXT"'' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_OVERLAY_TEXT")
  echo "Config loaded successfully."
else
  if [ -n "$CONFIG_FILE" ]; then
    echo "Warning: Config file '$CONFIG_FILE' not found or jq unavailable. Using defaults."
  fi
fi

# Determine video extension and format based on USE_RAW
if [ "$USE_RAW" = true ]; then
  VIDEO_EXT="avi"
  VIDEO_FORMAT="-f avi"
else
  VIDEO_EXT="mkv"
  VIDEO_FORMAT="-f matroska"  # Use full name to avoid alias issues
fi

# Map INPUT_FORMAT to v4l2-ctl FOURCC
case "$INPUT_FORMAT" in
  mjpeg) FOURCC="'MJPG'" ;;
  yuyv422) FOURCC="'YUYV'" ;;
  *) echo "Unsupported INPUT_FORMAT: $INPUT_FORMAT. Defaulting to MJPG."; FOURCC="'MJPG'" ;;
esac

# Function to get max resolution and FPS for a device and format
get_max_res_fps() {
  local DEV=$1
  local OUTPUT=$(v4l2-ctl -d "$DEV" --list-formats-ext 2>/dev/null)
  if [ -z "$OUTPUT" ]; then
    echo "$DEFAULT_VIDEO_SIZE $DEFAULT_FRAMERATE"
    return
  fi

  # Awk script to parse max area size and its max FPS under the matching format
  echo "$OUTPUT" | awk -v fourcc="$FOURCC" '
  BEGIN { max_area=0; max_size=""; max_fps=0; in_format=0; current_size=""; current_area=0; current_max_fps=0 }
  /Pixel Format: / { if ($3 == fourcc) { in_format=1 } else { in_format=0 } }
  in_format && /Size: Discrete/ { current_size=$3; split($3, dims, "x"); current_area=dims[1]*dims[2]; current_max_fps=0 }
  in_format && /Interval: Discrete/ { match($4, /\(([0-9.]+)/, arr); fps=arr[1]+0; if (fps > current_max_fps) current_max_fps=fps }
  in_format && current_size != "" && current_max_fps > 0 {
    if (current_area > max_area) {
      max_area = current_area;
      max_size = current_size;
      max_fps = current_max_fps;
    }
  }
  END { if (max_size != "") print max_size, max_fps; else print "'"$DEFAULT_VIDEO_SIZE"'", '"$DEFAULT_FRAMERATE"' }
  '
}

# Dynamically detect USB cameras using v4l2-ctl (more accurate than lsusb for mapping to /dev/videoX)
VIDEO_DEVICES=($(v4l2-ctl --list-devices 2>/dev/null | awk '/\(usb-/{getline; if ($1 ~ /^\/dev\/video/) print $1}'))

# Check if any cameras found
if [ ${#VIDEO_DEVICES[@]} -eq 0 ]; then
  echo "No USB cameras detected via v4l2-ctl. Falling back to lsusb scan (less reliable)."
  if command -v lsusb &> /dev/null; then
    USB_CAMERAS=$(lsusb -v 2>/dev/null | grep -B 10 "bInterfaceClass.*14 Video" | grep "Bus" | awk '{print $2 ":" $4}')
    if [ -n "$USB_CAMERAS" ]; then
      echo "Detected potential USB cameras via lsusb: $USB_CAMERAS"
      # Improved fallback: Probe /dev/video* for USB-linked devices via udevadm
      PROBED_DEVICES=()
      for dev in /dev/video*; do
        if command -v udevadm &> /dev/null && udevadm info --query=all --name="$dev" 2>/dev/null | grep -q "ID_BUS=usb"; then  # USB check via udev
          PROBED_DEVICES+=("$dev")
        fi
      done
      if [ ${#PROBED_DEVICES[@]} -gt 0 ]; then
        VIDEO_DEVICES=("${PROBED_DEVICES[@]}")
        echo "Probed USB-linked video devices: ${VIDEO_DEVICES[@]}"
      else
        # Fallback to sequential
        NUM_CAMS=$(echo "$USB_CAMERAS" | wc -l)
        for i in $(seq 0 $((NUM_CAMS-1))); do
          VIDEO_DEVICES+=("/dev/video$i")
        done
      fi
    else
      echo "No cameras found via lsusb either."
      exit 1
    fi
  else
    echo "lsusb not available; no fallback detection possible."
    exit 1
  fi
fi

echo "Detected USB cameras: ${VIDEO_DEVICES[@]}"

# Dynamically detect USB microphone with selection if multiple
AUDIO_DEVICE="default"
AUDIO_FORMAT="pulse"  # Default to PulseAudio
AUDIO_OPTIONS=()

if command -v pactl &> /dev/null; then
  # PulseAudio available
  AUDIO_OPTIONS=($(pactl list short sources 2>/dev/null | grep -i '\.usb' | awk '{print $2 " (" $1 ")"}'))  # Include index for display
  if [ ${#AUDIO_OPTIONS[@]} -gt 0 ]; then
    echo "Detected USB mics via PulseAudio:"
    for i in "${!AUDIO_OPTIONS[@]}"; do
      echo "  $i: ${AUDIO_OPTIONS[$i]}"
    done
    if [ ${#AUDIO_OPTIONS[@]} -gt 1 ]; then
      read -p "Select mic index (0-${#AUDIO_OPTIONS[@]}-1, default 0): " sel
      [ -z "$sel" ] && sel=0
      AUDIO_DEVICE=$(echo "${AUDIO_OPTIONS[$sel]}" | awk '{print $1}')
    else
      AUDIO_DEVICE="${AUDIO_OPTIONS[0]}"
    fi
    echo "Selected USB mic: $AUDIO_DEVICE"
  else
    echo "No USB mic detected via PulseAudio; using default."
  fi
else
  # Fallback to ALSA
  AUDIO_FORMAT="alsa"
  USB_CARDS=($(arecord -l 2>/dev/null | grep -i '^card [0-9]\+:.*usb' | awk '{print substr($2,1,length($2)-1)}'))  # Get card numbers for USB
  if [ ${#USB_CARDS[@]} -gt 0 ]; then
    echo "Detected USB mics via ALSA (cards: ${USB_CARDS[*]})."
    if [ ${#USB_CARDS[@]} -gt 1 ]; then
      read -p "Select card number (default ${USB_CARDS[0]}): " sel_card
      [ -z "$sel_card" ] && sel_card="${USB_CARDS[0]}"
      AUDIO_DEVICE="hw:$sel_card,0"
    else
      AUDIO_DEVICE="hw:${USB_CARDS[0]},0"
    fi
    echo "Selected USB mic: $AUDIO_DEVICE"
  else
    AUDIO_DEVICE="hw:0,0"
    echo "No USB mic detected via ALSA; using default hw:0,0."
  fi
fi

# If still default and ALSA, adjust
if [ "$AUDIO_FORMAT" = "alsa" ] && [ "$AUDIO_DEVICE" = "default" ]; then
  AUDIO_DEVICE="hw:0,0"
fi

# Test audio device
echo "Testing audio device $AUDIO_DEVICE..."
TEST_CMD="ffmpeg -f $AUDIO_FORMAT -i $AUDIO_DEVICE -t 1 -f null - 2>/dev/null"
if eval "$TEST_CMD"; then
  echo "Audio device test successful."
else
  echo "Audio device test failed (No such file or directory or similar)."
  SKIP_ANS=$(prompt_yn "Skip audio recording?" "y")
  if [ "$SKIP_ANS" = "y" ]; then
    AUDIO_SKIP=true
    echo "Audio recording skipped."
  else
    echo "Proceeding with audio despite test failure (may error at runtime)."
  fi
fi

# Optional: Fallback lsusb for audio if no mic detected (less reliable)
if [ "$AUDIO_DEVICE" = "default" ] || [ "$AUDIO_DEVICE" = "hw:0,0" ]; then
  if command -v lsusb &> /dev/null; then
    USB_MICS=$(lsusb -v 2>/dev/null | grep -B 10 "bInterfaceClass.*1 Audio" | grep "Bus" | awk '{print $2 ":" $4}')
    if [ -n "$USB_MICS" ]; then
      echo "Detected potential USB mics via lsusb: $USB_MICS (manual configuration may be needed for device mapping)."
    fi
  fi
fi

# Determine codecs and formats based on USE_RAW
if [ "$USE_RAW" = true ]; then
  VIDEO_CODEC="-c:v copy"
  AUDIO_CODEC="-c:a pcm_s16le"
  AUDIO_FORMAT_OPT="-f wav"
  AUDIO_EXT="wav"
else
  VIDEO_CODEC="-c:v ffv1"  # Default lossless FFV1 codec
  AUDIO_CODEC="-c:a flac"
  AUDIO_FORMAT_OPT="-f flac"
  AUDIO_EXT="flac"
fi

# Function for y/n prompt with loop
prompt_yn() {
  local prompt="$1"
  local default="$2"
  while true; do
    read -p "$prompt (y/n, default $default): " ans
    [ -z "$ans" ] && ans="$default"
    case "$ans" in
      [Yy]* ) echo "y"; return ;;
      [Nn]* ) echo "n"; return ;;
      * ) echo "Please answer y or n."; ;;
    esac
  done
}

# Prompt for auto-detect
AUTO_DETECT_ANS=$(prompt_yn "Auto-detect max resolution and FPS for each camera?" "n")
AUTO_DETECT=false
if [ "$AUTO_DETECT_ANS" = "y" ]; then
  AUTO_DETECT=true
fi

# Arrays for per-device settings
VIDEO_SIZES=()
FRAMERATES=()

# Set settings and probe/confirm
for i in "${!VIDEO_DEVICES[@]}"; do
  DEV="${VIDEO_DEVICES[$i]}"
  if [ "$AUTO_DETECT" = true ]; then
    SETTINGS=$(get_max_res_fps "$DEV")
    PROBED_SIZE=$(echo "$SETTINGS" | awk '{print $1}')
    PROBED_FPS=$(echo "$SETTINGS" | awk '{print $2}')
    echo "Probed specs for $DEV: $PROBED_SIZE at $PROBED_FPS fps"
    read -p "Is this correct? (y/n, or enter custom 'WIDTHxHEIGHT FPS'): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
      VIDEO_SIZE="$PROBED_SIZE"
      FRAMERATE="$PROBED_FPS"
    elif [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
      read -p "Enter custom resolution (default $DEFAULT_VIDEO_SIZE): " custom_size
      [ -z "$custom_size" ] && custom_size="$DEFAULT_VIDEO_SIZE"
      read -p "Enter custom FPS (default $DEFAULT_FRAMERATE): " custom_fps
      [ -z "$custom_fps" ] && custom_fps="$DEFAULT_FRAMERATE"
      VIDEO_SIZE="$custom_size"
      FRAMERATE="$custom_fps"
    else
      # Parse custom input like "1920x1080 30"
      if echo "$confirm" | grep -q "x"; then
        VIDEO_SIZE=$(echo "$confirm" | awk '{print $1}')
        FRAMERATE=$(echo "$confirm" | awk '{print $2}')
      else
        VIDEO_SIZE="$DEFAULT_VIDEO_SIZE"
        FRAMERATE="$DEFAULT_FRAMERATE"
      fi
    fi
  else
    VIDEO_SIZE="$DEFAULT_VIDEO_SIZE"
    FRAMERATE="$DEFAULT_FRAMERATE"
  fi
  echo "Final settings for $DEV: $VIDEO_SIZE at $FRAMERATE fps"
  VIDEO_SIZES+=("$VIDEO_SIZE")
  FRAMERATES+=("$FRAMERATE")
done

# Prompt for overlay
OVERLAY_ANS=$(prompt_yn "Add text overlay with timestamp?" "n")
OVERLAY=false
OVERLAY_TEXT="$DEFAULT_OVERLAY_TEXT"
if [ "$OVERLAY_ANS" = "y" ]; then
  OVERLAY=true
  read -p "Enter overlay text (default: $DEFAULT_OVERLAY_TEXT): " user_text
  if [ -n "$user_text" ]; then
    OVERLAY_TEXT="$user_text"
  fi
  # Font check
  if [ ! -f "$FONT_FILE" ]; then
    echo "Warning: Font file '$FONT_FILE' not found. Install dejavu fonts (e.g., apt install fonts-dejavu-core) or adjust FONT_FILE."
    CONT_ANS=$(prompt_yn "Continue with overlay (text may not render)?" "n")
    if [ "$CONT_ANS" = "n" ]; then
      OVERLAY=false
    fi
  fi
  if [ "$OVERLAY" = true ]; then
    # If overlay, force encoding (cannot use copy with filters)
    VIDEO_CODEC="-c:v ffv1"
    VIDEO_EXT="mkv"  # Switch to mkv for encoded
    VIDEO_FORMAT="-f matroska"
    echo "Overlay enabled with text '$OVERLAY_TEXT'; using lossless FFV1 encoding."
  fi
fi

# Build overlay filter if enabled (escaped for safety)
if [ "$OVERLAY" = true ]; then
  OVERLAY_FILTER="-vf \"drawtext=fontfile=$FONT_FILE:text='${OVERLAY_TEXT//\'/\\\'}':fontcolor=white:fontsize=24:borderw=2:x=(w-tw)/2:y=h-(2*th)-20,drawtext=fontfile=$FONT_FILE:text='%{localtime\:%Y-%m-%d %H\\:%M\\:%S}':fontcolor=white:fontsize=24:borderw=2:x=(w-tw)/2:y=h-th-10\""
else
  OVERLAY_FILTER=""
fi

# Prompt for preview with conflict warning
if command -v ffplay &> /dev/null; then
  PREVIEW_ANS=$(prompt_yn "Preview live footage in windows? (Warning: May conflict with recording on same device)" "n")
  PREVIEW=false
  if [ "$PREVIEW_ANS" = "y" ]; then
    PREVIEW=true
    if [ ${#VIDEO_DEVICES[@]} -gt 0 ]; then
      echo "Note: Preview and recording may fail if using the same device. Close preview windows before starting recording if issues occur."
    fi
    read -p "Preview scale (e.g., 1.0 full, 0.5 half, default 1.0): " scale_input
    if [[ "$scale_input" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$scale_input > 0" | bc -l) )); then
      PREVIEW_SCALE="$scale_input"
    else
      PREVIEW_SCALE=1.0
      echo "Invalid scale; using default 1.0."
    fi
    if [ $(echo "$PREVIEW_SCALE < 1.0" | bc -l) = 1 ]; then
      PREVIEW_VF="-vf scale=iw*$PREVIEW_SCALE:ih*$PREVIEW_SCALE"
    else
      PREVIEW_VF=""
    fi
    echo "Preview set to scale $PREVIEW_SCALE."
  fi
else
  PREVIEW=false
  echo "ffplay not found; skipping preview option."
fi

# Array to hold PIDs of background processes
PIDS=()

# Function to stop all processes
stop_all() {
  echo "Stopping recordings and previews..."
  for PID in "${PIDS[@]}"; do
    kill -INT "$PID" 2>/dev/null  # Send SIGINT to cleanly stop FFmpeg and ffplay
  done
  wait "${PIDS[@]}" 2>/dev/null  # Wait for processes to exit
}

# Trap for clean exit
trap stop_all EXIT

# Start previews if enabled
if [ "$PREVIEW" = true ]; then
  for i in "${!VIDEO_DEVICES[@]}"; do
    DEV="${VIDEO_DEVICES[$i]}"
    VIDEO_SIZE="${VIDEO_SIZES[$i]}"
    FRAMERATE="${FRAMERATES[$i]}"
    PREVIEW_CMD="ffplay -f v4l2 -framerate $FRAMERATE -video_size $VIDEO_SIZE -input_format $INPUT_FORMAT -i $DEV $OVERLAY_FILTER $PREVIEW_VF"
    echo "Starting preview for $DEV: $PREVIEW_CMD"
    $PREVIEW_CMD &
    PIDS+=($!)
  done
fi

# Start video recordings in background (outputs to SCRIPT_DIR)
for i in "${!VIDEO_DEVICES[@]}"; do
  DEV="${VIDEO_DEVICES[$i]}"
  VIDEO_SIZE="${VIDEO_SIZES[$i]}"
  FRAMERATE="${FRAMERATES[$i]}"
  VID_OUTPUT="$SCRIPT_DIR/${BASE_NAME}_cam${i}.$VIDEO_EXT"
  if [ -n "$DURATION" ]; then
    FULL_CMD="timeout $DURATION ffmpeg -f v4l2 -framerate $FRAMERATE -video_size $VIDEO_SIZE -input_format $INPUT_FORMAT -thread_queue_size $THREAD_QUEUE_SIZE -i $DEV $OVERLAY_FILTER $VIDEO_CODEC $VIDEO_FORMAT -y $VID_OUTPUT"
  else
    FULL_CMD="ffmpeg -f v4l2 -framerate $FRAMERATE -video_size $VIDEO_SIZE -input_format $INPUT_FORMAT -thread_queue_size $THREAD_QUEUE_SIZE -i $DEV $OVERLAY_FILTER $VIDEO_CODEC $VIDEO_FORMAT -y $VID_OUTPUT"
  fi
  echo "Starting video recording for $DEV to $VID_OUTPUT: $FULL_CMD"
  eval $FULL_CMD &
  PIDS+=($!)
done

# Start audio recording in background if not skipped (outputs to SCRIPT_DIR)
if [ "$AUDIO_SKIP" = false ]; then
  AUDIO_OUTPUT="$SCRIPT_DIR/${BASE_NAME}_audio.${AUDIO_EXT}"
  if [ -n "$DURATION" ]; then
    FULL_CMD="timeout $DURATION ffmpeg -f $AUDIO_FORMAT -i $AUDIO_DEVICE $AUDIO_CODEC $AUDIO_FORMAT_OPT -y $AUDIO_OUTPUT"
  else
    FULL_CMD="ffmpeg -f $AUDIO_FORMAT -i $AUDIO_DEVICE $AUDIO_CODEC $AUDIO_FORMAT_OPT -y $AUDIO_OUTPUT"
  fi
  echo "Starting audio recording to $AUDIO_OUTPUT: $FULL_CMD"
  eval $FULL_CMD &
  PIDS+=($!)
else
  echo "Audio skipped."
fi

# Wait for duration or user input to stop
if [ -n "$DURATION" ]; then
  echo "Recordings will auto-stop after $DURATION seconds."
  sleep $DURATION
else
  echo "All recordings started. Outputs will be saved to: $SCRIPT_DIR"
  echo "Press 'q' and Enter to end the recording session."
  while true; do
    read key
    if [ "$key" = "q" ]; then
      read -p "Confirm end session and save files? (y/n): " confirm_end
      if [ "$confirm_end" = "y" ] || [ "$confirm_end" = "Y" ]; then
        stop_all
        echo "Waiting for files to finalize and save..."
        sleep 2  # Brief pause to ensure final writes
        echo "Session ended successfully."
        echo "Files saved to $SCRIPT_DIR:"
        ls -la "$SCRIPT_DIR"/${BASE_NAME}* 2>/dev/null || echo "No output files found (check permissions)."
        break
      else
        echo "Session continuing..."
      fi
    fi
  done
fi

# Notes:
# - Outputs: ${BASE_NAME}_cam0.mkv (FFV1 lossless default), ..., ${BASE_NAME}_audio.flac saved to script directory ($SCRIPT_DIR).
# - Previews: If enabled and ffplay available, opens a window for each camera. Close manually or stopped with recordings. Warning for device conflicts.
# - Auto-detect: Uses v4l2-ctl to find max resolution (by area) and max FPS for that res under the specified INPUT_FORMAT.
#   Falls back to defaults if detection fails. Different cameras may have different settings. Probes and confirms specs per camera.
# - Overlay: If enabled, adds specified text (default "DeMoD LLC") with real-time timestamp underneath at bottom center (with black border for visibility).
#   Requires re-encoding; overrides raw copy. Uses mono font; adjust FONT_FILE if path incorrect.
# - Audio: Tests device before recording; skips if fails (common on NixOS without sound.enable). Enable in configuration.nix for ALSA/Pulse.
# - Config: Supports JSON file via --config (e.g., {"default_framerate": 60, "input_format": "yuyv422"}). Requires jq.
# - For more accurate lsusb-based detection, you could parse /sys/bus/usb/devices/ for video4linux or snd subdirs, but v4l2-ctl/pactl/arecord are preferred.
# - For synchronization: Since separate processes, there may be minor start-time offsets (ms); for perfect sync, consider hardware timestamps or post-processing.
# - Optimization tips: Use SSD for output, close other apps, test with lower resolution/framerate on laptops to avoid overheating. FFV1 files are smaller than raw but larger than lossy.
