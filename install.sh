#!/usr/bin/env bash
#
# Fingerprint reader installer for FPC/Chipsailing 10a5:9201
# (Xiaomi Book Pro 14 2022 and relatives)
#
# Builds the vrolife/fingerprint-ocv userspace driver with a set of correctness,
# crash and security fixes applied, installs it as a drop-in replacement for
# fprintd, and wires up udev + systemd.
#
# Safe to re-run. Backs up anything it replaces. See ./uninstall.sh to revert.
#
# Usage:
#   sudo ./install.sh                 # build + install
#   sudo ./install.sh --dry-run       # show what would happen, change nothing
#   sudo ./install.sh --skip-deps     # don't touch the package manager
#
set -euo pipefail

REPO_URL="https://github.com/vrolife/fingerprint-ocv.git"
REPO_REF="${REPO_REF:-}"            # optional pinned commit
SRC_DIR="${SRC_DIR:-/usr/local/src/fingerprint-ocv}"
DEST="/usr/local/bin/fingerpp"
DATA_DIR="/var/lib/fprint"
BACKUP_DIR="$DATA_DIR/backups"
UNIT_DROPIN="/etc/systemd/system/fprintd.service.d/override.conf"
UDEV_RULE="/etc/udev/rules.d/99-fpc9201.rules"

VENDOR_ID="10a5"
PRODUCT_ID="9201"

# Tuning. min-area is the stitched template area required to finish enrolling;
# larger means more of the finger is covered, which is what gives tolerance to
# angle/offset and to ridge wear. min-score is the MSSIM match threshold.
MIN_AREA="${MIN_AREA:-150000}"
MIN_SCORE="${MIN_SCORE:-0.30}"

DRY_RUN=0
SKIP_DEPS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --skip-deps) SKIP_DEPS=1 ;;
        -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- helpers ----
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '\n%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[error]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# ------------------------------------------------------------ preflight ------
log "Checking hardware"
if command -v lsusb >/dev/null 2>&1; then
    if lsusb | grep -qi "${VENDOR_ID}:${PRODUCT_ID}"; then
        echo "  found ${VENDOR_ID}:${PRODUCT_ID}"
    else
        warn "USB device ${VENDOR_ID}:${PRODUCT_ID} not detected."
        warn "This driver is ONLY for that sensor. Continuing anyway;"
        warn "the daemon will simply idle if the device never appears."
    fi
else
    warn "lsusb not available, skipping hardware check"
fi

# ----------------------------------------------------------- distro deps -----
detect_distro() {
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "${ID:-unknown}"
    else echo unknown; fi
}
DISTRO="$(detect_distro)"

install_deps() {
    log "Installing build dependencies (distro: $DISTRO)"
    case "$DISTRO" in
        fedora|rhel|centos|rocky|almalinux)
            run dnf install -y gcc-c++ cmake make git pkgconf-pkg-config \
                libusb1-devel libevent-devel dbus-devel openssl-devel \
                opencv-devel fprintd fprintd-pam
            ;;
        debian|ubuntu|linuxmint|pop|elementary)
            run apt-get update
            run apt-get install -y g++ cmake make git pkg-config \
                libusb-1.0-0-dev libevent-dev libdbus-1-dev libssl-dev \
                libopencv-dev fprintd libpam-fprintd
            ;;
        arch|manjaro|endeavouros)
            run pacman -Sy --needed --noconfirm gcc cmake make git pkgconf \
                libusb libevent dbus openssl opencv fprintd
            ;;
        opensuse*|sles)
            run zypper install -y gcc-c++ cmake make git pkg-config \
                libusb-1_0-devel libevent-devel dbus-1-devel libopenssl-devel \
                opencv-devel fprintd fprintd-pam
            ;;
        *)
            warn "Unrecognised distro '$DISTRO'. Install these yourself:"
            warn "  a C++17 compiler, cmake, make, git, pkg-config,"
            warn "  and dev packages for: libusb-1.0, libevent, dbus-1,"
            warn "  openssl, opencv4, plus fprintd and its PAM module."
            warn "Then re-run with --skip-deps."
            die "cannot auto-install dependencies on this distro"
            ;;
    esac
}
[ "$SKIP_DEPS" = 1 ] && log "Skipping dependency install (--skip-deps)" || install_deps

# --------------------------------------------------------------- sanity ------
log "Verifying toolchain and libraries"
for tool in git cmake make pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
if ! pkg-config --exists opencv4; then
    die "opencv4 not found by pkg-config - install the OpenCV dev package"
fi
OPENCV_VER="$(pkg-config --modversion opencv4)"
echo "  OpenCV $OPENCV_VER"
echo "  $(cmake --version | head -1)"

