#!/bin/bash
# ============================================================================
# Seamless Loop Player - One-Click Installer for Raspberry Pi 5
# Raspberry Pi OS Lite (Trixie / Debian 13, 64-bit)
# ============================================================================
set -e

INSTALL_DIR="/opt/loop-player"
SERVICE_NAME="loop-player"
MOUNT_POINT="/mnt/usb"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# 1. System Checks
# ============================================================================
info "=== Seamless Loop Player Installer ==="

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (sudo)."
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    error "This script requires a 64-bit ARM system (aarch64). Detected: $ARCH"
    exit 1
fi

info "System check passed (root, aarch64)."

# ============================================================================
# 2. Install Dependencies (no full-upgrade)
# ============================================================================
info "Installing dependencies..."
apt-get update -y
apt-get install -y vlc ffmpeg python3 ntfs-3g exfatprogs

info "Dependencies installed."

# ============================================================================
# 3. User Permissions
# ============================================================================
info "Configuring user permissions..."

TARGET_USER=$(id -un 1000 2>/dev/null || echo "pi")
info "Target user: ${TARGET_USER}"

for group in render video audio input; do
    usermod -aG $group "$TARGET_USER" 2>/dev/null || true
done

loginctl enable-linger "$TARGET_USER" 2>/dev/null || true

info "User permissions configured."

# ============================================================================
# 4. Silent Boot Configuration
# ============================================================================
info "Configuring silent boot..."

systemctl set-default multi-user.target
systemctl disable getty@tty1.service 2>/dev/null || true

CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE_FILE" ]; then
    sed -i 's/ quiet//g' "$CMDLINE_FILE"
    sed -i 's/ loglevel=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ consoleblank=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ splash//g' "$CMDLINE_FILE"
    sed -i 's/ vt.global_cursor_default=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ logo.nologo//g' "$CMDLINE_FILE"
    sed -i 's/console=tty1/console=tty3/g' "$CMDLINE_FILE"
    sed -i '1 s/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo consoleblank=0/' "$CMDLINE_FILE"
    # Ensure trailing newline (some tools break without it)
    sed -i -e '$a\' "$CMDLINE_FILE"
    info "Kernel parameters configured."
else
    warn "$CMDLINE_FILE not found, skipping."
fi

# ============================================================================
# 5. System Hardening for Digital Signage
# ============================================================================
info "Hardening system for unattended operation..."

# --- Limit journal size to prevent SD card fill-up ---
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/loop-player.conf << 'EOF'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald 2>/dev/null || true
info "Journal limited to 50MB."

# --- Disable automatic apt updates (prevent mid-playback interruptions) ---
systemctl disable --now apt-daily.timer 2>/dev/null || true
systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
info "Automatic apt updates disabled."

# --- Protect /tmp/loop-player from tmpfiles-clean (runs after 10d) ---
cat > /etc/tmpfiles.d/loop-player.conf << 'EOF'
x /tmp/loop-player
x /tmp/loop-player/*
EOF
info "RAM copy protected from tmpfiles-clean."

# --- Hardware watchdog: auto-reboot on kernel panic / hang ---
cat > /etc/sysctl.d/99-loop-player-watchdog.conf << 'EOF'
kernel.panic = 10
kernel.panic_on_oops = 1
EOF
sysctl -p /etc/sysctl.d/99-loop-player-watchdog.conf 2>/dev/null || true
# Enable Pi 5 hardware watchdog via systemd
if [ ! -f /etc/systemd/system.conf.d/watchdog.conf ]; then
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdog=15s
RebootWatchdog=2min
EOF
fi
info "Hardware watchdog enabled (auto-reboot on hang/panic)."

# --- Disable unnecessary services ---
for svc in bluetooth.service ModemManager.service avahi-daemon.service; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
# Serial getty on debug UART — not needed
systemctl disable --now serial-getty@ttyAMA10.service 2>/dev/null || true
# wpa_supplicant + NetworkManager + ssh STAY ENABLED (WiFi management)
info "Unnecessary services disabled (bluetooth, ModemManager, avahi, serial-getty)."

# --- Disable unnecessary timers ---
for tmr in fstrim.timer e2scrub_all.timer man-db.timer dpkg-db-backup.timer; do
    systemctl disable --now "$tmr" 2>/dev/null || true
done
info "Unnecessary timers disabled."

info "System hardening complete."

# ============================================================================
# 6. GPU / Display Configuration (config.txt)
# ============================================================================
info "Configuring GPU settings..."

CONFIG_FILE="/boot/firmware/config.txt"
if [ -f "$CONFIG_FILE" ]; then
    sed -i '/# --- Loop Player Setup ---/,/# --- End Loop Player Setup ---/d' "$CONFIG_FILE"
    sed -i '/^dtoverlay=rpivid-v4l2/d' "$CONFIG_FILE"
    sed -i '/^hdmi_group=/d' "$CONFIG_FILE"
    sed -i '/^hdmi_mode=/d' "$CONFIG_FILE"

    if grep -q '^dtoverlay=vc4-kms-v3d$' "$CONFIG_FILE"; then
        sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-512/' "$CONFIG_FILE"
    elif ! grep -q 'cma-512' "$CONFIG_FILE"; then
        sed -i 's/^dtoverlay=vc4-kms-v3d.*/dtoverlay=vc4-kms-v3d,cma-512/' "$CONFIG_FILE"
    fi

    # Remove trailing blank lines before appending (prevents accumulation on re-runs)
    sed -i -e :a -e '/^\s*$/{ $d; N; ba; }' "$CONFIG_FILE"

    cat >> "$CONFIG_FILE" << 'EOF'

