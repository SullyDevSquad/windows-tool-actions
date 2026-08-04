# Windows tool actions

Private, reusable composite actions for fail-closed Windows build-tool provisioning. The actions either validate a hosted-image prerequisite or provision caller-approved content after SHA-256 verification. They do not embed vendor binaries, licenses, download URLs, or placeholder hashes.

## Consumption policy

- Keep this repository private and grant access only to repositories that need these actions.
- Pin every reference to a reviewed 40-character commit SHA. Do not consume `main` or a moving tag from production.
- Use `windows-2025` for the documented baseline. Each action fails immediately on a non-Windows runner, except `setup-node-npm`, which is cross-platform.
- Treat URLs and hashes as a reviewed pair. A checksum proves identity with the reviewed artifact; it does not establish provenance by itself.
- Never expose licensed inputs to workflows triggered from forks. Put licensed jobs behind a protected GitHub Environment.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-msbuild@FULL_COMMIT_SHA
  with:
    vs-version: "17.0"
```

`FULL_COMMIT_SHA` is intentionally not a runnable placeholder. Replace it with a reviewed commit before moving the example into `.github/workflows`.

## Action catalog

| Action | Supported request | Network behavior | Primary outputs |
| --- | --- | --- | --- |
| `setup-dotnet-framework` | .NET Framework `4.8` | None | `release`, `runtime-version`, `sdk-path`, `reference-assemblies` |
| `setup-wix` | `6.x`, exact `6.y.z`, `3.11.1`, `3.14.1` | Approved ZIP only when no matching installation exists | `installed-version`, `path`, `major`, `source` |
| `setup-msbuild` | Visual Studio/MSBuild `17.0` line | None | `path`, `version`, `installation-path` |
| `setup-typemock` | Typemock `9.3.5` | Mandatory approved HTTPS installer and SHA-256 | `path`, `version`, `installer-ran`, `activated` |
| `setup-node-npm` | Explicit even Node.js LTS major; default `24` | Official `actions/setup-node` behavior | `node-version`, `npm-version` |
| `setup-msxsl` | Caller-approved `msxsl.exe` | Mandatory approved HTTPS binary and SHA-256 | `path`, `sha256`, `cache-hit` |

All downloaded content is placed under `RUNNER_TOOL_CACHE`. Cache hits are revalidated. The actions append to `GITHUB_PATH`, `GITHUB_ENV`, and `GITHUB_OUTPUT`; they do not mutate the current step's process environment as a substitute for GitHub file commands.

## `setup-dotnet-framework`

This action validates, but never installs:

1. The `HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full` release value is at least `528040`.
2. A 4.8-or-later compatible .NET Framework 4.x runtime reports a product version.
3. The `NETFXSDK\4.8` SDK registration and directory exist.
4. The 4.8 targeting pack contains core reference assemblies under the x86 Program Files reference-assembly path.

A newer in-place .NET Framework 4.x runtime is compatible, but the **4.8 developer pack/reference assemblies remain required** for targeting `net48`.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-dotnet-framework@FULL_COMMIT_SHA
  id: netfx
  with:
    version: "4.8"
```

Failure tells the image owner which prerequisite is absent. The action never installs a developer pack and never initiates a reboot.

## `setup-wix`

WiX v3 and v6 have deliberately separate discovery and validation paths:

- v3 requires both `candle.exe` and `light.exe`, adds their directory to `PATH`, and exports `WIX` as the tool root.
- v6 requires `wix.exe`, invokes `wix --version`, and adds its directory to `PATH`.
- A matching tool already on `PATH` is preferred. The tool cache is checked next.
- If no match exists, both `source-url` and `sha256` are mandatory. `source-url` must be an approved HTTPS **ZIP distribution**. The archive is verified before extraction.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-wix@FULL_COMMIT_SHA
  with:
    version: "6.0.2"
    source-url: ${{ vars.WIX_6_0_2_ZIP_URL }}
    sha256: ${{ vars.WIX_6_0_2_ZIP_SHA256 }}
```

### Exact pinning

Prefer an exact `6.y.z` request. `6.x` accepts any detected v6 patch; when it downloads, the reviewed URL/hash pair still fixes artifact identity, but the requested contract is not patch-specific. WiX v3 accepts only `3.11.1` or `3.14.1`. A preinstalled 3.14 tool is used only when its binary metadata reports exactly `3.14.1`.

This repository intentionally provides no URL or digest. Artifact owners must retain the vendor release URL, SHA-256, approval record, and acquisition date.

### WiX licensing

Use of WiX is subject to the applicable WiX Toolset license/EULA and current Open Source Maintenance Fee (OSMF) policy. Before approving a v6 artifact, have the organization's legal or open-source program owner review the vendor's current terms at <https://wixtoolset.org/docs/about/maintenance/>. This repository neither accepts terms on a consumer's behalf nor provides legal advice.

## `setup-msbuild`

`setup-msbuild` uses the runner-provided `vswhere.exe` to select the latest complete Visual Studio 2022 installation in `[17.0,18.0)`. Optional component IDs are passed to `vswhere -requires` as individual process arguments.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-msbuild@FULL_COMMIT_SHA
  id: msbuild
  with:
    vs-version: "17.0"
    required-components: >-
      Microsoft.VisualStudio.Component.VC.Tools.x86.x64,
      Microsoft.Net.Component.4.8.SDK,
      Microsoft.Net.Component.4.8.TargetingPack
```

