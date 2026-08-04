# Security policy

## Reporting

Report suspected vulnerabilities through this repository's private vulnerability reporting or GitHub Security Advisory interface. Do not include licenses, authenticated artifact URLs, tokens, or customer build logs in an issue or pull request. If private reporting is unavailable, contact the repository administrators through an approved internal channel.

The supported version is the latest reviewed commit on `main`. Consumers must pin that commit by full SHA and update only after review.

## Threat model and controls

These actions execute build tools with the permissions of a GitHub Actions runner. The primary risks are artifact substitution, malicious input interpreted as code, secret disclosure, license misuse, and silent hosted-image drift.

- Download actions require absolute HTTPS URLs without embedded credentials and exact 64-character SHA-256 values.
- Downloads are verified before extraction or execution. Cache hits are rehashed or tool-version validated.
- The repository contains no vendor binaries, default download locations, digests, licenses, or activation syntax.
- Composite metadata passes secret-bearing inputs through environment variables instead of interpolating them into PowerShell source.
- Typemock installer and activation arguments are JSON arrays. Executables are launched directly with `ProcessStartInfo.ArgumentList`; no action uses `Invoke-Expression`.
- PowerShell uses literal paths and terminating errors. Unsupported versions fail closed.
- Workflows use least-privilege `contents: read`, avoid `pull_request_target`, and pin third-party actions to full commit SHAs.

SHA-256 verifies artifact identity only. Artifact owners must separately verify provenance, publisher authenticity, licensing, retention, and access controls.

## Licensed builds

Typemock jobs must use a protected environment such as `licensed-build` and run only for trusted code. Repository administrators must not expose license secrets or authenticated URLs to workflows from forks. Prefer ephemeral hosted runners and vendor-supported short-lived activation.

GitHub composite actions do not provide a guaranteed post-job hook. If a vendor requires deactivation, consumers must implement and test a vendor-documented `if: ${{ always() }}` cleanup step in their workflow. Consider cancellation and runner-loss behavior when deciding whether a license model is suitable.

## Review checklist

Before updating a URL, checksum, version, or pinned action:

1. Acquire the artifact from an authoritative channel.
2. Verify publisher signatures where available.
3. Compute SHA-256 independently and record provenance outside this repository.
4. Review EULA, OSMF, redistribution, and license-seat implications.
5. Update the reviewed URL and checksum together in protected environment or repository configuration.
6. Run static validation and the appropriate trusted integration workflow.
7. Pin consumers to the resulting reviewed commit SHA.
