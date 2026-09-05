# Security Policy

## Cryptographic posture — read this first

**FIPS provider present; FIPS approved mode is NOT enforced for this image.**

This image ships the RHEL 9 OpenSSL FIPS provider exactly as delivered by its parent
image ubi9-base-micro (`openssl-fips-provider-so-3.0.7-8.el9`, module version 3.0.7-395c1a240fbfffd8,
CMVP certificate #4857, `fips.so` present and self-test-passing). The `org.nwarila.fips.*` module
labels describe that provider, not certification of this image.
The authoritative image label is `org.nwarila.fips.approved-mode=false`, and the child-owned
`/etc/nwarila/fips-status.json` says `"approved_mode":false`. This image's OpenSSL configuration
(`/etc/pki/tls/openssl-guacd.cnf`) activates the `fips`, `base`, `default` and `legacy` providers without
`default_properties = fips=yes`; `EVP_default_properties_is_fips_enabled()` returns 0.

Why: RDP licensing occurs after the MCS channels are joined, but a server may return
`STATUS_VALID_CLIENT` before a license request or platform challenge. The full licensing path can
require MD5 for key derivation and RC4 for platform challenges and license blobs. Those algorithms are not
available in approved mode. FreeRDP gets MD5 from OpenSSL's default provider and RC4 from its legacy
provider; neither is part of the validated module. The owner therefore discloses that this image is not
an approved-mode system.

What this means for you:
- Do not describe this image as FIPS-validated, FIPS-compliant, or as running in FIPS approved mode.
  Products are not FIPS validated; cryptographic modules are, and this image does not restrict itself
  to the validated one.
- Algorithms implemented by the FIPS provider are preferred from it (`default_properties = ?fips=yes`).
  MD5, RC4, and MD4 are supplied by non-validated default/legacy providers on request. WinPR uses
  provider MD4 for NTLM/NLA.
- Set `security=tls` on every connection. It removes NLA/NTLM from the wire but not licensing RC4/MD5.
  This is a per-connection Guacamole parameter; the image cannot enforce it. NLA is unsupported, but if
  selected it uses MD4 from the legacy provider.
- TLS parameters come from the embedded RHEL 9 DEFAULT crypto-policy: TLS 1.2 or 1.3; no RC4, MD5,
  DES/3DES, NULL, anonymous, RC2, IDEA, SEED, CAMELLIA, ARIA or CCM8 cipher suites; ECDHE/DHE/RSA key
  exchange; SHA-2 signatures. FreeRDP requests a TLS 1.0 floor and lowers the security level from 2 to 1;
  OpenSSL 3.5.5 security-level behavior rejects TLS 1.0/1.1. Level 1 permits 1024-bit RSA server
  certificates but re-enables no excluded cipher suite.
- The arm64 image is outside CMVP #4857's validated operational environment even for the parent image;
  on arm64 the provider is present and self-tests, nothing more.
- Server identity depends on the connection's certificate settings: use CA-signed certificates or
  `cert-fingerprints`; `cert-tofu` re-trusts after every restart because FreeRDP's state directory is
  ephemeral in this image; `ignore-cert` disables verification.
```

## Honest limitations

The Path B section above replaces item 2 in full. The remaining items preserve the platform wording.

1. **No regulation requires any of this.** OMB M-26-05 rescinded M-22-18 and M-23-16; the secure-software attestation form is discretionary. No attestation or conformity obligation applies to this repository today; a commercial integrator inherits its own.
3. **Not STIG-compliant. STIG-evaluated.** The DISA RHEL 9 STIG is a host GPOS profile; a standalone container is not accredited and its certificate to field does not apply (DISA CHPG). We publish the raw ARF and machine-generated pass/fail/notapplicable/notchecked counts. Read the counts, not an adjective.
4. **The signature proves this image was produced by this workflow in this repository. It does not prove any human reviewed the change.** This is a single-maintainer project with no two-party control; anyone holding the maintainer's credentials produces artifacts indistinguishable from legitimate ones.
5. **A valid signature is not freshness.** An image published in March verifies identically in the following March. Pin a digest that `:build-N` names, and check the fleet status page before treating `:latest` as current.
6. **The image is published with known unfixed vulnerabilities and always will be.** Vendor-unfixed CVEs cannot be gated on without stopping the nightly. The Security tab shows Red Hat's actionable set (`will_not_fix`/`end_of_life`/`fix_deferred` suppressed); `trivy image <digest>` reproduces the unfiltered view in one command.
7. **"Nightly" means rebuilt nightly, republished when the package set, the source revision, or the base image changes.** Green nights with no new digest are normal and expected.
8. **"Zero human maintenance" holds in steady state only.** A pipeline change fans out as one human-gated pull request per image repo, because the reusable workflow is SHA-pinned and bot PRs are never auto-merged.
9. **We do not claim reproducible builds.** We set `SOURCE_DATE_EPOCH` for legible diffs; no independent rebuilder verifies our output.
10. **We do not claim a SLSA level.** We publish SLSA v1.0 provenance.

## Network and runtime boundary

guacd TCP 4822 is unauthenticated by design, and the Guacamole handshake carries the RDP username
and password in cleartext. Permit ingress only from the Guacamole web application. Run with a
read-only root filesystem and an ephemeral, per-replica 64 MiB tmpfs or `emptyDir` at
`/home/nonroot`. Use an ephemeral debug container (`kubectl debug --image=...`); no debug image is
published.

Set `security=tls` on every connection. Use server identity controls in this order: CA-signed
certificate, `cert-fingerprints`, `cert-tofu`, and only then `ignore-cert`. Printing is unsupported
because Ghostscript is absent. NLA, NLA-EXT, and `security=any` against NLA-only servers are
unsupported. Drive redirection requires an operator-mounted writable `drive-path`.

## Vulnerability coverage

Distro scanning covers all 90 shipped RPM identities. `guacamole-server` has no usable distro
advisory namespace; monitor the Apache Guacamole security page and the NVD
`cpe:2.3:a:apache:guacamole` record as an explicit operational obligation.
