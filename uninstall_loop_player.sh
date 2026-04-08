#!/bin/bash
# ============================================================================
# Seamless Loop Player - Uninstaller
# ============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (sudo)."
    exit 1
fi

info "=== Seamless Loop Player Uninstaller ==="

# --- Stop and disable service ---
info "Stopping and disabling service..."
systemctl stop loop-player.service 2>/dev/null || true
systemctl disable loop-player.service 2>/dev/null || true
rm -f /etc/systemd/system/loop-player.service
systemctl daemon-reload

# --- Kill any remaining VLC processes ---
pkill -f "cvlc.*drm_vout" 2>/dev/null || true

# --- Remove udev rules ---
info "Removing udev rules..."
rm -f /etc/udev/rules.d/99-loop-player-usb.rules
rm -f /etc/udev/rules.d/99-loop-player-hdmi.rules
udevadm control --reload-rules

# --- Remove sudoers rule ---
info "Removing sudoers rule..."
rm -f /etc/sudoers.d/loop-player

# --- Remove application ---
info "Removing application files..."
rm -rf /opt/loop-player

# --- Unmount and remove mount point ---
umount /mnt/usb 2>/dev/null || true
rmdir /mnt/usb 2>/dev/null || true

# --- Remove helper scripts ---
info "Removing helper scripts..."
rm -f /usr/local/bin/loop-start
rm -f /usr/local/bin/loop-stop
rm -f /usr/local/bin/loop-status
rm -f /usr/local/bin/loop-logs
rm -f /usr/local/bin/loop-restart

# --- Restore config.txt ---
info "Restoring config.txt..."
CONFIG_FILE="/boot/firmware/config.txt"
if [ -f "$CONFIG_FILE" ]; then
    sed -i '/# --- Loop Player Setup ---/,/# --- End Loop Player Setup ---/d' "$CONFIG_FILE"
    info "Removed Loop Player settings from config.txt."
fi

# --- Restore cmdline.txt ---
info "Restoring cmdline.txt..."
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE_FILE" ]; then
    sed -i 's/ quiet//g' "$CMDLINE_FILE"
    sed -i 's/ loglevel=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ consoleblank=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ vt.global_cursor_default=[0-9]*//g' "$CMDLINE_FILE"
    sed -i 's/ logo.nologo//g' "$CMDLINE_FILE"
    sed -i 's/console=tty3/console=tty1/g' "$CMDLINE_FILE"
    info "Restored cmdline.txt."
fi

# --- Re-enable getty and graphical target ---
info "Restoring boot defaults..."
systemctl enable getty@tty1.service 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

# --- Done ---
echo ""
info "============================================"
info "  Uninstall complete!"
info "============================================"
echo ""
warn "Rebooting in 10 seconds to apply changes... (Ctrl+C to cancel)"
sleep 10
reboot
