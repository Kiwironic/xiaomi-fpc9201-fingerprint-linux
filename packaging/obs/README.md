# openSUSE Build Service (OBS)

One OBS project can build this driver for Fedora, openSUSE, Debian, Ubuntu
and Arch at the same time, hosted on openSUSE's infrastructure.

## 1. Create the account

1. Go to <https://build.opensuse.org> and click **Sign Up** (top right).
   This creates an openSUSE account — one account covers OBS and all
   openSUSE services.
2. Log in at <https://build.opensuse.org>. The first login offers to create
   your home project (`home:<username>`) — accept it.

## 2. Create the package

In the web UI, inside `home:<username>`:

1. **Create Package** → name `fingerprint-ocv-fpc9201`.
2. Upload these sources (OBS takes each file individually):
   - `fingerprint-ocv-1.0.0-src.tar.gz` — the release asset from
     <https://github.com/Kiwironic/fingerprint-ocv/releases/tag/v1.0.0>
   - `../rpm/fingerprint-ocv-fpc9201.spec` — for Fedora/openSUSE targets
     (it already switches BuildRequires on `%suse_version`)
   - the `../debian/` files, renamed to OBS's Debian convention:
     `control` → `debian.control`, `changelog` → `debian.changelog`,
     `rules` → `debian.rules`, `copyright` → `debian.copyright`,
     `postinst` → `debian.postinst`, `postrm` → `debian.postrm`,
     plus `99-fpc9201.rules` and `fingerpp.conf` as-is
3. In the project **Repositories** tab, enable build targets:
   `Fedora_44`, `openSUSE_Tumbleweed`, `Debian_12`, `xUbuntu_24.04`,
   and `Arch` (uses `../aur/PKGBUILD` — upload it too).

OBS builds each target automatically and publishes a per-distro repo at
`https://download.opensuse.org/repositories/home:<username>/` that users
can add directly — no COPR/AUR account needed on their side.

## 3. Updating

`osc` (the OBS CLI) manages checkouts if the web UI gets tedious:

```bash
osc -A https://api.opensuse.org checkout home:<username>/fingerprint-ocv-fpc9201
```

Bump the version by uploading the new release tarball and bumping
`Version:` in the spec / `pkgver` in the PKGBUILD / the debian changelog.
