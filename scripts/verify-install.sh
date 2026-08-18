#!/usr/bin/env bash
#
# Post-install self-check. Read-only: inspects state, changes nothing.
#
# Confirms every layer between the USB device and PAM, and reports the exact
# next step when something is wrong.
#
#   sudo ./scripts/verify-install.sh
#
set -uo pipefail

VENDOR_ID="10a5"; PRODUCT_ID="9201"
DEST="/usr/local/bin/fingerpp"
DB="/var/lib/fprint/fpc9201.bin"
DROPIN="/etc/systemd/system/fprintd.service.d/override.conf"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
pass=0; fail=0; warnc=0
ok()   { printf '  %s[ ok ]%s %s\n'   "$c_grn" "$c_off" "$*"; pass=$((pass+1)); }
bad()  { printf '  %s[fail]%s %s\n'   "$c_red" "$c_off" "$*"; fail=$((fail+1)); }
warn() { printf '  %s[warn]%s %s\n'   "$c_yel" "$c_off" "$*"; warnc=$((warnc+1)); }
sec()  { printf '\n%s\n' "$*"; }

USER_NAME="${SUDO_USER:-$USER}"
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sec "1. Hardware"
if lsusb 2>/dev/null | grep -qi "$VENDOR_ID:$PRODUCT_ID"; then
    ok "sensor $VENDOR_ID:$PRODUCT_ID present"
else
    bad "sensor $VENDOR_ID:$PRODUCT_ID NOT found (this driver only supports it)"
fi

sec "2. Daemon binary"
if [ -x "$DEST" ]; then
    ok "$DEST installed"
    miss="$(ldd "$DEST" 2>/dev/null | grep -c 'not found')"
    if [ "$miss" -eq 0 ]; then
        ok "all shared libraries resolve"
    else
        bad "$miss missing libraries - OpenCV probably upgraded; re-run install.sh"
        ldd "$DEST" | grep 'not found' | sed 's/^/         /'
    fi
else
    bad "$DEST not installed - run install.sh"
fi

sec "3. systemd"
if [ -f "$DROPIN" ]; then
    ok "drop-in present"
    grep -q "$DEST" "$DROPIN" && ok "drop-in points at our daemon" \
                              || bad "drop-in does not reference $DEST"
else
    bad "no drop-in at $DROPIN - stock fprintd is in use and cannot drive this sensor"
fi
if systemctl is-active --quiet fprintd.service; then
    ok "fprintd.service active"
    running="$(ps -o args= -C fingerpp 2>/dev/null | head -1)"
    [ -n "$running" ] && ok "running: $running" || warn "fprintd active but fingerpp process not found"
else
    bad "fprintd.service not active - check: journalctl -u fprintd -n 40"
fi
restarts="$(systemctl show fprintd -p NRestarts --value 2>/dev/null || echo 0)"
if [ "${restarts:-0}" -gt 3 ]; then
    warn "fprintd has restarted $restarts times - it may be crashing"
else
    ok "restart count healthy ($restarts)"
fi

sec "4. Template database"
if [ -f "$DB" ]; then
    perms="$(stat -c '%a' "$DB")"
    if [ "$perms" = "600" ]; then
        ok "$DB is 0600"
    else
        bad "$DB is $perms - should be 600 (biometric data must not be group/other accessible)"
        echo "         fix: sudo chmod 0600 $DB"
    fi
else
    warn "no template database yet (nothing enrolled)"
fi

sec "5. D-Bus API"
dbus_get() {
    dbus-send --system --print-reply --dest=net.reactivated.Fprint \
        "$1" "$2" ${3:+"$3"} ${4:+"$4"} 2>/dev/null
}
if dbus_get /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager.GetDefaultDevice | grep -q "object path"; then
    ok "GetDefaultDevice responds (GNOME uses this)"
else
    bad "GetDefaultDevice failed - GNOME will not see a reader"
fi
if dbus_get /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager.GetDevices | grep -q "object path"; then
    ok "GetDevices responds (pam_fprintd uses this)"
else
    bad "GetDevices failed - PAM will not see a reader"
fi
scan_type="$(dbus-send --system --print-reply --dest=net.reactivated.Fprint \
    /net/reactivated/Device/0 org.freedesktop.DBus.Properties.Get \
    string:"net.reactivated.Fprint.Device" string:"scan-type" 2>/dev/null | tail -1 | grep -o '"[a-z]*"' | tr -d '"')"
[ "$scan_type" = "press" ] && ok "scan-type = press" || bad "scan-type unexpected: '${scan_type:-<none>}'"

sec "6. Enrolled fingers"
if command -v fprintd-list >/dev/null 2>&1; then
    out="$(fprintd-list "$USER_NAME" 2>&1)"
    if echo "$out" | grep -q "^ - #"; then
        ok "enrolled for $USER_NAME:"
        echo "$out" | grep "^ - #" | sed 's/^/         /'
    else
        warn "nothing enrolled for $USER_NAME"
        echo "         enroll: sudo stdbuf -oL fprintd-enroll $USER_NAME -f right-index-finger"
    fi
