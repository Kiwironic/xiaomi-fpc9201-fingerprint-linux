# Hardware and protocol notes

Reference notes for `10a5:9201`. Useful if you are debugging, porting to another
sensor, or picking up this work.

## Device identity

```
Bus 003 Device 003: ID 10a5:9201 FPC FPC Sensor Controller L:0001 FW:021.26.2.031
```

- Reported vendor string is **FPC**, but the driver family is Chipsailing;
  upstream `libfprint` carries an unrelated `cs9711` driver, which does **not**
  work here.
- Firmware seen on the tested unit: `021.26.2.031`, reported by the daemon as
  `Version 21.26.2.31`.
- Stock `libfprint` has **no support** for this device. Nothing you install from
  your distro repos will drive it.

## Why not a kernel module

The sensor is a plain USB device requiring an encrypted, TLS-like handshake
before it will return image data. All of that is ordinary userspace work —
libusb plus OpenSSL. A kernel driver would gain nothing and would have to
implement crypto in kernel space.

If you are considering the kernel-module route for this device, the handshake is
the reason not to: without it the sensor never returns a frame at all.

## Image pipeline

| Stage | Detail |
|-------|--------|
| Raw frame | 112 × 88, 8-bit greyscale (9856 bytes) |
| Preprocess | `equalizeHist`, then gamma 1.5 |
| Upscale | 224 × 176 (39424 px) — all matching happens here |
| Enrollment | Many frames stitched via SIFT + homography into one wide template with a coverage mask |
| Verification | One frame aligned to the template, scored with MSSIM over the overlap |

Enrollment completes when the stitched mask area reaches `--min-area`
(default 150000 ≈ 3.8 frames).

Because matching is image-based rather than minutiae-based, **coverage during
enrollment is the dominant factor** in later tolerance to angle, offset and
ridge wear.

## Template storage

- `/var/lib/fprint/fpc9201.bin` — a single **ChaCha20-Poly1305** encrypted blob
  holding *all* users and fingers, serialised as OpenCV `FileStorage` JSON
  (the raw matrices, hence the multi-MB size).
- Must be mode `0600`. Upstream's inverted `umask(0600)` created it
  world-writable; see patch `03`.
- Writes are now atomic (temp file + `fsync` + `rename`). Previously the live
  file was truncated in place, so a crash mid-write lost every enrolled print.
- The encryption key is derived inside the driver and is **not** TPM-bound.

## D-Bus surface

The daemon claims `net.reactivated.Fprint`, impersonating fprintd, so PAM and
GNOME need no changes.

Implemented: `Manager.GetDevices`, `Manager.GetDefaultDevice`,
`Device.{Claim,Release,ListEnrolledFingers,DeleteEnrolledFinger(s),
DeleteEnrolledFingers2,VerifyStart,VerifyStop,EnrollStart,EnrollStop}`,
properties `name`, `num-enroll-stages`, `scan-type`, `finger-present`,
`finger-needed`, signals `VerifyStatus`, `EnrollStatus`, `VerifyFingerSelected`.

Not implemented: `org.freedesktop.DBus.ObjectManager`, and
`PropertiesChanged` is never emitted.

### Things that will bite you

- **Claims are bound to the caller's D-Bus connection name.** Testing with
  separate `dbus-send` invocations fails with `not claimed`, because each
  invocation is a new connection. Use one connection —
  `scripts/test-dbus-signals.py` does this.
- **`VerifyFingerSelected` drives the entire user-visible prompt.**
  `pam_fprintd` turns it into the PAM message
  `"Place your finger on <device>"`; `sudo` prints that in a terminal and GNOME
  converts it into `(or place finger on reader)`. Upstream declared the signal
  and never sent it, so the reader appeared dead while working perfectly.
- **The signal must arrive *after* the `VerifyStart` method return.**
  `pam_fprintd` sets its internal `verify_started` flag only in the
  method-return callback and discards anything that arrives earlier, logging
  `Unexpected VerifyFingerSelected`. Emitting the signal before replying
  therefore produces no prompt at all, even though the signal is provably on the
  bus. See patch `04`.
- **GNOME Shell looks the device up once at session start** and creates the proxy
  with `Gio.DBusProxyFlags.DO_NOT_CONNECT_SIGNALS`. A newly installed driver is
  not seen until re-login. Because it never connects device signals, the hint is
  driven entirely by PAM messages relayed through GDM — which is why the missing
  `PropertiesChanged` does not affect it.
- **`finger-present` has no hardware finger-up event.** The driver clears it
  after a frame is captured; treat it as approximate.

## Client call sequences

What `pam_fprintd` does:

```
Manager.GetDevices → Device.Claim(user) → [subscribe VerifyFingerSelected]
  → Device.VerifyStart("any")  ⟵ sets verify_started in the reply callback
  → VerifyFingerSelected (accepted only after that reply)
  → VerifyStatus signals → VerifyStop → Release
```

It calls `VerifyStart` asynchronously, so the reply and the signals interleave;
the ordering above is what the driver must produce.

What GNOME Shell does:

```
Manager.GetDefaultDevice → device proxy (DO_NOT_CONNECT_SIGNALS)
  → read property "scan-type"  (press | swipe)
```

## Diagnostics

```bash
# Live matcher numbers - score, threshold, overlap
sudo journalctl -u fprintd -f | grep -E 'enroll:|match:'

# Confirm the prompt signal is emitted, and emitted late enough
sudo ./scripts/test-dbus-signals.py "$USER"

# Full API surface
busctl --system introspect net.reactivated.Fprint /net/reactivated/Device/0
```

Interpreting `match:` lines:

| Observation | Meaning |
|-------------|---------|
| No `match:` line at all | No homography could be fitted; press does not align to the template |
| `score` well below threshold | Template is poor — re-enroll with more varied coverage |
| `overlap` exceeding frame size (e.g. `77212/39424`) | Bogus stretched alignment; the homography scale check should reject this |
| `score` 0.5–0.9, overlap 60–100% of frame | Healthy |

## Build coupling

The daemon links system OpenCV. A **major/minor OpenCV upgrade changes the
soname** and the binary stops loading:

```
fingerpp: error while loading shared libraries: libopencv_imgcodecs.so.NNN
```

Observed: worked on OpenCV 4.11, broke on 4.13. Re-run `install.sh` to rebuild.
This will recur on every OpenCV bump; it is not a regression.
