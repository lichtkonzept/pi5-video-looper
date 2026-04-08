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
# 5. GPU / Display Configuration (config.txt)
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
# 6. Application Installation
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
Finds USB stick, copies video to RAM, plays via cvlc in a loop.
Exits when VLC stops or USB is removed — systemd restarts us.
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

# --- Configuration ---
MOUNT_POINT = "/mnt/usb"
VIDEO_FILENAME = "loop.mp4"
INSTALL_DIR = "/opt/loop-player"
RAM_COPY_DIR = "/tmp/loop-player"
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
                    # Extract port number: card0-HDMI-A-1 -> 1
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


def find_usb_partition():
    """Find the first mountable partition (or raw disk) on a USB storage device.
    Supports all common filesystems: FAT32, exFAT, NTFS, ext2/3/4, etc.
    """
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
            # Prefer partitions over raw disk
            for child in dev.get("children", []):
                if child.get("fstype"):
                    return child["path"]
            # Disk without partition table (directly formatted)
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


def copy_to_ram(video_path):
    os.makedirs(RAM_COPY_DIR, exist_ok=True)
    dest = os.path.join(RAM_COPY_DIR, VIDEO_FILENAME)
    try:
        src_size = os.path.getsize(video_path)
        stat = os.statvfs("/tmp")
        free = stat.f_bavail * stat.f_frsize
        if src_size > free - 512 * 1024 * 1024:
            log.warning("Video too large for RAM, playing from USB")
            return None
        log.info(f"Copying video to RAM ({src_size // (1024*1024)}MB)...")
        shutil.copy2(video_path, dest)
        return dest
    except Exception as e:
        log.error(f"RAM copy failed: {e}")
        return None


def extract_background(video_path):
    # Remove old background so we never show a stale frame from a previous video
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

    # Always start with black screen — remove stale background from previous video
    try:
        os.remove(BACKGROUND_IMG)
    except FileNotFoundError:
        pass

    # Find USB
    partition = find_usb_partition()
    if not partition:
        log.info("No USB found, showing standby")
        bg = show_standby()
        if bg:
            bg.wait()
        time.sleep(5)
        return

    # Mount
    if not mount_usb(partition):
        time.sleep(5)
        return

    video_path = os.path.join(MOUNT_POINT, VIDEO_FILENAME)
    if not os.path.isfile(video_path):
        log.warning(f"{VIDEO_FILENAME} not found on USB")
        bg = show_standby()
        if bg:
            bg.wait()
        time.sleep(5)
        return

    # Copy to RAM + extract background
    ram_video = copy_to_ram(video_path)
    playback_path = ram_video or video_path
    extract_background(playback_path)

    # Play
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
chown -R "$TARGET_USER":"$TARGET_USER" "${INSTALL_DIR}"
# Unmount USB first (may be mounted from previous install), then chown
umount "${MOUNT_POINT}" 2>/dev/null || true
chown "$TARGET_USER":"$TARGET_USER" "${MOUNT_POINT}"
info "Application installed."

# ============================================================================
# 7. USB udev rules (restart service on USB insert/remove)
# ============================================================================
info "Configuring USB rules..."

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
# 8. Systemd Service
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
# 9. Helper Scripts
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
# 10. Done
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
