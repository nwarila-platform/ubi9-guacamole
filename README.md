# ubi9-guacamole

This repository builds hardened Apache Guacamole `guacd` 1.6.0.
The runtime enables only the RDP protocol plugin.
It listens on TCP 4822 as UID/GID 65532 with no shell or package manager.

## Cryptographic posture

This is Path B: the RHEL FIPS provider is present, but approved mode is not enforced.
RDP licensing can require RC4 and MD5 from the default and legacy providers.
Every connection must set `security=tls`; read [SECURITY.md](SECURITY.md).

## Publication

Pushes to `main` and manual dispatches build Linux amd64 and push to GHCR.
The workflow publishes `:latest` and a short-SHA tag, smoke-tests `guacd -v`, then keyless-signs the digest with Cosign.
The runtime parent is pinned to `ghcr.io/nwarila/ubi9-base-micro`.
Its digest is `sha256:215c082aa0718d2ee45caa17ae08dc6127685f1b83f3a2d0993e271ca4debbda`.
Assembler and CentOS Stream builder inputs are also digest-pinned in [BUILD-ARGS.md](BUILD-ARGS.md).
No gate suite, test harness, SLSA generator, or attestation workflow is included.
