# Patches

Fixes applied to [vrolife/fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv)
on top of upstream `main`. `install.sh` applies these automatically and refuses
to build if the critical ones are missing.

Each is idempotent — already-applied patches are detected and skipped.

These are offered in the spirit of contributing back: each one is scoped to a
single problem so it can be reviewed, taken, or rejected on its own merits, and
they are all intended to land upstream rather than live in a fork.

| Patch | Target | Severity | Fixes |
|-------|--------|----------|-------|
| `00-jinx-result-move-assign` | `jinx/` submodule | build | `_empty` accessed outside its `NDEBUG` guard and a missing `return *this` — Release builds fail on newer GCC |
| `01-asyncdbus-no-abort-on-spurious-wakeup` | `asyncdbus/` submodule | **crash** | `::abort()` when a D-Bus pending call was woken before completing. Killed the daemon and all fingerprint auth |
| `02-cvext-matching-robustness` | `src/cvext.cpp` | **function** | Verification could never succeed. Ratio test 0.6→0.75, homography sanity + RANSAC inlier checks, overlap floor, exception safety |
| `03-main-umask-security` | `src/main.cpp` | **security** | `umask(0600)` is inverted (umask takes bits to *remove*), leaving the biometric database world-writable |
| `04-fpc9201-signal-and-logging` | `src/drv_fpc/fpc9201.cpp` | **function** | Emits `VerifyFingerSelected` (declared upstream, never sent) **after** the `VerifyStart` method return, so `pam_fprintd` accepts it and PAM/GNOME show a prompt; clears latched `finger-present`; labelled logging |
| `05-fingerprint-atomic-save` | `src/drv_fpc/fingerprint.cpp` | **data loss** | `save()` dereferenced NULL on `fopen` failure and truncated the live DB in place; now temp-file + `fsync` + atomic `rename`. Also checks `fread` |
| `06-cmake-system-libs` | `CMakeLists.txt`, `src/CMakeLists.txt` | build | Build against system OpenCV/libevent instead of vcpkg |
| `07-opencv5-module-names` | `src/CMakeLists.txt` | build | OpenCV 5 renamed the `features2d` and `calib3d` modules to `features` and `calib`, so the hardcoded link names failed with `cannot find -lopencv_features2d`. Selects the right names via `OpenCV_VERSION_MAJOR`, keeping OpenCV 4 working |
| `08-polkit-authorization` | `src/drv_fpc/fpc9201.cpp` | **security** | No authorization check on enroll/delete — any local user could add or remove fingerprints with no prompt. Adds polkit `CheckAuthorization` for `net.reactivated.fprint.device.enroll` (stock fprintd's `auth_self_keep` action), failing closed. The check runs on a side task (`WorkerPolkitGate`) — required, see below — and the call is re-queued once authorized. Root stays authorized, so `sudo fprintd-enroll` is unaffected |
| `09-disconnect-mid-scan-crash` | `src/drv_fpc/fpc9201.cpp` | **crash** | Client disconnect mid-scan killed the daemon: a cancelled `WorkerEnrollVerify` can leave a pending `Get` on `_image_queue`, and the disconnect path's `send_enroll_stop()` then `Put` to it — `PendingGetError`. Now resets the queue and stops the sensor via the control queue (`FPP_StopSensor`) |
| `10-jinx-queue2-get-return` | `jinx/` submodule | build | `Queue2::Get::async_poll` fell off the end of a non-void function after its switch — `-Wreturn-type` warning and UB if `Queue2Status` ever gains a value. Defensive `async_throw` added |
| `11-jinx-error-message-fallback` | `jinx/` submodule | build | `JINX_ERROR_IMPLEMENT` generates a `message()` whose switch has no default — same `-Wreturn-type` UB at every expansion site (eventengine, openssl). Fallback `"unknown error"` return added in the macro |
| `12-crypto-evp-mac-hmac` | `src/drv_fpc/crypto.cpp` | build | `HMAC_CTX_*` calls are deprecated since OpenSSL 3.0 and slated for removal. Replaced with the `EVP_MAC` API; signature check now uses constant-time `CRYPTO_memcmp` |


## Patch 08: why the check runs on a side task

This daemon's message pump is strictly serial — one `WorkerDevice` task
loops `get → dispatch → handle → get`. A `CheckAuthorization` awaited on
that task parks the whole device: while the check was pending, **every
other call to the device queued behind it**.

That matters because the polkit agent's helper runs `pam_fprintd`, which
calls `Claim` on this same device. Observed with an earlier version of
this fix: the Claim sat in the queue until its ~25s D-Bus timeout,
`pam_fprintd` failed, PAM fell through to `pam_unix`, and the password
dialog appeared — at the same moment the client's `EnrollStart` timed
out. Reproducible every time, independent of the desktop environment's
state.

Upstream `fprintd` uses a *synchronous* `CheckAuthorization` on the same
code path, but gets away with it because `polkit_authority_check_
authorization_sync` keeps iterating the GLib main loop while it waits —
other calls still dispatch ("This may possibly block the invocation till
the user has not provided an authentication method, so other calls could
arrive"). This jinx runtime has no nested loop, so the check lives on a
side task:

- `check_polkit` parks a `ref`'d copy of the call, spawns a
  `WorkerPolkitGate` task, and returns to `run()` — the dispatch loop
  stays live.
- The helper's `Claim` now dispatches immediately and fails fast with
  `AlreadyInUse`, so the dialog's password prompt appears in about a
  second (same as upstream, where the claimed device is equally
  unavailable to the helper).
- On `authorized`, the gate re-queues the original call into the device
  message queue; it dispatches again, finds its gate entry marked
  authorized, and proceeds through `check_sender`/`enroll_verify_start`
  normally. On denial the gate replies `PermissionDenied` directly.
- On caller disconnect or `Release` mid-check, `drop_auth_gates` cancels
  the gate task; its `async_finalize` sends `CancelCheckAuthorization`
  (cancellation id `fingerpp-<sender>:<serial>`) so no orphaned dialog
  lingers. An already-authorized serial is tombstoned, not erased, so a
  re-queued call still in the queue is dropped rather than spawning a
  fresh check.
- The gate map is keyed by `"<sender>:<serial>"` — D-Bus serials are
  per-connection, so the sender must be part of the key.

Fail-closed throughout: no reply, malformed reply, denial, or timeout all
deny. A `Claim` by another user while a check is pending is rejected
early without prompting, matching upstream's claimed-check-first order.

## Patch 09: disconnect mid-scan crash

A cancelled `WorkerEnrollVerify` can leave a pending `Get` on
`_image_queue`. The old `NameOwnerChanged` disconnect path then called
`send_enroll_stop()`, which `Put`s `FPP_EnrollVerifyStop` onto that queue —
waking a dead awaitable and throwing `PendingGetError` (observed: daemon
killed when a client disconnected mid-scan). The disconnect path now
resets `_image_queue` after the cancel and posts `FPP_StopSensor` to
`_event_queue` (the control loop) directly — the client is gone, so no
`EnrollStatus` signal is needed. `release()`/`EnrollStop` are unchanged:
those use `resume()`/a live task, which drains the queue normally.

## Patch 04 and signal ordering

Patch 04 is the one to read carefully before touching, because emitting
`VerifyFingerSelected` is necessary but **not sufficient**.

`pam_fprintd` calls `VerifyStart` asynchronously and sets its internal
`verify_started` flag only in the method-return callback. Its signal handler
begins ([pam_fprintd.c](https://gitlab.freedesktop.org/libfprint/fprintd/-/blob/master/pam/pam_fprintd.c)):

```c
if (!data->verify_started) {
    pam_syslog (data->pamh, LOG_ERR, "Unexpected VerifyFingerSelected %s signal", finger_name);
    return 0;
}
```

So a signal that reaches the client **before** the method return is parsed,
logged as unexpected, and discarded — no PAM message, no GNOME hint. The
first version of this patch did exactly that: the signal was verifiably on the
bus, `test-dbus-signals.py` reported PASS, and the hint still never appeared.
The journal showed the reason:

```
pam_fprintd(gdm-fingerprint:auth): Unexpected VerifyFingerSelected any signal
```

The patch now awaits the method return and emits the signal from the
continuation (`send_verify_finger_selected`). Both go out through
`dbus_connection_send`, which appends to one ordered outgoing queue, and D-Bus
preserves per-sender ordering — so the client is guaranteed to see
return-then-signal.

`scripts/test-dbus-signals.py` asserts this ordering, not just emission. If you
rework this patch, that test must still report:

```
order seen: ['method_return:VerifyStart', 'signal:VerifyFingerSelected']
```

Note that `any` is a legitimate finger name — it is the first entry in
`pam_fprintd`'s
[fingerprint-strings.h](https://gitlab.freedesktop.org/libfprint/fprintd/-/blob/master/pam/fingerprint-strings.h)
table and maps to "Place your finger on %s". Resolving `any` to a specific
enrolled finger is therefore unnecessary; ordering was the whole problem.

## Applying manually

Patches are applied in numeric order. `02`–`09` and `12` apply at the repo
root; `00`, `01`, `10` and `11` target submodules and **must** be applied
from inside the submodule directory — a single top-level
`git apply patches/*.patch` fails with `No such file or directory` on
those paths.

```bash
cd /usr/local/src/fingerprint-ocv
P=/path/to/this/repo/patches

git -C jinx      apply "$P"/00-*.patch
git -C asyncdbus apply "$P"/01-*.patch
git apply "$P"/0{2,3,4,5,6,7,8,9}-*.patch
git -C jinx      apply "$P"/10-*.patch "$P"/11-*.patch
git apply "$P"/12-*.patch
```

Check whether one is already applied:

```bash
git apply --reverse --check "$P"/03-main-umask-security.patch && echo "already applied"
```

## Verifying the important ones landed

```bash
cd /usr/local/src/fingerprint-ocv
grep -q '::abort();' asyncdbus/include/jinx/dbus/dbus.hpp && echo "CRASH FIX MISSING"
grep -q 'umask(0077)'          src/main.cpp             || echo "UMASK FIX MISSING"
grep -q 'homography_is_sane'   src/cvext.cpp            || echo "MATCHING FIX MISSING"
grep -q 'VerifyFingerSelected' src/drv_fpc/fpc9201.cpp  || echo "PROMPT FIX MISSING"
grep -q 'send_verify_finger_selected' src/drv_fpc/fpc9201.cpp \
    || echo "PROMPT ORDERING FIX MISSING (signal emitted too early; PAM drops it)"
grep -q 'CheckAuthorization'        src/drv_fpc/fpc9201.cpp  || echo "POLKIT FIX MISSING"
grep -q 'WorkerPolkitGate'          src/drv_fpc/fpc9201.cpp  || echo "AUTH GATE FIX MISSING"
grep -q 'PendingGetError'           src/drv_fpc/fpc9201.cpp  || echo "DISCONNECT CRASH FIX MISSING"
```

The last check matters: a build can contain `VerifyFingerSelected` and still
show no prompt if the signal is emitted before the `VerifyStart` reply. Only a
live run of `scripts/test-dbus-signals.py` proves the ordering.

## Refreshing after upstream changes

If `install.sh` reports a patch cannot be applied, upstream has moved. Rebase
by hand, then regenerate:

```bash
cd /usr/local/src/fingerprint-ocv
git diff src/cvext.cpp > /path/to/patches/02-cvext-matching-robustness.patch
git -C asyncdbus diff  > /path/to/patches/01-asyncdbus-no-abort-on-spurious-wakeup.patch
```

Licence: AGPL-3.0, same as upstream.
