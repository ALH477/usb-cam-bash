# USB Camera and Microphone Recorder for Linux

[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A robust, configurable Bash script for capturing raw or lossless video footage from multiple USB cameras and audio from a USB microphone using FFmpeg on Linux systems. Optimized for laptops, it supports dynamic device detection, auto-configuration, live previews, and overlays. Ideal for professional recording setups, surveillance, or content creation.

## Features

- **Dynamic Device Detection**: Automatically detects USB cameras via `v4l2-ctl` and microphones via PulseAudio/ALSA, with fallbacks to `lsusb`.
- **Auto-Detection of Camera Specs**: Probes maximum resolution and FPS per camera using `v4l2-ctl --list-formats-ext`, now with improved FPS selection for same-resolution formats.
- **Flexible Recording Modes**:
  - Default: Lossless FFV1 in MKV container (compressed but high-quality).
  - Raw copy mode (AVI) for unprocessed footage, with warning if overlays force encoding.
- **Live Preview**: Optional scaled previews with `ffplay` (e.g., half-size to reduce CPU load), with combined overlay and scaling filters to prevent conflicts.
- **Overlays**: Add custom text (e.g., "DeMoD LLC") with real-time timestamps, requiring FFV1 encoding.
- **Separate Outputs**: One file per camera/audio stream for easy post-processing.
- **JSON Configuration**: Override defaults via a simple JSON file.
- **Enhanced Error Handling**: 
  - Tests audio devices with detailed error output; skips on failure.
  - Validates process starts (PIDs) for recordings and previews.
  - Clean shutdowns via SIGINT for FFmpeg, with duration handled natively (`-t` option).
  - Checks for `bc` dependency for preview scaling; defaults to full scale if absent.
  - Warns on preview/recording device conflicts with a pause to close previews.
- **NixOS-Compatible**: Handles common issues like disabled ALSA/PulseAudio.

## Requirements

- **Core Dependencies**:
  - FFmpeg (with V4L2, ALSA/PulseAudio support; `ffmpeg-full` on NixOS).
  - `v4l2-ctl` (from `v4l-utils`).
- **Optional**:
  - `ffplay` (for previews).
  - `pactl`/`arecord` (for audio detection).
  - `jq` (for JSON config parsing).
  - `udevadm` (for enhanced USB probing).
  - `bc` (for preview scaling calculations).
- **System**: Linux with USB camera/mic support. Tested on Ubuntu, Fedora, and NixOS.

Install on NixOS (add to `configuration.nix`):
```nix
environment.systemPackages = with pkgs; [
  ffmpeg-full
  v4l-utils
  pulseaudio  # Or pipewire for audio
  bc
];
sound.enable = true;
hardware.pulseaudio.enable = true;
```

## Installation

1. Clone or download the repository:
   ```
   git clone <repo-url>
   cd <repo-dir>
   chmod +x record.sh
   ```

2. Ensure dependencies are installed (e.g., `sudo apt install ffmpeg v4l-utils jq bc` on Debian/Ubuntu).

## Usage

Run the script interactively:
```
./record.sh [base_name] [--raw] [--duration SECONDS] [--config config.json]
```

- **`base_name`**: Output prefix (default: `recording`).
- **`--raw`**: Use raw copy mode (AVI) instead of FFV1 (MKV); ignored with overlays.
- **`--duration SECONDS`**: Auto-stop after time (e.g., 300 for 5 minutes), now using FFmpeg's native `-t` for clean stops.
- **`--config config.json`**: Load JSON config (see below).

The script prompts for:
- Auto-detect camera specs (y/n).
- Custom resolution/FPS confirmation.
- Text overlay with timestamp (y/n; default text: "DeMoD LLC").
- Scaled preview (y/n; e.g., 0.5 for half-size), with pause to close previews before recording.
- Audio skip if device test fails.

Press `q` + Enter during recording to stop, then confirm to save files. Ctrl+C also triggers clean shutdown.

### Example Output Files
In the script's directory:
- `recording_cam0.mkv` (FFV1 video).
- `recording_cam1.mkv` (second camera).
- `recording_audio.flac` (lossless audio).

### JSON Configuration Example

Create `config.json`:
```json
{
  "default_framerate": 60,
  "default_video_size": "1280x720",
  "input_format": "mjpeg",
  "thread_queue_size": 2048,
  "font_file": "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "default_overlay_text": "Your Company LLC"
}
```

Run: `./record.sh my_recording --config config.json`

## Troubleshooting

- **"Device or resource busy"**: Preview and recording can't share devices. Close `ffplay` windows via prompt or disable preview.
- **MKV Muxer Error**: Rare in full builds; script uses `-f matroska` as workaround.
- **Audio Test Fails**: Detailed error output shown; enable sound in NixOS config or skip audio via prompt.
- **No Cameras Detected**: Run `v4l2-ctl --list-devices` manually; ensure USB permissions (`sudo usermod -aG video $USER`).
- **High CPU/Overheating**: Lower FPS/resolution, use SSD output, or raw mode.
- **Overlays Not Rendering**: Install DejaVu fonts (`sudo apt install fonts-dejavu-core`).
- **Preview Scaling Fails**: Ensure `bc` is installed; otherwise, defaults to full scale.

For sync issues in post-processing, use tools like DaVinci Resolve or `ffmpeg` with timestamps.

## Contributing

Fork, branch, and submit PRs for features/bugfixes. Tests appreciated!

## Credits

- Developed with assistance from **Grok 3** by xAI.
- Created by **Asher LeRoy**, Founder of DeMoD LLC.

## License

This project is licensed under the GNU General Public License v3.0 (GPLv3) - see [LICENSE](LICENSE) for details.

```
Copyright (C) 2025 Asher LeRoy (DeMoD LLC)

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```