# --- Loop Player Setup ---
# cma-512 added to vc4-kms-v3d overlay above
# --- End Loop Player Setup ---
EOF

    info "GPU settings configured."
else
    warn "$CONFIG_FILE not found, skipping."
fi

# ============================================================================
# 7. Application Installation
# ============================================================================
info "Installing application to ${INSTALL_DIR}..."

# Stop running service first (safe for fresh install too)
systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
pkill -f "cvlc.*drm_vout" 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
mkdir -p "$MOUNT_POINT"

ffmpeg -f lavfi -i "color=c=black:s=1920x1080:d=1" -vframes 1 \
    "${INSTALL_DIR}/black.png" -y >/dev/null 2>&1

cat > "${INSTALL_DIR}/loop_player.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Seamless Loop Player for Raspberry Pi 5
Flow: USB → SD → RAM → Playback
  1. If USB present: copy video from USB to SD, then eject USB
  2. Copy video from SD to RAM (tmpfs)
  3. Play from RAM in a loop
  4. New USB inserted → udev restarts service → video updated on SD
"""

import subprocess
import signal
import sys
import os
import json
import logging
import shutil
import time
import glob
import hashlib

# --- Configuration ---
MOUNT_POINT = "/mnt/usb"
VIDEO_FILENAME = "loop.mp4"
INSTALL_DIR = "/opt/loop-player"
SD_VIDEO_DIR = os.path.join(INSTALL_DIR, "video")
SD_VIDEO_PATH = os.path.join(SD_VIDEO_DIR, VIDEO_FILENAME)
RAM_COPY_DIR = "/tmp/loop-player"
RAM_VIDEO_PATH = os.path.join(RAM_COPY_DIR, VIDEO_FILENAME)
BACKGROUND_IMG = os.path.join(INSTALL_DIR, "background.png")
BLACK_IMG = os.path.join(INSTALL_DIR, "black.png")


def detect_hdmi_port():
    """Auto-detect which HDMI port has a connected display.
    Reads /sys/class/drm/card*-HDMI-A-*/status. Returns 'HDMI-1' or 'HDMI-2'.
    Falls back to 'HDMI-1' if detection fails.
    """
    try:
        for status_file in sorted(glob.glob("/sys/class/drm/card*-HDMI-A-*/status")):
            with open(status_file) as f:
                if f.read().strip() == "connected":
                    port = status_file.split("HDMI-A-")[1].split("/")[0]
                    return f"HDMI-{port}"
    except Exception:
        pass
    return "HDMI-1"


HDMI_PORT = detect_hdmi_port()

VLC_ARGS = [
    "cvlc",
    "--no-xlib",
    "--quiet",
    "--fullscreen",
    "--no-video-title-show",
    "--no-osd",
    "--codec=drm_avcodec",
    "--vout=drm_vout",
    f"--drm-vout-display={HDMI_PORT}",
    "--drm-vout-pool-dmabuf",
    "--no-audio",
    "--file-caching=2000",
]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("loop-player")

vlc_process = None


def shutdown(sig, frame):
    log.info(f"Signal {sig}, shutting down...")
    if vlc_process and vlc_process.poll() is None:
        vlc_process.terminate()
        try:
            vlc_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            vlc_process.kill()
    sys.exit(0)


def file_checksum(path, chunk_size=1024 * 1024):
    """Fast partial MD5: first+last 1MB. Good enough to detect changed videos."""
    h = hashlib.md5()
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            h.update(f.read(chunk_size))
            if size > chunk_size * 2:
                f.seek(-chunk_size, 2)
                h.update(f.read(chunk_size))
        h.update(str(size).encode())
    except Exception:
        return None
    return h.hexdigest()


def find_usb_partition():
    """Find the first mountable partition (or raw disk) on a USB storage device."""
    try:
        result = subprocess.run(
            ["lsblk", "-o", "PATH,FSTYPE,TRAN,TYPE", "-J", "-T"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
        for dev in data.get("blockdevices", []):
            if dev.get("tran") != "usb" or dev.get("type") != "disk":
                continue
            for child in dev.get("children", []):
                if child.get("fstype"):
                    return child["path"]
            if dev.get("fstype"):
                return dev["path"]
    except Exception as e:
        log.error(f"USB scan error: {e}")
    return None


def mount_usb(partition):
    os.makedirs(MOUNT_POINT, exist_ok=True)
    try:
        r = subprocess.run(["findmnt", "-n", "-o", "SOURCE", MOUNT_POINT],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip() == partition:
            return True
        if r.returncode == 0 and r.stdout.strip():
            subprocess.run(["sudo", "umount", MOUNT_POINT], timeout=10)
    except Exception:
        pass
    try:
        r = subprocess.run(["sudo", "mount", "-o", "ro", partition, MOUNT_POINT],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            log.info(f"Mounted {partition}")
            return True
        log.error(f"Mount failed: {r.stderr.strip()}")
    except Exception as e:
        log.error(f"Mount error: {e}")
    return False


def unmount_usb():
    try:
        subprocess.run(["sudo", "umount", MOUNT_POINT],
                       capture_output=True, timeout=10)
        log.info("USB unmounted — stick can be removed")
    except Exception:
        pass


def import_from_usb():
    """Check USB for video, copy to SD if new/changed, then eject USB.
    Returns True if a new video was imported.
    """
    partition = find_usb_partition()
    if not partition:
        return False

    if not mount_usb(partition):
        return False

    usb_video = os.path.join(MOUNT_POINT, VIDEO_FILENAME)
    if not os.path.isfile(usb_video):
        log.info(f"No {VIDEO_FILENAME} on USB — ignoring stick")
        unmount_usb()
        return False

    # Compare checksums — skip copy if identical
    usb_hash = file_checksum(usb_video)
    sd_hash = file_checksum(SD_VIDEO_PATH) if os.path.isfile(SD_VIDEO_PATH) else None

    if usb_hash and usb_hash == sd_hash:
        log.info("Video on USB identical to SD — skipping import")
        unmount_usb()
        return False

    # Copy USB → SD
    os.makedirs(SD_VIDEO_DIR, exist_ok=True)
    usb_size = os.path.getsize(usb_video)
    log.info(f"Importing video from USB to SD ({usb_size // (1024*1024)}MB)...")
    try:
        shutil.copy2(usb_video, SD_VIDEO_PATH)
        log.info("Video imported to SD successfully")
    except Exception as e:
        log.error(f"USB→SD copy failed: {e}")
        unmount_usb()
        return False

    unmount_usb()
    return True


def copy_to_ram():
    """Copy video from SD to RAM (tmpfs). Returns path or None."""
    os.makedirs(RAM_COPY_DIR, exist_ok=True)
    try:
        src_size = os.path.getsize(SD_VIDEO_PATH)
        stat = os.statvfs("/tmp")
        free = stat.f_bavail * stat.f_frsize
        if src_size > free - 512 * 1024 * 1024:
            log.warning("Video too large for RAM, playing from SD")
            return None
        log.info(f"Copying video to RAM ({src_size // (1024*1024)}MB)...")
        shutil.copy2(SD_VIDEO_PATH, RAM_VIDEO_PATH)
        return RAM_VIDEO_PATH
    except Exception as e:
        log.error(f"RAM copy failed: {e}")
        return None


def extract_background(video_path):
    try:
        os.remove(BACKGROUND_IMG)
    except FileNotFoundError:
        pass
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", video_path, "-vframes", "1", "-update", "1", "-q:v", "2", BACKGROUND_IMG],
            capture_output=True, timeout=30,
        )
    except Exception:
        pass


def show_standby():
    img = BACKGROUND_IMG if os.path.exists(BACKGROUND_IMG) else BLACK_IMG
    if not os.path.exists(img):
        return None
    log.info(f"Showing standby: {img}")
    try:
        return subprocess.Popen(
            VLC_ARGS + ["--image-duration=-1", img],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
    except Exception:
        return None


def main():
    global vlc_process

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log.info(f"=== Loop Player started === (HDMI: {HDMI_PORT})")

    # Remove stale background
    try:
        os.remove(BACKGROUND_IMG)
    except FileNotFoundError:
        pass

    # Step 1: Import from USB if present (USB → SD), then eject
    imported = import_from_usb()
    if imported:
        # Clear RAM copy so we re-copy the new video
        shutil.rmtree(RAM_COPY_DIR, ignore_errors=True)

    # Step 2: Check if we have a video on SD
    if not os.path.isfile(SD_VIDEO_PATH):
        log.info("No video on SD — showing standby (insert USB with loop.mp4)")
        bg = show_standby()
        if bg:
            bg.wait()
        time.sleep(5)
        return

    # Step 3: Copy SD → RAM
    ram_video = copy_to_ram()
    playback_path = ram_video or SD_VIDEO_PATH
    extract_background(playback_path)

    # Step 4: Play
    cmd = VLC_ARGS + ["--input-repeat=65535", playback_path]
    log.info(f"Playing: {playback_path}")
    vlc_process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    vlc_process.wait()

    exit_code = vlc_process.returncode
    try:
        stderr_out = vlc_process.stderr.read().decode(errors="replace") if vlc_process.stderr else ""
    except Exception:
        stderr_out = ""
    if stderr_out:
        log.info(f"VLC exited ({exit_code}): {stderr_out[:500]}")
    else:
        log.info(f"VLC exited ({exit_code})")

    # Cleanup RAM
    shutil.rmtree(RAM_COPY_DIR, ignore_errors=True)
    log.info("=== Loop Player stopped ===")


if __name__ == "__main__":
    main()
PYTHON_EOF

chmod +x "${INSTALL_DIR}/loop_player.py"
mkdir -p "${INSTALL_DIR}/video"
chown -R "$TARGET_USER":"$TARGET_USER" "${INSTALL_DIR}"
# Unmount USB first (may be mounted from previous install), then chown
umount "${MOUNT_POINT}" 2>/dev/null || true
chown "$TARGET_USER":"$TARGET_USER" "${MOUNT_POINT}"
info "Application installed."

# ============================================================================
# 8. USB + HDMI udev rules
# ============================================================================
info "Configuring udev rules..."

cat > /etc/udev/rules.d/99-loop-player-usb.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", TAG+="systemd", RUN+="/bin/systemctl restart loop-player.service"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", TAG+="systemd", RUN+="/bin/systemctl restart loop-player.service"
EOF

# HDMI hotplug: restart service when display is connected/disconnected
cat > /etc/udev/rules.d/99-loop-player-hdmi.rules << 'EOF'
ACTION=="change", SUBSYSTEM=="drm", RUN+="/bin/systemctl restart loop-player.service"
EOF

udevadm control --reload-rules
info "USB + HDMI hotplug rules configured."

# ============================================================================
# 9. Systemd Service
# ============================================================================
info "Creating systemd service..."

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Seamless Loop Video Player
After=multi-user.target

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_USER}
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/loop_player.py
Restart=always
RestartSec=3
Environment="XDG_RUNTIME_DIR=/run/user/1000"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sudoers.d/loop-player << SUDOEOF
${TARGET_USER} ALL=(root) NOPASSWD: /bin/mount -o ro * /mnt/usb, /bin/umount /mnt/usb
SUDOEOF
chmod 0440 /etc/sudoers.d/loop-player

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service

info "Systemd service created and enabled."

# ============================================================================
# 10. Helper Scripts
# ============================================================================
info "Installing helper scripts..."

cat > /usr/local/bin/loop-start << 'EOF'
#!/bin/bash
sudo systemctl start loop-player.service
echo "Loop player started."
EOF

cat > /usr/local/bin/loop-stop << 'EOF'
#!/bin/bash
sudo systemctl stop loop-player.service
sudo pkill -f "cvlc.*drm_vout" 2>/dev/null || true
echo "Loop player stopped."
EOF

cat > /usr/local/bin/loop-status << 'EOF'
#!/bin/bash
systemctl status loop-player.service
EOF

cat > /usr/local/bin/loop-logs << 'EOF'
#!/bin/bash
journalctl -u loop-player.service -f
EOF

cat > /usr/local/bin/loop-restart << 'EOF'
#!/bin/bash
sudo systemctl restart loop-player.service
echo "Loop player restarted."
EOF

chmod +x /usr/local/bin/loop-start /usr/local/bin/loop-stop /usr/local/bin/loop-status /usr/local/bin/loop-logs /usr/local/bin/loop-restart

info "Helper scripts installed."

# ============================================================================
# 11. Done
# ============================================================================
echo ""
info "============================================"
info "  Installation complete!"
info "============================================"
echo ""
info "After reboot: Insert FAT32 USB with 'loop.mp4'"
info "Commands: loop-start, loop-stop, loop-restart, loop-status, loop-logs"
echo ""
warn "Rebooting in 10 seconds... (Ctrl+C to cancel)"
sleep 10
reboot
