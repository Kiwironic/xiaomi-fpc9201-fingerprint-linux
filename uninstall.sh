#!/usr/bin/env bash
#
# Revert what install.sh did: restore stock fprintd, remove our daemon,
# drop-in and udev rule.
#
# Enrolled fingerprints are NOT deleted unless you pass --purge-prints.
#
# Usage:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge-prints    # also delete enrolled templates
#
set -euo pipefail

DEST="/usr/local/bin/fingerpp"
DATA_DIR="/var/lib/fprint"
BACKUP_DIR="$DATA_DIR/backups"
UNIT_DROPIN="/etc/systemd/system/fprintd.service.d/override.conf"
UDEV_RULE="/etc/udev/rules.d/99-fpc9201.rules"
SRC_DIR="${SRC_DIR:-/usr/local/src/fingerprint-ocv}"

PURGE=0
[ "${1:-}" = "--purge-prints" ] && PURGE=1

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '\n%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }

TS="$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

log "Stopping fprintd"
systemctl stop fprintd.service 2>/dev/null || true

log "Removing systemd drop-in"
if [ -f "$UNIT_DROPIN" ]; then
    cp -a "$UNIT_DROPIN" "$BACKUP_DIR/override.conf.removed.$TS"
    rm -f "$UNIT_DROPIN"
    # Remove the directory only if we left it empty.
    rmdir "$(dirname "$UNIT_DROPIN")" 2>/dev/null || true
    echo "  removed (backup: $BACKUP_DIR/override.conf.removed.$TS)"
    echo "  stock fprintd will now be used again"
else
    echo "  none present"
fi

log "Removing udev rule"
if [ -f "$UDEV_RULE" ]; then
    rm -f "$UDEV_RULE"; echo "  removed $UDEV_RULE"
else
    echo "  none present"
fi

log "Removing daemon binary"
if [ -f "$DEST" ]; then
    cp -a "$DEST" "$BACKUP_DIR/fingerpp.removed.$TS"
    rm -f "$DEST"
    echo "  removed (backup: $BACKUP_DIR/fingerpp.removed.$TS)"
else
    echo "  none present"
fi

if [ "$PURGE" = 1 ]; then
    log "Deleting enrolled fingerprints (--purge-prints)"
    if [ -f "$DATA_DIR/fpc9201.bin" ]; then
        cp -a "$DATA_DIR/fpc9201.bin" "$BACKUP_DIR/fpc9201.bin.purged.$TS"
        rm -f "$DATA_DIR/fpc9201.bin"
        echo "  deleted (backup kept: $BACKUP_DIR/fpc9201.bin.purged.$TS)"
    else
        echo "  no template database found"
    fi
else
    echo
    echo "Enrolled fingerprints left untouched at $DATA_DIR/fpc9201.bin"
    echo "(pass --purge-prints to remove them)"
fi

log "Reloading"
udevadm control --reload-rules 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed fprintd.service 2>/dev/null || true
systemctl start fprintd.service 2>/dev/null || warn "stock fprintd did not start (it is socket/D-Bus activated, which is normal)"

cat <<EOF

$(printf '%s' "$c_grn")Uninstall complete.$(printf '%s' "$c_off")

Stock fprintd is restored. Your sensor (10a5:9201) is NOT supported by stock
libfprint, so fingerprint auth will not work until you reinstall this driver.

Source tree left at: $SRC_DIR   (delete manually if you want)
Backups kept in:     $BACKUP_DIR

To disable fingerprint auth in PAM as well:
    sudo authselect disable-feature with-fingerprint     # Fedora/RHEL
    sudo pam-auth-update                                 # Debian/Ubuntu

EOF
