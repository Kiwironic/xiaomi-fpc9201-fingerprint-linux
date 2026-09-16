# Packaging

Packages for the patched [Kiwironic/fingerprint-ocv](https://github.com/Kiwironic/fingerprint-ocv)
fork — tagged releases there carry a complete source tarball
(`fingerprint-ocv-<ver>-src.tar.gz`, submodules included; GitHub's
auto-generated archives do not).

Both packages install:

- `/usr/libexec/fingerpp` (RPM) / `/usr/lib/fingerpp` (AUR) — the daemon
- `99-fpc9201.rules` — udev `uaccess` rule for `10a5:9201`
- `fprintd.service.d/fingerpp.conf` — systemd drop-in replacing stock fprintd's
  `ExecStart` (the daemon claims the same `net.reactivated.Fprint` bus name)

Installing the package replaces the need for `install.sh` — but NOT the PAM
step (`authselect enable-feature with-fingerprint` / `pam-auth-update`), which
no package should do automatically.

## Fedora — COPR

One-time setup:

```bash
# 1. Create a Fedora account: https://accounts.fedoraproject.org
# 2. Log in once at https://copr.fedorainfracloud.org (creates the COPR account)
# 3. Copy the API token from https://copr.fedorainfracloud.org/api/ into ~/.config/copr
sudo dnf install copr-cli rpm-build
```

Build + publish:

```bash
copr-cli create fingerprint-ocv-fpc9201 \
  --chroot fedora-44-x86_64 --chroot fedora-43-x86_64 \
  --description "Fingerprint driver for FPC/Chipsailing 10a5:9201 (Xiaomi Book Pro 14 2022)" \
  --instructions "sudo dnf install fingerprint-ocv-fpc9201, then: sudo fprintd-enroll \$USER -f right-index-finger"

# build the SRPM locally, then submit
cd packaging/rpm
spectool -g -R fingerprint-ocv-fpc9201.spec        # fetches Source0
rpmbuild -bs fingerprint-ocv-fpc9201.spec \
  --define "_sourcedir $PWD" --define "_srcrpmdir $PWD"
copr-cli build fingerprint-ocv-fpc9201 ./fingerprint-ocv-fpc9201-*.src.rpm
```

Users then install with:

```bash
sudo dnf copr enable <your-copr-user>/fingerprint-ocv-fpc9201
sudo dnf install fingerprint-ocv-fpc9201
```

Note: an OpenCV soname bump breaks the binary. COPR rebuilds are manual —
`copr-cli build` again after the opencv update lands, bumping `Release:`.

## Arch — AUR

One-time setup:

```bash
# 1. Create an account: https://aur.archlinux.org/register
# 2. Generate an SSH key and paste the PUBLIC key into the AUR account profile
ssh-keygen -t ed25519 -C "aur" -f ~/.ssh/aur
# 3. ~/.ssh/config:
#    Host aur.archlinux.org
#      IdentityFile ~/.ssh/aur
#      User aur
```

Publish (this is the AUR `fingerprint-ocv-fpc9201` package repo — NOT GitHub):

```bash
git clone ssh://aur@aur.archlinux.org/fingerprint-ocv-fpc9201.git
cd fingerprint-ocv-fpc9201
cp /path/to/repo/packaging/aur/{PKGBUILD,.SRCINFO,99-fpc9201.rules,fingerpp.conf,fingerprint-ocv-fpc9201.install} .
git add -A && git commit -m "Initial upload: fingerprint-ocv-fpc9201 1.0.0"
git push
```

`.SRCINFO` is committed alongside `PKGBUILD` — regenerate it on any Arch
machine with `makepkg --printsrcinfo > .SRCINFO` when the PKGBUILD changes.

Users then install with `yay -S fingerprint-ocv-fpc9201` or
`makepkg -si` from the AUR repo.

## Bumping the version

1. Rebase/merge upstream into `Kiwironic/fingerprint-ocv` master, keep the
   patch commits; bump the `patched` branches of `Kiwironic/jinx` and
   `Kiwironic/asyncdbus` if their pinned commits change.
2. Tag `v<X.Y.Z>` on master, push the tag.
3. Rebuild the dist tarball (submodules included — see below) and attach it
   to a new GitHub release.
4. Bump `Version:`/`pkgver`, refresh `sha256sums`, update `Release:`/`pkgrel`.

Regenerating the dist tarball:

```bash
cd /path/to/fingerprint-ocv
git archive --format=tar --prefix=fingerprint-ocv-X.Y.Z/ -o /tmp/base.tar HEAD
for s in asyncdbus asyncusb jinx; do
  git -C $s archive --format=tar --prefix=fingerprint-ocv-X.Y.Z/$s/ -o /tmp/$s.tar HEAD
  tar -Af /tmp/base.tar /tmp/$s.tar
done
gzip -c /tmp/base.tar > fingerprint-ocv-X.Y.Z-src.tar.gz
gh release create vX.Y.Z fingerprint-ocv-X.Y.Z-src.tar.gz --repo Kiwironic/fingerprint-ocv
```
