# Seamless Loop Player for Raspberry Pi 5

One-click setup for a hardened Digital Signage player on Raspberry Pi 5. Insert a USB stick with `loop.mp4` — the video is imported to the SD card, the USB is ejected, and playback runs from RAM in a seamless HEVC loop.

## Features

- **USB → SD → RAM flow** – video is imported from USB to SD card, USB is ejected, playback runs from RAM
- **Persistent video on SD** – survives reboots, USB only needed to update the video
- **Smart import** – checksum comparison skips copy if video is unchanged
- **HEVC/H.265 hardware-accelerated playback** via Pi 5 stateless V4L2 decoder (`drm_avcodec`)
- **Zero-copy DMA display pipeline** – decoder buffers go directly to display controller
- **HDMI auto-detect** – automatically finds connected HDMI port (1 or 2), supports hotplug
- **Auto-detect any monitor resolution** via EDID (4K, 1080p, 1280x1024, etc.)
- **Universal USB support** – FAT32, exFAT, NTFS, ext2/3/4, with or without partition table
- **Silent boot** – no console output, no splash screen, no cursor
- **System hardening** – journal limited, apt auto-updates disabled, hardware watchdog enabled
- **Auto-restart** – service restarts automatically on crash, kernel panic, or hang
- **Standby image** – first frame extracted as background (black screen when no video)
- **One-click install & uninstall**

## Requirements

- **Raspberry Pi 5** with Raspberry Pi OS Lite (Trixie / Debian 13, 64-bit)
- **HDMI monitor** (any resolution – Pi auto-detects via EDID)
- **USB stick** (FAT32, exFAT, NTFS, ext4 — any filesystem) with a file named `loop.mp4`
  - Codec: **HEVC / H.265** (required for hardware acceleration on Pi 5)
  - Resolution: match your monitor (the Pi adapts to whatever EDID reports)
  - USB sticks with or without partition table are both supported
  - The USB stick is only needed to import/update the video — it can be removed after import
  - **Tip**: For the smoothest loop, make the first and last frames visually similar. VLC 3.0 has a minimal ~30ms gap between loops.

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
sed -i 's/\r$//' ~/setup_loop_player.sh
chmod +x ~/setup_loop_player.sh
sudo ~/setup_loop_player.sh
```

> **Note:** The `sed` command removes Windows line endings (CRLF → LF). Without it, the script may fail with "No such file or directory".

5. The Pi will reboot automatically
6. Insert a USB stick with `loop.mp4` — video is imported to SD, USB ejected, playback starts

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
2. **USB check** → If USB present with `loop.mp4`, import to SD (`/opt/loop-player/video/`)
3. **Checksum compare** → Skip import if video on USB is identical to SD (fast partial MD5)
4. **USB eject** → USB is unmounted automatically after import — stick can be removed
5. **SD → RAM** → Video copied from SD to `/tmp/loop-player/` (tmpfs) for stall-free playback
6. **Background extraction** → First frame extracted as `background.png` via ffmpeg
7. **Playback** → `cvlc` with hardware HEVC decoding (`drm_avcodec`), zero-copy DMA output
8. **Loop** → `--input-repeat=65535` for continuous playback
9. **Video update** → Insert new USB → udev restarts service → new video imported to SD
10. **HDMI hotplug** → udev detects display connect/disconnect → service restarts with correct port

## Technical Details

### config.txt
```ini
dtoverlay=vc4-kms-v3d,cma-512   # cma-512 added to existing overlay, not duplicated
```

### VLC Flags
```bash
cvlc --no-xlib --quiet --fullscreen --no-video-title-show --no-osd \
     --codec=drm_avcodec --vout=drm_vout --drm-vout-display=HDMI-{1|2} \
     --drm-vout-pool-dmabuf --no-audio --file-caching=2000 \
     --input-repeat=65535 \
     /tmp/loop-player/loop.mp4
# HDMI port is auto-detected at startup via /sys/class/drm/card*-HDMI-A-*/status
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

### System Hardening

- **Non-root service** with sudoers only for `mount`/`umount` on `/mnt/usb`
- **Journal limited** to 50MB / 7 days
- **apt auto-updates disabled** — no uncontrolled package changes
- **Hardware watchdog** — auto-reboot on kernel panic (10s) or system hang (15s)
- **Unnecessary services disabled** — bluetooth, ModemManager, avahi, serial-getty
- **Unnecessary timers disabled** — fstrim, e2scrub, man-db, dpkg-db-backup
- **tmpfiles-clean exception** — RAM video copy protected from cleanup
- **WiFi + SSH remain active** for remote management

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
├── LICENSE                    # Proprietary license
├── setup_loop_player.sh       # One-click installer (contains loop_player.py inline)
├── uninstall_loop_player.sh   # Uninstaller
├── loop_player.py             # Reference copy (installed inline by setup script)
└── changelog.txt              # Bugfix & performance history

# On the Pi after installation:
/opt/loop-player/
├── loop_player.py             # Main script
├── video/loop.mp4             # Persistent video (imported from USB)
├── background.png             # First frame of current video
└── black.png                  # Fallback standby image
```

## License

This software is proprietary. All rights reserved. See [LICENSE](LICENSE) for details.
