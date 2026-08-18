#!/usr/bin/env bash
#
# Interactive fingerprint enrollment with coaching and live output.
#
# Must run in a real terminal. Enrollment streams prompts as you press, so it
# cannot be piped or wrapped in `timeout` - both hide the prompts and a killed
# run saves nothing.
#
#   ./scripts/enroll.sh                    # right-index-finger
#   ./scripts/enroll.sh left-index-finger
#
set -uo pipefail

FINGER="${1:-right-index-finger}"
USER_NAME="${SUDO_USER:-$USER}"

VALID="left-thumb left-index-finger left-middle-finger left-ring-finger
left-little-finger right-thumb right-index-finger right-middle-finger
right-ring-finger right-little-finger"

if ! echo "$VALID" | tr ' \n' '\n\n' | grep -qx "$FINGER"; then
    echo "Invalid finger name: $FINGER"
    echo "Valid names:"; echo "$VALID" | tr ' ' '\n' | sed '/^$/d;s/^/  /'
    exit 2
fi

command -v fprintd-enroll >/dev/null 2>&1 || { echo "fprintd-enroll not found - install fprintd"; exit 1; }

if ! systemctl is-active --quiet fprintd; then
    echo "fprintd is not running. Start it:  sudo systemctl start fprintd"
    exit 1
fi

# A leftover enroller holds the sensor and silently eats your presses, making it
# look like nothing is happening.
if pgrep -f 'fprintd-(enroll|verify)' >/dev/null 2>&1; then
    echo "Clearing a stale enroll/verify process holding the sensor..."
    sudo pkill -f 'fprintd-(enroll|verify)' 2>/dev/null
    sleep 1
fi

cat <<EOF

Enrolling: $FINGER   (user: $USER_NAME)

This driver stitches MANY presses into one wide template. Coverage is what
buys tolerance, so vary your finger on every press:

  * press, hold ~1s until it reacts, lift completely, place again
  * rotate slightly left, then slightly right (~10-15 degrees)
  * shift toward the fingertip, then toward the joint
  * shift toward the left edge, then the right edge
  * vary pressure: normal, then a little firmer

Expect 20-40 presses. That is intentional: it samples a large area so a
partial or angled press still matches later, and tolerates ridge wear.

Status lines mean:
  enroll-stage-passed      good - coverage is growing, keep going
  enroll-remove-and-retry  lift and place again, slightly different spot
  enroll-completed         done and saved

Do NOT interrupt it. The template is only written at 100%.
If presses keep failing, clean the sensor and your fingertip - oils and dry
skin genuinely cause this.

EOF

read -r -t 3600 -p "Press Enter when ready (Ctrl-C to abort)... " _ || true
echo

# stdbuf -oL keeps output line-buffered so prompts appear as they happen.
sudo stdbuf -oL -eL fprintd-enroll "$USER_NAME" -f "$FINGER"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
    echo "Enrolled. Currently registered:"
    fprintd-list "$USER_NAME" 2>/dev/null | grep "^ - #" | sed 's/^/  /'
    echo
    echo "Test it:  sudo fprintd-verify $USER_NAME -f $FINGER"
else
    echo "Enrollment did not complete (exit $rc)."
    echo "See what the matcher reported:"
    echo "  sudo journalctl -u fprintd --since '-5min' | grep -E 'enroll:|match:'"
fi
exit "$rc"
