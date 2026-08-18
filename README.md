# Fingerprint reader support for FPC/Chipsailing `10a5:9201` on Linux

Makes the fingerprint reader in the **Xiaomi Book Pro 14 2022** (and relatives)
work on Linux — log in and run `sudo` with your fingerprint.

## The problem

Linux ships a fingerprint framework called `libfprint`, and it does **not**
support this sensor at all. On a fresh install the reader is simply dead: no
enrollment, no login, nothing in Settings.

This repository fixes that: it builds the
[fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv) userspace driver
with **7 bug fixes** applied and installs it as a drop-in replacement for the
standard fingerprint service, so your desktop and `sudo` use it with no further
configuration.

## What you get

- Fingerprint login at the GNOME lock screen and login screen
- `sudo` authentication by fingerprint
- A prompt telling you when to touch the sensor, and a retry message if a press
  is not recognised

## Does this apply to me?

```bash
lsusb | grep 10a5:9201
```

Output means yes. No output means this is the wrong driver for your hardware.

## Install

```bash
git clone https://github.com/<you>/xiaomi-fpc9201-fingerprint-linux.git
cd xiaomi-fpc9201-fingerprint-linux
sudo ./install.sh
./scripts/enroll.sh
```

Then **log out and back in**, and your fingerprint is ready to use.

Enrollment is interactive and asks for a lot of presses — 20 to 40 is normal.
Vary your finger every time: rotate it slightly each way, shift toward the tip
and the joint, toward each edge. Coverage is what makes recognition reliable
later. Wait for it to say `enroll: completed`; stopping early saves nothing.

To check everything is in place:

```bash
sudo ./scripts/verify-install.sh
```

That runs 18 read-only checks and tells you the exact next step if something is
wrong. It changes nothing.

To remove it:

```bash
sudo ./uninstall.sh          # keeps your enrolled fingerprints
sudo ./uninstall.sh --purge-prints
```

## Everyday use

```bash
./scripts/enroll.sh [finger]              # enroll another finger
sudo fprintd-list "$USER"                 # list enrolled fingers
sudo fprintd-verify "$USER"               # test a press
sudo journalctl -u fprintd -f             # watch what the sensor is doing
```

Reading the log while enrolling or verifying is the fastest way to understand a
problem:

```
enroll: progress=0.68 area=102072/150000     coverage growing, keep going
enroll: merge failed (reposition finger)     press not alignable, shift slightly
enroll: completed                            saved
match: score=0.846 min_score=0.3 overlap=39659/39424    healthy match
```

## Tuning

