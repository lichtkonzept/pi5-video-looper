# Seamless Loop Player for Raspberry Pi 5

One-click setup to automatically play `loop.mp4` from a FAT32 USB stick in a seamless HEVC loop on Raspberry Pi 5 with Raspberry Pi OS Lite (Trixie).

## Features

- **HEVC/H.265 hardware-accelerated playback** via Pi 5 stateless V4L2 decoder (`drm_avcodec`)
- **Zero-copy DMA display pipeline** – decoder buffers go directly to display controller
- **Video plays from RAM** – copied to tmpfs before playback, no USB I/O stalls
- **Auto-detect any monitor resolution** via EDID (4K, 1080p, 1280x1024, etc.)
- **Automatic USB detection** – insert a FAT32 USB stick with `loop.mp4` and it plays
- **USB hot-swap** – remove USB → standby image, insert new USB → plays automatically
- **Silent boot** – no console output, no splash screen, no cursor
- **Standby image** – first frame of video extracted as background (no black screen)
- **Auto-restart** – service restarts automatically on crash
- **Dynamic user detection** – works with any username (auto-detects UID 1000)
- **One-click install & uninstall**

## Requirements

- **Raspberry Pi 5** with Raspberry Pi OS Lite (Trixie / Debian 13, 64-bit)
- **HDMI monitor** (any resolution – Pi auto-detects via EDID)
- **FAT32 USB stick** with a file named `loop.mp4`
  - Codec: **HEVC / H.265** (required for hardware acceleration on Pi 5)
  - Resolution: match your monitor (the Pi adapts to whatever EDID reports)
  - USB sticks with or without partition table are both supported
  - **Tip**: For the smoothest loop, make the first and last frames of your video visually similar (e.g. same background color). VLC 3.0 has a minimal ~30ms gap between loops.

## Installation

1. Flash **Raspberry Pi OS Lite (Trixie, 64-bit)** to your SD card
2. Boot the Pi, connect via SSH or keyboard
3. Copy the setup script to the Pi:

```bash
scp setup_loop_player.sh youruser@192.168.1.55:~/setup_loop_player.sh
```

4. Run it:

```bash
ssh youruser@192.168.1.55
chmod +x ~/setup_loop_player.sh
sudo ./setup_loop_player.sh
```

5. The Pi will reboot automatically
6. Insert a FAT32 USB stick with `loop.mp4` – playback starts automatically

## Helper Commands

| Command | Description |
|---|---|
| `loop-start` | Start the player |
| `loop-stop` | Stop the player and kill VLC |
| `loop-restart` | Restart the player |
| `loop-status` | Show service status |
| `loop-logs` | Show live journal logs |

## How It Works

1. **Boot** → systemd starts `loop-player.service` (runs as UID 1000 user)
2. **USB scan** → Python script scans for FAT32/exFAT USB partitions via `lsblk`
3. **Mount** → First matching partition mounted read-only to `/mnt/usb` (via passwordless sudo)
4. **RAM copy** → Video copied to `/tmp/loop-player/` (tmpfs) to avoid USB I/O stalls
5. **Background extraction** → First frame extracted as `background.png` via ffmpeg
6. **Playback** → `cvlc` with hardware HEVC decoding (`drm_avcodec`), zero-copy DMA output
7. **Loop** → `--input-repeat=65535` for continuous playback
8. **Watchdog** → Monitors USB presence and VLC process health every 5 seconds
9. **USB removal** → Kills VLC, cleans up RAM copy, shows standby image, waits for new USB

## Technical Details

### config.txt
```ini
dtoverlay=vc4-kms-v3d,cma-512   # cma-512 added to existing overlay, not duplicated
```

### VLC Flags
```bash
cvlc --no-xlib --quiet --fullscreen --no-video-title-show --no-osd \
     --codec=drm_avcodec --vout=drm_vout --drm-vout-display=HDMI-1 \
     --drm-vout-pool-dmabuf --no-audio --file-caching=2000 \
     --input-repeat=65535 \
     /tmp/loop-player/loop.mp4
```

### Performance (Pi 5, 1280x1024@60fps HEVC 10-bit, 55 Mbit/s)

| Metric | Software (v1) | Hardware (v2) |
|--------|---------------|---------------|
| CPU usage | 209% | ~6-9% |
| Temperature | 77.9°C | 67.0°C |
| VLC RAM | 247 MB | 104 MB |
| Decoder | libavcodec software | rpi-hevc-dec hardware |
| Video source | USB (I/O stalls) | RAM (tmpfs) |
| Display pipeline | CPU frame copy | Zero-copy DMA |

### Resolution Handling

The Pi automatically detects the monitor's native resolution via EDID. No `hdmi_group` or `hdmi_mode` is set – the Pi uses whatever the monitor reports. VLC `--fullscreen` with `--vout=drm_vout` adapts to the active display resolution. Your video should match the monitor resolution for best results.

### Loop Gap

VLC 3.0 has a known limitation: there is a brief flash (~30ms / 1-3 frames) between loop iterations. For practical purposes this is barely noticeable, especially with videos where the first and last frames share the same background color.

### Security

The service runs as a non-root user. A sudoers rule grants passwordless access only for `mount`/`umount` on `/mnt/usb`.

## Uninstallation

```bash
chmod +x uninstall_loop_player.sh
sudo ./uninstall_loop_player.sh
```

This reverts all system changes (config.txt, cmdline.txt, services, udev rules, sudoers) and reboots.

## Project Structure

```
seamless-loop-player/
├── README.md                  # This file
├── setup_loop_player.sh       # One-click installer (contains loop_player.py inline)
├── uninstall_loop_player.sh   # Uninstaller
├── loop_player.py             # Reference copy (installed inline by setup script)
└── changelog.txt              # Bugfix & performance history
```
