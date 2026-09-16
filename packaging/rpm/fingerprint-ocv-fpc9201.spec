Name:           fingerprint-ocv-fpc9201
Version:        1.0.0
Release:        1%{?dist}
Summary:        Fingerprint driver for the FPC/Chipsailing 10a5:9201 sensor

License:        AGPL-3.0-only
URL:            https://github.com/Kiwironic/fingerprint-ocv
Source0:        %{url}/releases/download/v%{version}/fingerprint-ocv-%{version}-src.tar.gz

BuildRequires:  cmake gcc-c++ make pkgconf-pkg-config
BuildRequires:  libusb1-devel libevent-devel dbus-devel openssl-devel opencv-devel
Requires:       fprintd polkit

%description
Patched build of vrolife/fingerprint-ocv for the FPC/Chipsailing 10a5:9201
fingerprint sensor (Xiaomi Book Pro 14 2022 and relatives).

Installs the daemon as a drop-in replacement for the fprintd service, so
GNOME/KDE login and pam_fprintd (sudo, polkit) work with no further
configuration. Enrollment data is stored in /var/lib/fprint.

%prep
%autosetup -n fingerprint-ocv-%{version}

%build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j%{?_smp_mflags}

%install
install -Dm755 build/src/fingerprint-ocv %{buildroot}%{_libexecdir}/fingerpp

mkdir -p %{buildroot}/usr/lib/udev/rules.d
cat > %{buildroot}/usr/lib/udev/rules.d/99-fpc9201.rules <<'EOF'
# FPC/Chipsailing 10a5:9201 fingerprint sensor
SUBSYSTEM=="usb", ATTRS{idVendor}=="10a5", ATTRS{idProduct}=="9201", TAG+="uaccess"
EOF

mkdir -p %{buildroot}%{_unitdir}/fprintd.service.d
cat > %{buildroot}%{_unitdir}/fprintd.service.d/fingerpp.conf <<'EOF'
# Replaces stock fprintd with the fingerprint-ocv daemon, which claims the
# same D-Bus name (net.reactivated.Fprint) and so works with PAM/GNOME.
[Service]
ExecStart=
ExecStart=%{_libexecdir}/fingerpp --bus=system --min-score=0.30 --min-area=150000
Restart=on-failure
RestartSec=1s
EOF

%post
udevadm control --reload-rules || :
udevadm trigger --subsystem-match=usb --attr-match=idVendor=10a5 || :
systemctl daemon-reload || :
systemctl try-restart fprintd.service || :

%postun
udevadm control --reload-rules || :
systemctl daemon-reload || :
systemctl try-restart fprintd.service || :

%files
%license LICENSE
%doc README.md
%{_libexecdir}/fingerpp
/usr/lib/udev/rules.d/99-fpc9201.rules
%{_unitdir}/fprintd.service.d/fingerpp.conf

%changelog
* Wed Sep 16 2026 Kiwironic <menabassily@hotmail.com> - 1.0.0-1
- Initial package: vrolife/fingerprint-ocv plus crash, security and
  correctness fixes for the 10a5:9201 sensor
