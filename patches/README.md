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

Patches `02`–`06` apply at the repo root. Patches `00` and `01` target
submodules and **must** be applied from inside the submodule directory — a
single top-level `git apply patches/*.patch` fails with
`No such file or directory` on those paths.

```bash
cd /usr/local/src/fingerprint-ocv
P=/path/to/this/repo/patches

git apply "$P"/0{2,3,4,5,6}-*.patch
git -C asyncdbus apply "$P"/01-*.patch
git -C jinx      apply "$P"/00-*.patch
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
