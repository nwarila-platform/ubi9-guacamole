# LTO off so annocheck's fortify test is verifiable from the annobin notes (LTO discards the
# preprocessor record annocheck reads); the hardening flags themselves come from %%build_cflags.
%global _lto_cflags %{nil}
%undefine _package_note_file

Name:           guacamole-server
Version:        1.6.0
Release:        1%{?dist}
Summary:        Apache Guacamole proxy daemon (guacd) with the RDP protocol plugin only
License:        Apache-2.0
URL:            https://guacamole.apache.org/
Vendor:         nwarila-platform
Packager:       nwarila-platform <https://github.com/nwarila-platform/ubi9-guacamole>
Source0:        guacamole-server-%{version}.tar.gz
# GUACAMOLE-2070 (upstream commit 2e2a33621d673345e7b9d22c9388be80c6d77598, merged 2025-05-23,
# not in the 1.6.0 tarball): inet_pton(AF_INET6) wrote 16 bytes into the 4-byte sin_addr of a
# struct sockaddr_in in libguac/wol.c; glibc's _FORTIFY_SOURCE inet_pton check rejects the call
# at compile time under -Werror, so the fix is required to build with the default hardening flags.
Patch0:         guacamole-server-2e2a33621d673345e7b9d22c9388be80c6d77598-wol-sockaddr.patch

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pkgconf-pkg-config
BuildRequires:  patch
BuildRequires:  freerdp-devel = 2:2.11.7-12.el9
BuildRequires:  libwinpr-devel = 2:2.11.7-12.el9
BuildRequires:  cairo-devel
BuildRequires:  libjpeg-turbo-devel
BuildRequires:  libpng-devel
BuildRequires:  libuuid-devel
BuildRequires:  openssl-devel

%description
guacd, libguac, and libguac-client-rdp from the Apache Guacamole 1.6.0 release tarball,
configured for RDP only: no VNC, SSH, Telnet, Kubernetes, terminal, guacenc, guaclog, WebP,
Vorbis, PulseAudio, WebSockets, or FFmpeg support. Built as a scriptlet-free package for a
shell-less runtime.

%prep
%autosetup -p1 -n guacamole-server-%{version}

%build
# The tarball ships a generated configure (GNU Autoconf 2.72); autoreconf is never run.
%configure \
  --enable-option-checking=fatal \
  --disable-silent-rules \
  --enable-shared \
  --disable-static \
  --enable-guacd \
  --disable-guacenc \
  --disable-guaclog \
  --disable-kubernetes \
  --with-rdp \
  --with-freerdp-plugin-dir=%{_libdir}/freerdp2 \
  --with-guacd-conf=%{_sysconfdir}/guacamole/guacd.conf \
  --with-libuuid \
  --with-ssl \
  --without-vnc \
  --without-ssh \
  --without-telnet \
  --without-pango \
  --without-terminal \
  --without-websockets \
  --without-libavcodec \
  --without-libavformat \
  --without-libavutil \
  --without-libswscale \
  --without-pulse \
  --without-vorbis \
  --without-webp \
  --without-winsock
%make_build

%install
%make_install
# No libtool archives, no development headers, no unversioned libguac dev symlink.
# libguac-client-rdp.so (unversioned) MUST stay: guacd dlopen()s "libguac-client-rdp.so".
find %{buildroot} -name '*.la' -delete
rm -rf %{buildroot}%{_includedir}/guacamole
rm -f %{buildroot}%{_libdir}/libguac.so

%files
%license LICENSE
%{_sbindir}/guacd
%{_libdir}/libguac.so.25
%{_libdir}/libguac.so.25.0.0
%{_libdir}/libguac-client-rdp.so
%{_libdir}/libguac-client-rdp.so.0
%{_libdir}/libguac-client-rdp.so.0.0.0
%{_libdir}/freerdp2/libguac-common-svc-client.so
%{_libdir}/freerdp2/libguacai-client.so
%{_mandir}/man8/guacd.8*
%{_mandir}/man5/guacd.conf.5*

%changelog
* Sat Sep 05 2026 nwarila-platform - 1.6.0-1
- RDP-only build of the Apache Guacamole 1.6.0 release tarball with GUACAMOLE-2070 applied