else
    warn "fprintd-list not found (install the fprintd package)"
fi

sec "7. PAM"
if command -v authselect >/dev/null 2>&1; then
    if authselect current 2>/dev/null | grep -q with-fingerprint; then
        ok "authselect: with-fingerprint enabled"
    else
        bad "fingerprint not enabled in PAM"
        echo "         fix: sudo authselect enable-feature with-fingerprint"
    fi
elif [ -f /etc/pam.d/common-auth ]; then
    grep -q pam_fprintd /etc/pam.d/common-auth \
        && ok "pam_fprintd in common-auth" \
        || { bad "pam_fprintd not in common-auth"; echo "         fix: sudo pam-auth-update"; }
else
    warn "cannot determine PAM state on this distro; check pam_fprintd manually"
fi
[ -f /usr/lib64/security/pam_fprintd.so ] || [ -f /usr/lib/x86_64-linux-gnu/security/pam_fprintd.so ] \
    && ok "pam_fprintd.so present" \
    || bad "pam_fprintd.so missing - install fprintd-pam / libpam-fprintd"

sec "8. Prompt signal (the reason a reader can look 'dead')"
if [ -x "$DEST" ]; then
    # Note: `strings ... | grep -q` under `set -o pipefail` can report failure
    # because grep -q exits early and SIGPIPEs strings. Read into a file first.
    _strings_tmp="$(mktemp)"
    strings "$DEST" > "$_strings_tmp" 2>/dev/null || true
    if grep -q 'VerifyFingerSelected' "$_strings_tmp"; then
        ok "binary contains VerifyFingerSelected"
    else
        bad "VerifyFingerSelected absent - unpatched build; no auth prompt will appear"
    fi
    rm -f "$_strings_tmp"
    # The string being present only proves the interface declares it. Upstream
    # declared it and never emitted it, which is exactly the bug. And emitting
    # it is still not enough: pam_fprintd discards the signal unless it arrives
    # AFTER the VerifyStart method return. Only a live test proves both.
    if [ -x "$SCRIPT_SELF_DIR/test-dbus-signals.py" ] && command -v python3 >/dev/null 2>&1; then
        if python3 -c "import dbus, gi" 2>/dev/null; then
            _sig_out="$(python3 "$SCRIPT_SELF_DIR/test-dbus-signals.py" "$USER_NAME" 2>/dev/null)"
            if printf '%s' "$_sig_out" | grep -q "^PASS"; then
                ok "VerifyFingerSelected emitted AFTER VerifyStart return (PAM accepts it)"
            elif printf '%s' "$_sig_out" | grep -q "emitted BEFORE"; then
                bad "VerifyFingerSelected emitted too early - PAM discards it, no prompt"
                echo "         pam_fprintd logs 'Unexpected VerifyFingerSelected' and drops it."
                echo "         Rebuild with current patch 04: sudo ./install.sh"
            else
                bad "signal declared but NOT emitted - PAM/GNOME will show no prompt"
            fi
        else
            warn "python3-dbus/python3-gobject missing; cannot test signal emission"
        fi
    fi
fi

sec "9. Real authentication attempts (current daemon)"
if command -v journalctl >/dev/null 2>&1; then
    # Only count attempts made against the daemon that is running NOW. Counting
    # the whole boot would report failures from before the last rebuild, which
    # are expected and not actionable.
    _since="$(systemctl show fprintd -p ActiveEnterTimestamp --value 2>/dev/null)"
    if [ -n "$_since" ]; then
        _unexpected="$(journalctl --since "$_since" --no-pager 2>/dev/null | grep -c 'Unexpected VerifyFingerSelected' || true)"
        _attempts="$(journalctl --since "$_since" --no-pager 2>/dev/null | grep -c 'verify start:' || true)"
        if [ "${_unexpected:-0}" -gt 0 ]; then
            bad "pam_fprintd discarded $_unexpected VerifyFingerSelected signal(s)"
            echo "         The signal is being emitted before the VerifyStart method"
            echo "         return, so PAM drops it and no prompt appears."
            echo "         Rebuild with current patch 04: sudo ./install.sh"
        elif [ "${_attempts:-0}" -gt 0 ]; then
            ok "$_attempts verify attempt(s) since daemon start, 0 signals discarded"
        else
            ok "no discarded VerifyFingerSelected signals"
        fi
    fi
fi

sec "Summary"
printf '  %d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warnc"
if [ "$fail" -eq 0 ]; then
    printf '  %sInstall looks good.%s\n' "$c_grn" "$c_off"
    cat <<'EOF'

  The GNOME lock-screen hint requires a session started AFTER this install:
  GNOME Shell looks the fingerprint device up once, at session start. Log out
  and back in, then lock the screen and look under the password field for
  "(or place finger on reader)".
EOF
    exit 0
else
    printf '  %sSee the [fail] lines above.%s\n' "$c_red" "$c_off"
    exit 1
fi
