# SLSA L3 Provenance Verification

The inherited publish implementation is retained in
`.github/workflows/publish-image.yaml`, but its publishing path is disabled
pending replacement by the redesigned pipeline. The workflow accepts only
manual dispatches, which run the tag-integrity job; the publish job remains
ineligible because it requires a `push` event. When operational, the retained
implementation uses the SLSA container generator reusable workflow to write a
cosign OCI attestation for the pushed image digest.

## Trusted Generator

| Field | Value |
| --- | --- |
| Generator workflow | `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml` |
| Generator tag | `v2.1.0` |
| Audited tag target | `f7dd8c54c2067bafc12ca7a55595d5ee9b75204a` |
| Certificate identity / builder ID | `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |

The workflow reference is tag-pinned because the upstream generator resolves its
builder binary from a semantic-version tag. In the workflow's current disabled
state, a manual dispatch runs the tag-integrity guard and fails if
`refs/tags/v2.1.0` no longer resolves to the audited commit above. Pull requests
and pushes do not trigger this workflow.

## Verify Contract

Run both commands against the digest reference that was published:

```sh
cosign verify-attestation --type slsaprovenance <image>@<digest> \
  --certificate-identity https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

```sh
slsa-verifier verify-image <image>@<digest> \
  --source-uri github.com/NWarila/ubi9-application-template \
  --builder-id https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0
```

`gh attestation verify` is intentionally excluded: it verifies GitHub-native
Artifact Attestations, not the cosign OCI attestation written by this SLSA
generator.
