# Technical notes

Detailed internals for contributors and the curious. End users only need the
[README](../README.md).

## How it works

Not a kernel module. The sensor speaks USB with an encrypted, TLS-like
handshake, and all of it is handled in userspace:

```
GNOME / PAM  (authselect with-fingerprint)
      │  D-Bus:  net.reactivated.Fprint
      ▼
fingerpp   ← this daemon; claims the standard fprintd D-Bus name, so PAM and
      │      GNOME talk to it with no changes on their side
      │  libusb
      ▼
USB 10a5:9201   (112x88 raw frame, upscaled to 224x176)
```

The stock `fprintd.service` is redirected with a **systemd drop-in**, so nothing
your distribution ships is edited and package upgrades stay clean.

Matching is **image-based, not minutiae-based**. Enrollment stitches many presses
into one wide template; verification aligns a single press against it. Coverage
is what buys tolerance: a template stitched from many angles still matches a
partial or rotated press. This is why `MIN_AREA` matters far more than lowering
`MIN_SCORE`, and why enrollment asks for so many presses.

| Path | Purpose |
|------|---------|
| `/usr/local/bin/fingerpp` | the daemon (source install; packages use `/usr/libexec/fingerpp` on Fedora, `/usr/lib/fingerpp` elsewhere) |
| `/etc/systemd/system/fprintd.service.d/override.conf` | redirects fprintd (source install; packages ship their own drop-in under `/usr/lib/systemd/system/fprintd.service.d/`) |
| `/etc/udev/rules.d/99-fpc9201.rules` | device access for the local user |
| `/var/lib/fprint/fpc9201.bin` | encrypted templates, **must be `0600`** |
| `/var/lib/fprint/backups/` | automatic backups |
| `/usr/local/src/fingerprint-ocv` | patched source |

## The fixes in detail