Only if you need it. Pass these when installing, e.g.
`sudo MIN_AREA=180000 ./install.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `MIN_AREA` | `150000` | How much of your finger must be captured before enrollment finishes. **Raise this for more reliable recognition**, at the cost of more presses. One frame is 39424 px, so 150000 is roughly 3.8 frames. |
| `MIN_SCORE` | `0.30` | Match threshold. Prefer raising `MIN_AREA` first — a well-covered template beats a lowered threshold, and lowering it weakens security. |

## Troubleshooting

Run `sudo ./scripts/verify-install.sh` first; it identifies most problems.

**Service won't start** — `journalctl -u fprintd -n 40`

- `libopencv_*.so.NNN: cannot open shared object file` → OpenCV was upgraded.
  Re-run `sudo ./install.sh` to rebuild. This is expected after an OpenCV
  version bump, not a regression.
- `status=6/ABRT` → the crash fix (patch `01`) is missing from the build.

**Nothing enrolled yet** → `NoEnrolledPrints` is expected, not a fault.

**Verification always fails** — get the numbers instead of guessing:

```bash
sudo journalctl -u fprintd --since '-5min' | grep 'match:'
```

- No `match:` lines at all → the press could not be aligned to your template.
  Re-enroll with more varied coverage.
- `score` far below the threshold (e.g. 0.07) → the template is poor; re-enroll.
- `overlap` far larger than the frame size (e.g. `77212/39424`) → the matching
  fix (patch `02`) is missing.

**No prompt appears, but authentication works if you touch the sensor blindly**

```bash
journalctl -b | grep 'Unexpected VerifyFingerSelected'
```

Any output means the prompt signal is reaching the PAM module too early and
being discarded. Rebuild with the current patch `04`, then confirm with
`sudo ./scripts/test-dbus-signals.py "$USER"`.

A distinctive symptom of this specific bug: no prompt up front, but after a
*failed* press you do see "Place your finger on the reader again". The retry
message travels a different code path that is not affected.

**Enrollment stalls or seems to ignore presses**

- A leftover enroller holds the sensor and silently eats presses. Check with
  `pgrep -af 'fprintd-(enroll|verify)'`.
- Don't pipe enrollment through `tail`/`head` — output buffers and prompts
  vanish. Don't wrap it in `timeout` — being killed mid-run discards everything.
  `./scripts/enroll.sh` handles both.
- Clean the sensor and your fingertip. Oils and dry skin genuinely cause
  repeated merge failures.

**Fingerprint database has group or other permission bits** → the umask fix
(patch `03`) is missing. `sudo chmod 0600 /var/lib/fprint/fpc9201.bin` and
reinstall.

**The daemon aborted right after another copy was started.** Never run a second
copy of the daemon while the service is active, even on a different D-Bus bus.
Both fight over the USB device and the running one dies with
`jinx::exception::JinxError` / `status=6/ABRT`. This is a separate, unfixed bug
from patch `01`. The service restarts itself and authentication recovers. To test
a rebuilt binary, install it and restart the service instead of running it
alongside.

## The GNOME lock-screen hint needs a fresh session

GNOME Shell looks the fingerprint device up once, when your session starts. A
newly installed driver is therefore not noticed until you **log out and back
in**. This is also why the installer tells you to do that.

---

# Standing on someone else's work

None of this would exist without **[vrolife](https://github.com/vrolife)** and
[fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv).

Getting this sensor to produce an image at all is the hard part. It speaks an
encrypted, TLS-style protocol over USB with no public documentation, so support
had to be reverse-engineered from scratch: the handshake, the crypto, the frame
format, and an entire image-based matching pipeline built on OpenCV — for
hardware that every other Linux fingerprint stack ignores. That work is the
foundation of everything here, and finding it is what made these fixes possible.
Debugging a working design is a far smaller job than inventing one.

What remained were the rough edges of an early-stage project: a crash on an
unexpected D-Bus wakeup, matching thresholds too strict to ever succeed, an
inverted `umask`, a non-atomic save, and a prompt signal that was declared but
never sent. Real bugs worth fixing, but small next to the reverse engineering
they sit on — and exactly the kind of thing that only surfaces once other people
run your code on their own hardware.

So the fixes below are offered as contributions back upstream, not as a
criticism, and not as a competing fork. See [Contributing](#contributing).

# How it works

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
into one wide template; verification aligns a single press against it.

> **Coverage is what buys tolerance.** A template stitched from many angles still
> matches a partial or rotated press. This is why `MIN_AREA` matters far more
> than lowering `MIN_SCORE`, and why enrollment asks for so many presses.

| Path | Purpose |
|------|---------|
| `/usr/local/bin/fingerpp` | the daemon |
| `/etc/systemd/system/fprintd.service.d/override.conf` | redirects fprintd |
| `/etc/udev/rules.d/99-fpc9201.rules` | device access for the local user |
| `/var/lib/fprint/fpc9201.bin` | encrypted templates, **must be `0600`** |
| `/var/lib/fprint/backups/` | automatic backups |
| `/usr/local/src/fingerprint-ocv` | patched source |

---

# The fixes in detail

Seven bugs, each diagnosed against real hardware rather than guessed at. Note
that fault 4's second half was introduced by *this* project's first attempt at
fixing the first half — the failure modes here are subtle.

| # | Fault | Symptom | Patch |
|---|-------|---------|-------|
| 1 | `::abort()` on a spurious D-Bus wakeup | Daemon died repeatedly, taking fprintd and all fingerprint auth with it | `01` |
| 2 | Over-strict, unvalidated image matching | Verification **never** succeeded. Scored 0.07 against a 0.30 threshold while stretching the sample ~2x to force a fit | `02` |
| 3 | `umask(0600)` — inverted | Biometric template database created **world-writable** (mode `0066`) | `03` |
| 4 | Prompt signal never emitted, then emitted too early | **No prompt anywhere.** Reader looked dead even though it worked if you touched it blindly | `04` |
| 5 | `save()` null-deref + in-place truncate | Crash on any write failure; a crash mid-write destroyed **every** enrolled fingerprint | `05` |
| 6 | Unchecked `fread` | Partly uninitialised buffer passed to AEAD decrypt | `05` |
| 7 | `finger-present` latched `true` | D-Bus property permanently wrong after the first press | `04` |

Plus the installer sets `--min-area` to 150000 (the driver's own default is
120000) for wider coverage, and the matcher is hardened against OpenCV
exceptions.

## Fault 2 in detail — why matching could never work

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

## Fault 4 in detail — why there was no prompt

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

## Robustness, beyond the specific bugs

OpenCV signals errors by throwing, and this daemon is a **single-threaded event
loop** — so one bad press escaping as an exception killed fingerprint auth for
the whole session. `knnMatch` throws on empty descriptors (a real outcome for a
poor press) and `merge()` built an out-of-range `cv::Range` for rotated edge
presses. Both are now guarded, and `match`/`merge` catch `cv::Exception`. A
failed match is a *normal* outcome and returns `false`.

---

# Status and limitations

**Verified** on Fedora 44 with a Xiaomi Book Pro 14 2022: clean build with no
missing libraries; enrollment completes; verification matches comfortably above
the threshold; fingerprint login works at the GNOME login screen; the prompt
appears in a terminal for `sudo` and the retry message appears after an
unrecognised press; template database is `0600`; `verify-install.sh` reports
18/18.

**Not verified:**

- **Any distro other than Fedora.** Debian/Ubuntu/Arch/openSUSE package mappings
  are written but untested. Reports welcome.
- **Any hardware other than `10a5:9201`**, on one laptop model.
- The GNOME lock-screen hint text specifically. The prompt mechanism it depends
  on is confirmed working at the PAM layer and in a terminal, so it is expected
  to appear, but the lock screen itself has not been checked visually.

**Known limitations:**

- `PropertiesChanged` is not emitted (an upstream TODO). Confirmed **not** to
  affect GNOME, which learns about prompts from PAM messages rather than by
  watching device properties. Other D-Bus clients may care.
- `org.freedesktop.DBus.ObjectManager` is not implemented; stock fprintd has it.
- Running two copies of the daemon at once aborts the running one (see
  Troubleshooting). Unfixed.
- An OpenCV major/minor upgrade breaks the binary via a soname change — re-run
  `install.sh`.
- Image-based matching is inherently weaker than a match-on-chip sensor.
  Reasonable for convenience; consider that before relying on it for anything
  sensitive.
- Templates are encrypted with a key derived in-driver, not tied to a TPM.

---

# Contributing

Most valuable right now: **test reports from other distros and other laptop
models.** Please include your distro and version, `lsusb | grep 10a5`, your
OpenCV version, the output of `sudo ./scripts/verify-install.sh`, and any
`match:` lines from the log.

These patches are intended for upstream. A fork fragments an already-niche
driver, so the goal is to get the fixes into
[vrolife/fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv) and let
this repository become a thin installer. See `patches/README.md` for how each
patch is scoped and how to refresh one if upstream moves.

# Credits and licence

All driver credit belongs to **[vrolife](https://github.com/vrolife)**, who
reverse-engineered this sensor from nothing in
[fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv). This repository
only fixes bugs and adds packaging on top of that work. If this driver is useful
to you, the thanks belong upstream.

The driver is **AGPL-3.0**, so the patches here are AGPL-3.0 too. The installer
scripts and documentation are AGPL-3.0 for consistency. See `LICENSE`.

---

# Notes for contributors and AI agents

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