# ---------------------------------------------------------------- fetch ------
log "Fetching driver source into $SRC_DIR"
if [ -d "$SRC_DIR/.git" ]; then
    echo "  existing checkout found; leaving it in place"
else
    run mkdir -p "$(dirname "$SRC_DIR")"
    run git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

if [ "$DRY_RUN" = 0 ]; then
    cd "$SRC_DIR"
    [ -n "$REPO_REF" ] && git fetch --depth 1 origin "$REPO_REF" && git checkout -q FETCH_HEAD
    # Only the code submodules. vcpkg is huge, needs SSH, and we build against
    # system libraries instead.
    git submodule update --init --depth 1 asyncdbus asyncusb jinx
fi

# ---------------------------------------------------------------- patch ------
log "Applying fixes"
apply_patch() {
    local dir="$1" patch="$2" name
    name="$(basename "$patch")"
    if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] apply %s in %s\n' "$name" "$dir"; return; fi
    if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "  already applied: $name"
    elif git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$dir" apply "$patch"
        echo "  applied: $name"
    else
        die "cannot apply $name - upstream source has changed. Update the patch."
    fi
}

P="$SCRIPT_DIR/patches"
apply_patch "$SRC_DIR"           "$P/02-cvext-matching-robustness.patch"
apply_patch "$SRC_DIR"           "$P/03-main-umask-security.patch"
apply_patch "$SRC_DIR"           "$P/04-fpc9201-signal-and-logging.patch"
apply_patch "$SRC_DIR"           "$P/05-fingerprint-atomic-save.patch"
apply_patch "$SRC_DIR"           "$P/06-cmake-system-libs.patch"
apply_patch "$SRC_DIR/asyncdbus" "$P/01-asyncdbus-no-abort-on-spurious-wakeup.patch"
apply_patch "$SRC_DIR/jinx"      "$P/00-jinx-result-move-assign.patch"

# Fail loudly rather than shipping a driver that crashes or leaks the DB.
if [ "$DRY_RUN" = 0 ]; then
    log "Verifying critical fixes are present"
    fail=0
    grep -q '::abort();' "$SRC_DIR/asyncdbus/include/jinx/dbus/dbus.hpp" \
        && { echo "  MISSING: crash fix";    fail=1; } || echo "  ok: crash fix"
    grep -q 'umask(0077)' "$SRC_DIR/src/main.cpp" \
        && echo "  ok: umask fix"           || { echo "  MISSING: umask fix"; fail=1; }
    grep -q 'homography_is_sane' "$SRC_DIR/src/cvext.cpp" \
        && echo "  ok: matching fix"        || { echo "  MISSING: matching fix"; fail=1; }
    grep -q 'VerifyFingerSelected"' "$SRC_DIR/src/drv_fpc/fpc9201.cpp" \
        && echo "  ok: prompt signal fix"   || { echo "  MISSING: prompt signal"; fail=1; }
    # Emitting the signal is not enough: pam_fprintd discards it unless it
    # arrives after the VerifyStart method return. This function is what
    # defers it into the reply continuation.
    grep -q 'send_verify_finger_selected' "$SRC_DIR/src/drv_fpc/fpc9201.cpp" \
        && echo "  ok: prompt ordering fix" || { echo "  MISSING: prompt ordering fix"; fail=1; }
    [ "$fail" -eq 0 ] || die "required fixes are not present - aborting"
fi

# ---------------------------------------------------------------- build ------
log "Building (Release)"
if [ "$DRY_RUN" = 0 ]; then
    cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$SRC_DIR/build" -j"$(nproc)" >/dev/null
    NEW_BIN="$SRC_DIR/build/src/fingerprint-ocv"
    [ -x "$NEW_BIN" ] || die "build produced no binary at $NEW_BIN"
    missing="$(ldd "$NEW_BIN" | grep -c 'not found' || true)"
    [ "$missing" -eq 0 ] || { ldd "$NEW_BIN" | grep 'not found'; die "$missing libraries missing"; }
    echo "  built OK, 0 missing libraries"
else
    echo "  [dry-run] cmake configure + build"
fi

# -------------------------------------------------------------- install ------
log "Installing"
run mkdir -p "$BACKUP_DIR" "$(dirname "$UNIT_DROPIN")"
TS="$(date +%Y%m%d%H%M%S)"

if [ -f "$DEST" ]; then
    run cp -a "$DEST" "$BACKUP_DIR/fingerpp.bak.$TS"
    echo "  backed up existing binary"
fi
# The upstream binary is called fingerprint-ocv; we install it as 'fingerpp'
# because the systemd drop-in below refers to that name.
run install -m 0755 "${NEW_BIN:-/dev/null}" "$DEST"

