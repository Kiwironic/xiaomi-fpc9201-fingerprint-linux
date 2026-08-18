#!/usr/bin/env python3
"""Check the driver emits VerifyFingerSelected *and* emits it late enough.

Why this exists: the upstream driver DECLARED VerifyFingerSelected in its
interface but never emitted it. pam_fprintd uses that signal to produce the PAM
message "Place your finger on <device>", which GNOME turns into the
"(or place finger on reader)" hint. Without it, verification still works but no
prompt ever appears - the reader looks dead.

ORDERING MATTERS AS MUCH AS EMISSION. pam_fprintd calls VerifyStart
asynchronously and sets its internal `verify_started` flag only in the
method-return callback. Its handler begins:

    if (!data->verify_started) { "Unexpected VerifyFingerSelected"; return 0; }

So a signal emitted BEFORE the method return is parsed, logged as unexpected and
discarded - no PAM message, no GNOME hint. An earlier version of our own fix had
exactly this bug: the signal was on the wire, this test reported PASS, and the
hint still never appeared. Hence the ordering assertion below.

IMPORTANT: this uses ONE D-Bus connection for Claim + VerifyStart. The driver
binds a claim to the caller's connection name, so testing with separate
`dbus-send` invocations always fails with "not claimed" and gives a false
negative. (That mistake cost real debugging time.)

Read-only: claims the device, starts a verify, listens, then stops and
releases. Does not read, modify or delete any enrolled template.

Usage:  sudo ./scripts/test-dbus-signals.py [username]
"""
import sys

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
except ImportError:
    sys.exit(
        "Missing Python D-Bus bindings. Install:\n"
        "  Fedora: sudo dnf install python3-dbus python3-gobject\n"
        "  Debian: sudo apt install python3-dbus python3-gi\n"
        "  Arch:   sudo pacman -S python-dbus python-gobject"
    )

BUS_NAME = "net.reactivated.Fprint"
DEV_PATH = "/net/reactivated/Device/0"
DEV_IFACE = "net.reactivated.Fprint.Device"

seen = []


def main() -> int:
    user = sys.argv[1] if len(sys.argv) > 1 else "root"

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    def on_signal(*args, **kwargs):
        member = kwargs.get("member")
        seen.append(f"signal:{member}")
        vals = [str(a) for a in args]
        print(f"  signal: {member} {vals}", flush=True)

    bus.add_signal_receiver(
        on_signal,
        dbus_interface=DEV_IFACE,
        path=DEV_PATH,
        member_keyword="member",
    )

    try:
        dev = bus.get_object(BUS_NAME, DEV_PATH)
    except dbus.DBusException as exc:
        print(f"Cannot reach {BUS_NAME} at {DEV_PATH}: {exc}")
        print("Is fprintd running?  systemctl status fprintd")
        return 2

    iface = dbus.Interface(dev, DEV_IFACE)

    print(f"Claim({user}) ...", flush=True)
    try:
        iface.Claim(user)
    except dbus.DBusException as exc:
        print(f"Claim failed: {exc}")
        print("Run this as root (sudo), and pass a user that has prints enrolled.")
        return 2

    print("VerifyStart('any') ... do NOT touch the sensor", flush=True)

    # Called asynchronously so we can record the method return in the same
    # ordered stream as the signals. pam_fprintd does the same thing, and only
    # accepts VerifyFingerSelected after this return has arrived.
    def on_verify_started():
        seen.append("method_return:VerifyStart")
        print("  method return: VerifyStart", flush=True)

    def on_verify_error(exc):
        seen.append("error")
        print(f"VerifyStart failed: {exc}")

    try:
        iface.VerifyStart(
            "any",
            reply_handler=on_verify_started,
            error_handler=on_verify_error,
        )
    except dbus.DBusException as exc:
        print(f"VerifyStart failed: {exc}")
        try:
            iface.Release()
        except dbus.DBusException:
            pass
        return 2

    loop = GLib.MainLoop()

    def finish():
        for method in ("VerifyStop", "Release"):
            try:
                getattr(iface, method)()
            except dbus.DBusException:
                pass
        loop.quit()
        return False

    GLib.timeout_add_seconds(3, finish)
    loop.run()

    print()
    if "signal:VerifyFingerSelected" not in seen:
        print("FAIL: VerifyFingerSelected was NOT emitted.")
        print(f"      order seen: {seen or '(none)'}")
        print()
        print("This means the daemon is an unpatched build. Verification may still")
        print("work if you touch the sensor blindly, but no prompt will ever appear.")
        print("Re-run install.sh to build with the fix.")
        return 1

    if "method_return:VerifyStart" not in seen:
        print("WARN: never saw the VerifyStart method return; cannot check order.")
        print(f"      order seen: {seen}")
        return 1

    sig_idx = seen.index("signal:VerifyFingerSelected")
    ret_idx = seen.index("method_return:VerifyStart")

    if sig_idx < ret_idx:
        print("FAIL: VerifyFingerSelected was emitted BEFORE the VerifyStart")
        print("      method return.")
        print(f"      order seen: {seen}")
        print()
        print("pam_fprintd sets verify_started only in the VerifyStart reply")
        print("callback and discards signals that arrive earlier, logging")
        print("'Unexpected VerifyFingerSelected'. The signal is on the bus but")
        print("no PAM message and no GNOME hint will be produced.")
        print("Check for it with:")
        print("  journalctl -b | grep 'Unexpected VerifyFingerSelected'")
        return 1

    print("PASS: VerifyFingerSelected emitted AFTER the VerifyStart method")
    print("      return - pam_fprintd will accept it and show a prompt.")
    print(f"      order seen: {seen}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
