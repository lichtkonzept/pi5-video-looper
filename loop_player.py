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