Nine bugs — eight diagnosed against real hardware, plus an authorization gap
reported by a user
([#2](https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux/issues/2)).
Note that fault 4's second half was introduced by *this* project's first
attempt at fixing the first half — the failure modes here are subtle.

| # | Fault | Symptom | Patch |
|---|-------|---------|-------|
| 1 | `::abort()` on a spurious D-Bus wakeup | Daemon died repeatedly, taking fprintd and all fingerprint auth with it | `01` |
| 2 | Over-strict, unvalidated image matching | Verification **never** succeeded. Scored 0.07 against a 0.30 threshold while stretching the sample ~2x to force a fit | `02` |
| 3 | `umask(0600)` — inverted | Biometric template database created **world-writable** (mode `0066`) | `03` |
| 4 | Prompt signal never emitted, then emitted too early | **No prompt anywhere.** Reader looked dead even though it worked if you touched it blindly | `04` |
| 5 | `save()` null-deref + in-place truncate | Crash on any write failure; a crash mid-write destroyed **every** enrolled fingerprint | `05` |
| 6 | Unchecked `fread` | Partly uninitialised buffer passed to AEAD decrypt | `05` |
| 7 | `finger-present` latched `true` | D-Bus property permanently wrong after the first press | `04` |
| 8 | No authorization check on enroll/delete | Any local user could add or remove fingerprints on their own account with no prompt — an unattended unlocked session could be given a new passwordless credential | `08` |
| 9 | Disconnect mid-scan `Put` on `_image_queue` | Daemon died with `PendingGetError` when a client vanished during a scan | `09` |

Plus the installer sets `--min-area` to 150000 (the driver's own default is
120000) for wider coverage, and the matcher is hardened against OpenCV
exceptions.

### Fault 2 — why matching could never work

Verification aligns a press to the stored template with SIFT and a RANSAC
homography, then scores similarity with MSSIM. Three problems compounded:

- The **Lowe ratio test was 0.6**, very strict. On a worn or partial print it
  discarded most *true* correspondences, so no homography could be fitted. Now
  **0.75** (Lowe's own recommendation).
- **Nothing validated the homography.** `findHomography` returns *something* from
  4 noisy points. Added a sanity check: finite values, area scale bounded to
  0.64–1.56 (a genuine re-press is ~1:1, which is what rejects the observed 2x
  stretch), near-zero perspective terms, plus a **RANSAC inlier count** so the
  fit must be *supported*, not merely computable.
- **Scores were averaged over arbitrarily tiny overlaps**, which is
  statistically meaningless and can pass by luck. Now requires ≥25% overlap.

Relaxing the ratio test while *adding* geometric validation is the key trade:
more candidates get through, but bad alignments are rejected on geometry.

The diagnostic that cracked it was an `overlap` value far exceeding the frame
size — the homography was stretching the sample about 2x to force a fit.

Result: scores moved from 0.07, never matching, to a comfortable margin above
the 0.30 threshold. Rejected presses still score around 0.06–0.08, which is the
geometric validation correctly refusing a bad alignment.

### Fault 4 — why there was no prompt

`pam_fprintd` uses a D-Bus signal called `VerifyFingerSelected` to learn which
finger was chosen, and turns it into the PAM message "Place your finger on
\<device\>". That message is what `sudo` prints in a terminal and what GNOME
turns into the `(or place finger on reader)` hint under the password field.

There were **two** defects, and the second was introduced by the first attempt at
fixing the first.

**Never emitted.** The driver declared the signal in its D-Bus interface and
never sent it. Verification worked, but nothing ever told the user to touch the
sensor.

**Then emitted too early.** `pam_fprintd` calls `VerifyStart` asynchronously and
sets its internal `verify_started` flag only in the method-return callback. Its
handler discards anything that arrives before that:

```c
if (!data->verify_started) {
    pam_syslog (data->pamh, LOG_ERR, "Unexpected VerifyFingerSelected %s signal", finger_name);
    return 0;
}
```

So emitting the signal before replying to `VerifyStart` produced a signal that
was verifiably on the bus and still yielded no prompt at all. The fix defers
emission until after the reply, so the client always observes method-return then
signal.

A useful clue while debugging: the retry message *did* appear after a failed
press. That travels a different path — a `VerifyStatus` result becomes a PAM
*error* message, which is not subject to the `verify_started` gate. "No prompt up
front, but a message after a failure" is the signature of this bug.

Confirm both emission and ordering:

```bash
sudo ./scripts/test-dbus-signals.py "$USER"
# PASS: VerifyFingerSelected emitted AFTER the VerifyStart method return
```

### Robustness, beyond the specific bugs

OpenCV signals errors by throwing, and this daemon is a **single-threaded event
loop** — so one bad press escaping as an exception killed fingerprint auth for
the whole session. `knnMatch` throws on empty descriptors (a real outcome for a
poor press) and `merge()` built an out-of-range `cv::Range` for rotated edge
presses. Both are now guarded, and `match`/`merge` catch `cv::Exception`. A
failed match is a *normal* outcome and returns `false`.

## Notes for contributors and AI agents

Mistakes made while developing this, each of which cost real time:

- **Read the numbers.** `journalctl -u fprintd | grep -E 'match:|enroll:'` gives
  score, threshold and overlap. An anomalous `overlap` value is what identified
  fault 2; guessing at thresholds would never have found it.
- **"Signal emitted" is not "signal accepted."** Patch `04` once put the prompt
  signal on the bus *before* the `VerifyStart` method return; `pam_fprintd`
  discarded it and logged `Unexpected VerifyFingerSelected`. The test reported
  PASS and the feature was still broken. When a signal-driven feature does not
  work, check the **consumer's** log and its ordering requirements, not just your
  own emission.
- **Read the consumer's source before theorising.** One early hypothesis here was
  that the finger name `any` was being rejected as invalid. It is not — `any` is
  the first entry in `pam_fprintd`'s finger table. Fetching the actual source
  disproved that in one step, after the guess had already produced a wrong
  explanation.
- **The driver binds claims to the D-Bus sender connection.** Testing with
  separate `dbus-send` calls gives a false negative ("not claimed"). Use
  `scripts/test-dbus-signals.py`, which holds one connection.
- **Never run a second daemon instance to test a build.** Both processes fight
  over the USB device and the live daemon aborts. Install the new binary and
  restart the service.
- **`strings X | grep -q` under `set -o pipefail` can spuriously fail** (SIGPIPE
  kills `strings`). Redirect to a file first. This produced a false "unpatched
  build" report.
- **`/var/lib/fprint` is `drwx------`.** An unprivileged `test -f` on files
  inside returns false even when they exist, which can look like data loss.
- **You cannot drive enrollment programmatically.** It needs live human presses
  and streams prompts; non-interactive tool calls only return output after exit.
  Give the user one bare command and stop.
- **Give one command at a time.** Offering an enrollment command plus an optional
  monitoring command led to only the monitoring one being run.
- **Never edit PAM to fix this.** It is the main lockout risk and it breaks on
  upgrades. `authselect` (or `pam-auth-update`) is the supported path.
- **Confirm before deleting enrolled prints.** Re-enrolling costs 20–40 presses
  per finger.
- **Exceptions are fatal here** — single-threaded event loop, so any unguarded
  `cv::` call that throws ends fingerprint auth for the session.
- **A patched source tree can drift from the patch files.** If a regenerated
  patch will not apply, the managed tree at `/usr/local/src/fingerprint-ocv` may
  still have the previous version applied: `sudo git checkout -- <file>` there,
  then re-run the installer.

## Upstreaming

These patches are intended for upstream. A fork fragments an already-niche
driver, so the goal is to get the fixes into
[vrolife/fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv) and let
this repository become a thin installer. See `patches/README.md` for how each
patch is scoped and how to refresh one if upstream moves.
