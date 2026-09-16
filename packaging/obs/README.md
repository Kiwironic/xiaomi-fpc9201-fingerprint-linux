# openSUSE Build Service (OBS)

One OBS project builds this driver for Fedora, openSUSE, Debian, Ubuntu
and Arch at the same time, hosted on openSUSE's infrastructure.

## 1. Create the package

Your **home project** (`home:Kiwironic`) IS the project — do not create a
separate one. Inside it: **Packages** → **Create Package**.

The form fields:

| Field | Value |
|-------|-------|
| Name | `fingerprint-ocv-fpc9201` |
| Title | optional, e.g. `Fingerprint driver for FPC 10a5:9201` |
| SCM Sync URL | **leave blank** (manual uploads, not git sync) |
| Description | optional one-liner |
| Disable build results publishing | **leave unchecked** — publishing is what produces the downloadable repo |

## 2. Upload the source files

In the new package, **Add File** / **Upload File** for each of:

| Upload as | What it is |
|-----------|------------|
| `fingerprint-ocv-1.0.0-src.tar.gz` | the release asset from <https://github.com/Kiwironic/fingerprint-ocv/releases/tag/v1.0.0> — used by the RPM and Arch builds (name must match the spec's `Source0` basename) |
| `fingerprint-ocv-fpc9201_1.0.0.orig.tar.gz` | **a second copy of the same tarball, renamed** — Debian builds require the `<pkg>_<version>.orig.tar.gz` name |
| `fingerprint-ocv-fpc9201.spec` | from `packaging/rpm/` — Fedora + openSUSE |
| `debian.control` | `packaging/debian/control`, renamed |
| `debian.changelog` | `packaging/debian/changelog`, renamed |
| `debian.rules` | `packaging/debian/rules`, renamed — **make it executable** (chmod +x; the upload form has a checkbox, or OBS treats it by content) |
| `debian.copyright` | `packaging/debian/copyright`, renamed |
| `debian.postinst` | `packaging/debian/postinst`, renamed |
| `debian.postrm` | `packaging/debian/postrm`, renamed |
| `99-fpc9201.rules` | `packaging/debian/99-fpc9201.rules` |
| `fingerpp.conf` | `packaging/debian/fingerpp.conf` |
| `PKGBUILD` | **`packaging/obs/PKGBUILD`** — the OBS variant (local source tarball; OBS builds have no network, so the AUR PKGBUILD's remote URL will not work) |
| `fingerprint-ocv-fpc9201.install` | `packaging/aur/fingerprint-ocv-fpc9201.install` — referenced by the PKGBUILD's `install=` |

## 3. Enable build targets

Project page → **Repositories** → **Add from a Distribution**, enable:

- `Fedora_44` (and `Fedora_43`)
- `openSUSE_Tumbleweed`
- `Debian_12`
- `xUbuntu_24.04`
- `Arch` / `Arch_Extra` if listed

OBS builds each target automatically and publishes a per-distro repo at
`https://download.opensuse.org/repositories/home:Kiwironic/` that users
add directly — including a **pacman repo for Arch**, which works around
the closed AUR registration.

## 4. Disambiguate dependencies (one-time, expected)

The first build round will report **unresolvable** on most targets with
`have choice for ...` errors — OBS refuses to guess between equivalent
providers. Fix once in **Project Config** (project page → Advanced →
Project Config), append:

```
Prefer: hdf-libs pipewire-jack-audio-connection-kit-libs
Prefer: libavcodec59 libavformat59 libjpeg62-turbo-dev
Prefer: libavcodec60 libavformat60
Prefer: blas-openblas
```

Save → the unresolvable targets re-schedule themselves.

Optional: remove non-x86_64 architectures (Repositories → each repo's
arch list) — this sensor only ships in x86_64 laptops, and the extra
i586/aarch64 builds just burn build time.

## 5. If a target still fails

The **Monitor** page shows per-target status. Known issues:

- `directories not owned by a package: /usr/lib/systemd/system/fprintd.service.d`
  — fixed in spec release 1.0.0-2; re-upload the spec
- Debian target: `debian.rules` executable bit lost in web upload —
  use `osc` to set it (below)
- `unresolvable` that does NOT say `have choice` — a dep name differs
  per distro; check the target's log details

## 6. Add more distro coverage

Same **Repositories → Add from a Distribution** step supports more
targets — worth adding: `xUbuntu_25.04`, `Debian_13` (trixie),
`Fedora_Rawhide`, `Arch_Core`. (Ubuntu 24.04 was chosen first as the
current LTS; others are one tick-box each.)

## 5. Updating

Bump the version by uploading the new release tarball (plus a renamed
`.orig.tar.gz` copy), bumping `Version:` in the spec, `pkgver` in the
PKGBUILD, and adding a `debian.changelog` entry.

`osc` (the OBS CLI) manages checkouts if the web UI gets tedious:

```bash
osc -A https://api.opensuse.org checkout home:Kiwironic/fingerprint-ocv-fpc9201
```