The action validates `MSBuild.exe -version`, exports `MSBUILD_EXE_PATH`, and adds the containing directory to `PATH`. It does not install or modify Visual Studio.

## `setup-typemock`

Typemock is proprietary software. The action has no embedded installer, vendor syntax, license, or activation assumptions.

Required inputs:

- `installer-url`: reviewed HTTPS vendor installer URL.
- `sha256`: reviewed installer digest.
- `silent-install-arguments-json`: a JSON array of vendor-documented arguments, such as the value of an organization variable. A single command string is not accepted.
- `expected-executable`: absolute installed executable path (Windows environment variables may be used). File metadata must report `9.3.5`.

Optional structured activation accepts an absolute `activation-executable` and a JSON string array in `activation-arguments-json`. The process is invoked directly without `Invoke-Expression`, `cmd.exe`, or `powershell -Command`. Exactly one secret source is allowed:

- `license-value`, referenced by a `{license}` argument token; or
- `license-file`, referenced by a `{license-file}` argument token.

The placeholder may be embedded in an argument only when required by documented vendor syntax. Resolved arguments and secret inputs are masked, process output is suppressed, and secrets are never written to action outputs.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-typemock@FULL_COMMIT_SHA
  with:
    version: "9.3.5"
    installer-url: ${{ vars.TYPEMOCK_INSTALLER_URL }}
    sha256: ${{ vars.TYPEMOCK_INSTALLER_SHA256 }}
    silent-install-arguments-json: ${{ vars.TYPEMOCK_SILENT_ARGUMENTS_JSON }}
    expected-executable: ${{ vars.TYPEMOCK_EXPECTED_EXECUTABLE }}
    license-value: ${{ secrets.TYPEMOCK_LICENSE }}
    activation-executable: ${{ vars.TYPEMOCK_ACTIVATION_EXE }}
    activation-arguments-json: ${{ vars.TYPEMOCK_ACTIVATION_ARGUMENTS_JSON }}
```

If direct activation cannot be expressed safely with this interface, omit all license/activation inputs and run a separately reviewed caller step. Never pass a free-form activation command to this action.

### Licensed-runner lifecycle

Run licensed builds only for trusted branches in a protected `licensed-build` environment. Do not make secrets available to fork pull requests. Prefer ephemeral GitHub-hosted runners and vendor-supported short-lived activation. Composite actions do not support a JavaScript action-style `post` hook, so this action cannot guarantee deactivation after a later build step. If the license requires explicit release, the caller must add a vendor-documented deactivation step guarded with `if: ${{ always() }}` and ensure that job cancellation behavior meets the license policy.

## `setup-node-npm`

This action wraps `actions/setup-node` v6 pinned in `action.yml` to commit `249970729cb0ef3589644e2896645e5dc5ba9c38`. It provisions Node.js and npm only; it does not install dependencies, build React, publish packages, or deploy.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-node-npm@FULL_COMMIT_SHA
  with:
    node-version: "24"
    cache: npm
    lockfile: package-lock.json
    registry-url: https://registry.npmjs.org
    scope: "@example"
```

Use an even-numbered LTS major. The requested major is checked again after setup and both semantic versions are emitted.

## `setup-msxsl`

`setup-msxsl` downloads only from the caller's HTTPS URL, verifies the mandatory SHA-256, stores the binary by digest under `RUNNER_TOOL_CACHE`, and performs a minimal XML/XSL transform. It does not depend on undocumented version or help switches.

```yaml
- uses: SullyDevSquad/windows-tool-actions/setup-msxsl@FULL_COMMIT_SHA
  with:
    binary-url: ${{ vars.MSXSL_BINARY_URL }}
    sha256: ${{ vars.MSXSL_BINARY_SHA256 }}
```

Microsoft's historical redistribution terms may not permit mirroring or redistribution in every context. Before populating `MSXSL_BINARY_URL`, the artifact owner must verify:

1. the binary came from an authoritative, approved source;
2. acquisition and internal hosting comply with applicable license/redistribution terms;
3. the recorded digest was computed from that reviewed binary; and
4. access controls prevent substituting an unreviewed object.

This repository does not distribute MSXSL.

## External prerequisites

| Prerequisite | Owner responsibility |
| --- | --- |
| Windows runner image | Provide VS 2022/MSBuild, vswhere, .NET Framework 4.8 developer pack, and any expected preinstalled WiX version |
| Artifact hosting | Restrict write access, retain vendor provenance, serve HTTPS, and review every URL/digest change |
| Typemock | Maintain entitlement, vendor installer, documented silent/activation arguments, protected license secret, and deactivation policy |
| WiX | Review release provenance and applicable EULA/OSMF obligations |
| MSXSL | Confirm provenance and redistribution/internal-hosting rights |
| Node.js | Permit the pinned official setup action to acquire the requested Node distribution |

## Repository validation

- `.github/workflows/validate.yml` runs YAML parsing, PowerShell parsing, and static contract tests without downloading licensed/vendor content.
- `.github/workflows/hosted-image-drift.yml` runs weekly and manually on `windows-2025` to detect .NET Framework, MSBuild, WiX 3.14.1, and Node 24 image drift.
- `tests/Test-Contracts.ps1` is dependency-free and can run on any host with PowerShell 7.
- `actionlint .github/workflows/*.yml` must produce no findings before merge.

See [SECURITY.md](SECURITY.md) for the threat model and reporting process. A complete, deliberately non-runnable consumer template is in [`examples/windows-build.yml`](examples/windows-build.yml).
