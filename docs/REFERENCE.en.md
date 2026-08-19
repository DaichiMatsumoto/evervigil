# EverVigil Technical Reference

[日本語](REFERENCE.ja.md) | [User guide](README.en.md) | [Technical overview](TECHNICAL_OVERVIEW.en.md) | [Repository](https://github.com/DaichiMatsumoto/evervigil)

Target release: `2.0.0`

## Runtime topology

```text
Tailnet client -> Tailscale Serve :3456
               -> 127.0.0.1:3457 Even Terminal
               -> 127.0.0.1:8765 Codex app-server

EverVigil -> launcher -> Node.js -> separately installed Even Terminal / Codex
```

Tailscale Serve is Tailnet-only, uses no Funnel, and remains subject to Tailnet
ACLs. EverVigil does not read or store Codex credentials.

## File locations

| Purpose | Location |
|---|---|
| Program | Setup selection; default `%LOCALAPPDATA%\Programs\EverVigil` |
| Settings | `%LOCALAPPDATA%\EverVigil\settings.json` |
| Applied system state | `%LOCALAPPDATA%\EverVigil\applied-system-configuration.json` |
| Startup block marker | `%LOCALAPPDATA%\EverVigil\system-configuration-required` |
| DPAPI token | `%LOCALAPPDATA%\EverVigil\token.dat` |
| Logs | `%LOCALAPPDATA%\EverVigil\Logs\evervigil.log` |
| Startup shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\EverVigil.lnk` |

Settings, tokens, logs, transaction state, and machine-local configuration are
never release assets.

## Default settings

| Setting | Default / meaning |
|---|---|
| Display language | Windows display language; Japanese for Japanese, English otherwise |
| Display name | Current Windows machine name |
| Tailscale host | Read-only Tailscale Self DNS name from the protected broker ledger; no machine-name fallback |
| Tailscale CLI | Fixed read-only path `C:\Program Files\Tailscale\tailscale.exe`; custom executables are refused |
| Serve port | `3456` |
| Even Terminal backend | `127.0.0.1:3457` |
| Codex app-server | `127.0.0.1:8765` |
| Project directory | Current user profile |
| Health interval | 30 seconds |
| Provider / Tailnet check | 300 seconds |
| Startup timeout | 120 seconds |
| Stable run | 600 seconds |
| Failure threshold | 3 |
| Log limit | 5 MB x 3 generations |
| Secret reveal | Approximately 60 seconds |
| Clipboard clear | 60 seconds by default |

## Command line

| Option | Purpose |
|---|---|
| `--background` | Start in the notification area without showing a window |
| `--health-check` | Check the loopback backend/provider, protected live Tailscale Self identity, and current exact tailnet-only Serve root; zero means all passed |
| `--shutdown` | Gracefully stop the current-user instance |
| `--register-startup` | Register the `EverVigil` Startup shortcut |
| `--unregister-startup` | Remove the `EverVigil` Startup shortcut |
| `--force-start-service` | Start the managed service once regardless of its saved preference |

`--bridge-launcher`, system-maintenance, transaction-recovery, and audit modes
are internal interfaces. Do not run them manually.

## Serve and Firewall ownership

The default Serve command is:

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

Before mutation, the canonical ProgramData broker inspects
`tailscale serve status --json` and matches the root mapping against its
ACL-protected per-SID applied ledger. A mismatched or ambiguous mapping is
unowned and is not changed. The Windows Firewall block rule is user-identifiable
and is removed only after its full identity and protected ownership evidence
match. A medium-integrity client authenticates to the broker through a
PID/SID/session/nonce-bound named pipe. First-time installer Apply may execute
in the verified package broker that installs the canonical image in the same
elevated process; later operations execute only in the canonical broker. The
tray supervisor, PowerShell scripts, and child applications remain unelevated.

## Token and QR handling

`TokenUtility` generates 16 CSPRNG bytes and encodes them as 32 lowercase
hexadecimal characters. `TokenStore` protects the token with DPAPI
`CurrentUser`, the application-specific entropy label `EverVigil/token/v1`, and
a restrictive ACL. The bridge receives plaintext through `BRIDGE_TOKEN`; the
token is absent from command-line arguments.

QRCoder renders the connection URL locally. Reveal is explicit, expires after
approximately 60 seconds, and is cancelled on window deactivation. Copying
warns about clipboard history. Redaction covers URL query tokens, bearer
credentials, known token values, and 32-hex token-shaped values.

## Manual update and v1.2.1 compatibility

There is no automatic updater. Users download a GitHub Release installer,
verify its SHA-256, and run it over the installation. Binaries are unsigned and
may trigger SmartScreen.

For the v1.2.1 in-place upgrade only, the installer retains the predecessor's
AppId and necessary cryptographic/path compatibility through the dedicated
`LegacyCompatibility` boundary. These values are not user-facing names. The
transaction preserves settings, encrypted token bytes, and startup preference,
then removes only ownership-verified predecessor resources after EverVigil is
healthy. Rollback restores verified snapshots and the previous runnable state.

New installations use the EverVigil paths listed above. A validated v1.2.1
upgrade may use its predecessor data root, DPAPI entropy, and synchronization
names while required for safe compatibility. Do not move the token manually.
Persistent state in both current and predecessor roots is ambiguous and fails
closed.

## Uninstall contract

The uninstaller stops owned processes; removes owned Serve, Firewall, startup,
shortcut, support, transaction, temporary, and verified program resources; and
lets the user retain or delete settings and token. It does not remove Tailscale,
Node.js, Codex, `@evenrealities/even-terminal`, unrelated routes/rules, or an
unverified directory.

## Source validation

Run from the repository root:

```powershell
dotnet restore .\EverVigil.sln
dotnet build .\EverVigil.sln -c Release --no-restore
dotnet format .\EverVigil.sln --verify-no-changes --no-restore
dotnet run --project .\tests\EverVigil.Tests\EverVigil.Tests.csproj -c Release --no-build
dotnet run --project .\tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj -c Release --no-build
.\tests\Test-Repository.ps1
.\tests\Test-SystemMaintenance.ps1
.\tests\Test-InstallTransaction.ps1
.\scripts\Test-NuGetVulnerabilities.ps1 -SolutionPath .\EverVigil.sln
.\scripts\New-PlaceholderIcon.ps1 -Check
.\scripts\Test-ReleaseVersion.ps1 -Version 2.0.0
.\scripts\Build-Release.ps1 -Version 2.0.0
```

Release approval also requires source, staged-file, binary, extracted-installer,
VersionInfo, icon, notice, prohibited-string, and deny-list scans. A build or
scan not run on the target Windows environment must be reported as unperformed,
not passed.

Creating a private draft RC additionally requires production-installer audits
bound to the same candidate-manifest `sourceSha`, version, and installer
SHA-256. The Actions job is a controller only and never executes the candidate.
One separate dedicated ephemeral physical Windows 11 Pro target with an AMD CPU
and one with an Intel CPU must each report every check passed, zero failed, and
zero skipped before the publishing job can start. The contract covers a
clean install and the exact `CONFIGURATION REQUIRED` state; normal runtime
(Windows-login startup, tray operation, Even Terminal and Codex app-server
launch, abnormal-child restart, Tailscale Serve ownership, QR connection,
reveal timeout, token persistence, and a normal update); v1.2.1 default and
custom-path/port migrations; pre-boundary rollback; post-boundary forward
recovery; exact Start menu, ARP, and support registration; preserve and complete
uninstall; over-the-shoulder elevation using separate administrator credentials;
and residue/system snapshots.

The clean-install report contract is `schemaVersion=2`. The top-level
`cleanInstall` object and the `clean-install-execution-attestation` JSON evidence
must carry the same exact object. The existing external audit-harness CLI remains
unchanged, but both AMD and Intel harness runs must emit v2; the gate rejects an
older schema fail-closed. `cleanInstall` attests all of the following:

- Before execution, the current and legacy data roots, install root, transaction
  journal/temporary files, the entire `C:\ProgramData\EverVigil` protected broker
  root (`protectedBrokerRootAbsent=true`), protected broker executable/receipts,
  Start menu, ARP, and uninstall support are absent.
- The real production Setup path, whose name and pre/post SHA-256 exactly match the
  candidate, runs directly as a standard user with an HKCU install, successful
  `PrepareToInstall`, and Setup exit zero. `/AUDITEXTRACT`, a resource-audit build,
  compatibility mode, or administrative install mode cannot substitute for it.
- The two-stage authenticated pipe from a medium-integrity client to the
  high-integrity broker succeeds. `broker-authenticated-pipe-roundtrip` requires
  bootstrap=`CanonicalReady`, canonical status=`NoChange`, both exits zero, both
  pipe connections true, and zero authentication exit-3 events.
- The actual `pwsh.exe` and `coreclr.dll` paths, versions, and SHA-256 values are
  recorded. Across the full Setup lifecycle, Application Error Event 1000, .NET
  Runtime Event 1023, WER Event 1001, and `0x80131506` must each have zero events.
- Post-state verifies the exact installed version, `CONFIGURATION REQUIRED`, the
  installed executable, Start menu, ARP, support, and a completed transaction,
  with no remaining journal/temporary files, installer errors,
  `PrepareToInstall` failures, or legacy data root.

No GitHub Actions runner is registered on either target, and no GitHub job
token, runner registration credential, or Tailnet auth key is placed there. The
external audit harness runs only on a controller after its fixed hash and
protected Program Files path are verified; it hands the candidate to a separate
target that cannot reach controller credentials. Reports must attest distinct
controller/target fingerprints and sessions, credential absence on the target,
the clean physical snapshot, and retirement of the target session after audit.
Same-host execution is rejected.

Evidence artifacts are restricted to UTF-8 JSON, log, and text files. They must
not contain QR images, connection URLs, Bearer values, token query parameters,
the known canary, or token-shaped values. Every file is bound by length and
SHA-256 and is verified in audit jobs that have no write token. The publishing
job has the sole GitHub write token, checks out no repository code, and only
revalidates strict JSON plus every candidate, AMD-report, and Intel-report hash.
If either dedicated runner or the hash-pinned external audit harness is
unavailable, the gate remains closed; an unperformed audit is never a pass.
