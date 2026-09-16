# Fingerprint reader support for FPC/Chipsailing `10a5:9201` on Linux

Makes the fingerprint reader in the **Xiaomi Book Pro 14 2022** (and relatives)
work on Linux — log in and run `sudo` with your fingerprint.

`libfprint` doesn't support this sensor, so on a stock install the reader is
dead: no enrollment, no login, nothing in Settings. This repo ships
[fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv) — the userspace
driver that reverse-engineered the sensor — with a set of crash, security and
correctness fixes on top, installed as a drop-in replacement for the normal
fingerprint service.

## Is this your sensor?

```bash
lsusb | grep 10a5:9201
```

```
Bus 003 Device 003: ID 10a5:9201 FPC FPC Sensor Controller L:0001 FW:021.26.2.031
```

Confirmed working:

| Laptop | Where tested |
|--------|--------------|
| Xiaomi Book Pro 14 (2022) | development machine, Fedora 44 |
| RedmiBook Pro 15 (2022) | reported on Garuda/Arch with KDE ([#1](https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux/issues/1#issuecomment-5674549013)) |

Any laptop whose reader reports `10a5:9201` should work — please
[report your result](#reporting-a-result). Sensors that aren't this one
(Goodix, Synaptics `06cb:`, Validity `138a:`, other FPC parts) are unrelated to
this driver.

## Install

### Packages

Packages are built from the tagged releases of
[Kiwironic/fingerprint-ocv](https://github.com/Kiwironic/fingerprint-ocv)
(the patched fork). Most distros are served by the
[OBS project](https://build.opensuse.org/package/show/home:Kiwironic/fingerprint-ocv-fpc9201),
which publishes a native repo per distro.

**Fedora** — COPR (recommended):

```bash
sudo dnf copr enable kiwir0nic/fingerprint-ocv-fpc9201
sudo dnf install fingerprint-ocv-fpc9201
```

Or the OBS repo instead (swap `Fedora_44` for `Fedora_43` as needed):

```bash
sudo dnf config-manager --add-repo https://download.opensuse.org/repositories/home:Kiwironic/Fedora_44/home:Kiwironic.repo
sudo dnf install fingerprint-ocv-fpc9201
```

**Debian / Ubuntu** — replace `Debian_12` below with your release directory:
`Debian_13`, `xUbuntu_24.04`, `xUbuntu_24.10`, `xUbuntu_25.04`,
`xUbuntu_25.10` or `xUbuntu_26.04`.

```bash
echo 'deb http://download.opensuse.org/repositories/home:/Kiwironic/Debian_12/ /' \
    | sudo tee /etc/apt/sources.list.d/fpc9201.list
curl -fsSL https://download.opensuse.org/repositories/home:Kiwironic/Debian_12/Release.key \
    | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/fpc9201.gpg > /dev/null
sudo apt update && sudo apt install fingerprint-ocv-fpc9201
```

Standalone `.deb` files are also attached to the
[v1.0.0 release](https://github.com/Kiwironic/fingerprint-ocv/releases/tag/v1.0.0)
for a one-off install without the repo.

**Arch** — add the OBS pacman repo to `/etc/pacman.conf`:

```ini
[home_Kiwironic_Arch]
SigLevel = Never
Server = https://download.opensuse.org/repositories/home:Kiwironic/Arch/$arch
```

```bash
sudo pacman -Sy fingerprint-ocv-fpc9201
```

`SigLevel = Never` skips pacman's signature check — the repo is signed with the
OBS project's own key, which isn't in the pacman keyring. An AUR package is also
prepared in `packaging/aur/` for when AUR registration reopens.

**openSUSE Tumbleweed**:

```bash
sudo zypper addrepo https://download.opensuse.org/repositories/home:Kiwironic/openSUSE_Tumbleweed/home:Kiwironic.repo
sudo zypper refresh && sudo zypper install fingerprint-ocv-fpc9201
```

After installing, enroll with `fprintd-enroll`, then **log out and back in** —
GNOME only picks up the driver in a fresh session.

### From source

```bash
git clone https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux.git
cd xiaomi-fpc9201-fingerprint-linux
sudo ./install.sh
./scripts/enroll.sh
```

Then log out and back in.

Enrollment asks for a lot of presses — 20 to 40 is normal. Rotate and shift
your finger a little each time; coverage is what makes matching reliable later.
Wait for `enroll: completed` before stopping.

The repo also ships two helper scripts:

```bash
sudo ./scripts/verify-install.sh   # 19 read-only checks, changes nothing
sudo ./uninstall.sh                # keeps enrolled fingerprints
sudo ./uninstall.sh --purge-prints
```

## Everyday use

```bash
./scripts/enroll.sh [finger]      # enroll another finger (from a repo clone)
sudo fprintd-list "$USER"         # list enrolled fingers
sudo fprintd-verify "$USER"       # test a press
sudo journalctl -u fprintd -f     # watch the sensor live
```

Enrolling or deleting prints without `sudo` asks polkit to confirm it's you
first, the same way stock fprintd does — you get a password dialog before any
scan starts. If enroll fails with `PermissionDenied` and no dialog appears,
your session's polkit agent is probably wedged; `pkexec id` is a quick check.

Useful log lines while enrolling or verifying:

```
enroll: progress=0.68 area=102072/150000     coverage growing, keep going
enroll: merge failed (reposition finger)     press not alignable, shift slightly
enroll: completed                            saved
match: score=0.846 min_score=0.3 overlap=39659/39424    healthy match
```

## Tuning

Only if you need it — pass these when installing, e.g.
`sudo MIN_AREA=180000 ./install.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `MIN_AREA` | `150000` | How much of your finger must be captured before enrollment finishes. Raise it for more reliable recognition, at the cost of more presses. |
| `MIN_SCORE` | `0.30` | Match threshold. Prefer raising `MIN_AREA` first — lowering this weakens security. |

## Troubleshooting

`sudo ./scripts/verify-install.sh` identifies most problems.

**Service won't start** — check `journalctl -u fprintd -n 40`.
`libopencv_*.so: cannot open shared object file` means OpenCV was upgraded;
reinstall the package or re-run `install.sh` to rebuild.

**Nothing enrolled** — `NoEnrolledPrints` is expected, not a fault.

**Verification always fails** — look at the numbers:

```bash
sudo journalctl -u fprintd --since '-5min' | grep 'match:'
```

No `match:` lines means the press couldn't be aligned to your template; a low
`score` means a poor one. Either way, re-enroll that finger with more varied
coverage. One weak finger shows up as intermittent failures even when the
others match fine, because verification tries all enrolled fingers.

**No prompt, but auth works if you touch the sensor blindly:**

```bash
journalctl -b | grep 'Unexpected VerifyFingerSelected'
```

Output means you're running a build without the prompt fix — reinstall the
current package.

**Reader not detected at all** — `lsusb` prints nothing.

- Check the fingerprint reader is enabled in BIOS/UEFI — a disabled reader
  looks identical to a broken one.
- If it drops in and out, USB autosuspend may be the cause:

  ```bash
  echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="10a5", ATTR{idProduct}=="9201", ATTR{power/control}="on"' \
      | sudo tee /etc/udev/rules.d/99-fpc9201-nosuspend.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger
  ```

**Enrollment stalls or ignores presses**

- A leftover enroller may be holding the sensor:
  `pgrep -af 'fprintd-(enroll|verify)'`.
- Don't pipe enrollment through `tail`/`head` or wrap it in `timeout` — use
  `./scripts/enroll.sh`.
- Clean the sensor and your fingertip.

**Don't run a second copy of the daemon** while the service is active — both
fight over the USB device and the running one aborts. The service restarts
itself; to test a rebuilt binary, install it and restart the service instead.

## Limitations

- An OpenCV upgrade breaks the binary via a soname change — reinstall the
  package or re-run `install.sh`.
- Matching is image-based, which is inherently weaker than a match-on-chip
  sensor. Fine for convenience; think twice before relying on it for anything
  sensitive.
- Templates are encrypted, but the key is derived in the driver — it's not
  tied to a TPM.
- Non-root enroll/delete needs a polkit agent in the session to answer the
  prompt (over plain SSH there isn't one — use `sudo`).
- Two D-Bus gaps vs stock fprintd remain: no `PropertiesChanged` (doesn't
  affect GNOME) and no `ObjectManager`.

## Reporting a result

Test reports from other distros and laptop models are the most useful
contribution right now. Whatever the outcome, please include:

```bash
lsusb -d 10a5:9201
head -2 /etc/os-release
pkg-config --modversion opencv4 || pkg-config --modversion opencv5
sudo ./scripts/verify-install.sh
sudo journalctl -u fprintd --since '-10min' | grep -E 'enroll:|match:'
```

plus your laptop model, and whether login, `sudo` and the on-screen prompt
each worked. If the reader isn't detected at all, check it's enabled in
BIOS/UEFI before filing — that accounts for a fair share of "dead sensor"
reports.

## Credits

All driver credit belongs to **[vrolife](https://github.com/vrolife)**, who
reverse-engineered this sensor's encrypted USB protocol from scratch and built
the matching pipeline in
[fingerprint-ocv](https://github.com/vrolife/fingerprint-ocv). This project
fixes bugs on top and packages the result — the fixes have been submitted
upstream as pull requests, and the goal is for this repo to become a thin
installer once they land.

For the detailed bug write-ups, internals and contributor notes, see
[docs/technical-notes.md](docs/technical-notes.md) and
[patches/README.md](patches/README.md).

Everything here is **AGPL-3.0**, matching the upstream driver. See `LICENSE`.
