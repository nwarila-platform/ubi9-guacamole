# Scriptlet classification

The exact tags and bodies are captured from the pinned RPMs in the freeze contract. The only
non-empty package set is exactly:

`bash fontconfig freetype glib2 krb5-libs libblkid p11-kit-trust systemd-libs xml-common`

## bash

The Lua postinstall/postuninstall updates `/etc/shells`. Not required: bash is erased and parent
remnants are restored.

## fontconfig

Cache and XML-catalog scriptlets are not required by the RDP-only runtime; helper programs are
trimmed.

## freetype

The `< 2.0.5-3` upgrade trigger is unreachable on a fresh installation.

## glib2

GIO-module and schema cache file triggers are not required; no module/schema payload requiring a
generated cache ships, and both helpers are trimmed.

## krb5-libs

The `< 1.15.1-5` upgrade trigger is unreachable on a fresh installation.

## libblkid

The legacy `/etc/blkid.tab*` migration has no input in the parent and is a no-op.

## p11-kit-trust

The NSS-only alternatives symlink is not used; alternatives is erased and GnuTLS uses the module
declaration directly.

## systemd-libs

The parent `/etc/nsswitch.conf` is retained. The runtime consumes `libsystemd.so.0` only.

## xml-common

The upgrade-only catalog scriptlet is unreachable on a fresh installation.

## glibc

The suppressed parent file trigger is replicated by an explicit `ldconfig -r /rootfs`.