# udev: let the logged-in user open the device without root.
if [ ! -f "$UDEV_RULE" ]; then
    if [ "$DRY_RUN" = 0 ]; then
        cat > "$UDEV_RULE" <<EOF
# FPC/Chipsailing $VENDOR_ID:$PRODUCT_ID fingerprint sensor
SUBSYSTEM=="usb", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", TAG+="uaccess"
EOF
    fi
    [ "$DRY_RUN" = 1 ] && echo "  [dry-run] would write $UDEV_RULE" || echo "  wrote $UDEV_RULE"
else
    echo "  udev rule already present"
fi

# systemd: replace stock fprintd's ExecStart with our daemon. Using a drop-in
# (not editing the unit) keeps this safe across fprintd package upgrades.
[ -f "$UNIT_DROPIN" ] && run cp -a "$UNIT_DROPIN" "$BACKUP_DIR/override.conf.bak.$TS"
if [ "$DRY_RUN" = 0 ]; then
    cat > "$UNIT_DROPIN" <<EOF
# Installed by xiaomi-fpc9201-fingerprint-linux
# Replaces stock fprintd with the patched fingerprint-ocv daemon, which claims
# the same D-Bus name (net.reactivated.Fprint) and so works with PAM/GNOME.
[Service]
ExecStart=
ExecStart=$DEST --bus=system --min-score=$MIN_SCORE --min-area=$MIN_AREA
Restart=on-failure
RestartSec=1s
EOF
fi
if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] would write $UNIT_DROPIN"; else echo "  wrote $UNIT_DROPIN"; fi

# Existing template DB must not be group/other accessible. Upstream had an
# inverted umask that created it world-writable; fix any legacy file.
if [ -f "$DATA_DIR/fpc9201.bin" ]; then
    run chmod 0600 "$DATA_DIR/fpc9201.bin"
    run chown root:root "$DATA_DIR/fpc9201.bin"
    if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] would secure $DATA_DIR/fpc9201.bin"; else echo "  secured $DATA_DIR/fpc9201.bin (0600)"; fi
fi

log "Reloading services"
run udevadm control --reload-rules
run udevadm trigger --subsystem-match=usb --attr-match=idVendor="$VENDOR_ID" || true
run systemctl daemon-reload
run systemctl reset-failed fprintd.service || true
run systemctl restart fprintd.service

if [ "$DRY_RUN" = 0 ]; then
    sleep 2
    systemctl is-active --quiet fprintd.service \
        || die "fprintd failed to start - check: journalctl -u fprintd -n 40"
    echo "  fprintd is active"
fi

# ------------------------------------------------------------- PAM note ------
log "PAM"
if command -v authselect >/dev/null 2>&1; then
    if authselect current 2>/dev/null | grep -q with-fingerprint; then
        echo "  authselect: with-fingerprint already enabled"
    else
        warn "Fingerprint is not enabled in PAM. Enable it with:"
        warn "    sudo authselect enable-feature with-fingerprint"
        warn "(This installer does NOT edit PAM: a mistake there can lock you out.)"
    fi
elif command -v pam-auth-update >/dev/null 2>&1; then
    echo "  Debian/Ubuntu: enable with 'sudo pam-auth-update' -> tick fingerprint"
else
    warn "Enable pam_fprintd for your distro manually. This installer does not"
    warn "edit PAM files, by design - errors there can lock you out of the system."
fi

# ---------------------------------------------------------------- done -------
if [ "$DRY_RUN" = 1 ]; then
    log "Dry run complete - nothing was changed"
    exit 0
fi

cat <<EOF

$(printf '%s' "$c_grn")Installation complete.$(printf '%s' "$c_off")

Next steps:

  1. Enroll a finger (run in a REAL terminal - it is interactive):

       sudo stdbuf -oL fprintd-enroll "\${SUDO_USER:-\$USER}" -f right-index-finger

     Vary the finger on every press: rotate ~10-15 degrees each way, shift
     toward tip and joint, toward each edge. Expect 20-40 presses. It must
     reach 'enroll: completed' - interrupting saves nothing.

  2. Test it:

       sudo fprintd-verify "\${SUDO_USER:-\$USER}" -f right-index-finger

  3. Check the install:

       sudo $SCRIPT_DIR/scripts/verify-install.sh

  4. LOG OUT AND BACK IN before expecting the GNOME lock-screen fingerprint
     hint. GNOME Shell looks the fingerprint device up once, at session start,
     so a freshly installed driver is not picked up until a new session. Then
     lock the screen and look under the password field for
     "(or place finger on reader)".

Notes:
  * An OpenCV major/minor upgrade breaks the binary (soname change). Re-run
    this installer to rebuild.

EOF
