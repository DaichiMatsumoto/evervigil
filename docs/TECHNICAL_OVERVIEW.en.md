# EverVigil Technical Overview

[日本語](TECHNICAL_OVERVIEW.ja.md) | [User guide](README.en.md) | [Technical reference](REFERENCE.en.md) | [Repository](https://github.com/DaichiMatsumoto/evervigil)

This document describes the EverVigil v2.1.1 architecture and security model.

## 1. Architecture

```text
Even client / G2
  -> Tailscale Tailnet
  -> Tailscale Serve :3456
  -> 127.0.0.1:3457 Even Terminal
  -> 127.0.0.1:8765 Codex app-server

Windows login
  -> EverVigil Startup entry
  -> tray application (medium integrity)
  -> supervised launcher and Job Object
  -> separately installed Node.js / Even Terminal / Codex

System configuration request
  -> authenticated named pipe bound to the client PID, SID, session, and nonce
  -> canonical EverVigil.Broker.exe (high integrity only for fixed operations)
  -> protected ProgramData journal / Tailscale Serve / Windows Firewall
```

EverVigil is a per-user .NET 8 Windows tray application. It orchestrates local
dependencies but does not bundle, fork, patch, or redistribute
`@evenrealities/even-terminal`, Codex, Node.js, or Tailscale. It adds no
telemetry, proprietary cloud backend, or external relay.

The product name, executable, startup entry, install folder, Start menu folder,
process, and window title are all `EverVigil`. Compatibility-only identifiers
from the predecessor are internal migration data, not product names.

## 2. Process supervision

EverVigil starts the Even Terminal bridge and its Codex provider without a
visible console. The bridge launcher is assigned to a Windows Job Object before
it creates descendants. This lets EverVigil stop the owned process tree during
a restart, update, rollback, or uninstall.

Authenticated health requests are sent only to the loopback backend. Tailnet
readiness additionally requires the protected broker ledger to match the active
ports and Tailscale executable, a currently assigned local Tailscale address,
every fresh DNS answer for the recorded Tailscale Self name, and the current
Serve status to contain the exact protected root proxy with Funnel disabled.
The Serve check is read-only and unelevated. No health check sends the bridge
token to a configured or remote host. Unexpected exits trigger
bounded exponential backoff. The failure counter
resets after a stable run, and a crash-loop threshold suppresses unlimited
restart attempts. Windows login startup launches the tray application without
opening the management window. Ordinary monitoring runs as the user and is not
permanently elevated.

## 3. Tailscale Serve configuration

The default operation is equivalent to:

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

EverVigil does not enable Funnel. The listener is Tailnet-only and depends on
Tailscale identity, device posture where configured, and Tailnet ACL policy.
It is not a public-Internet endpoint.

Before applying, replacing, or removing a route, EverVigil reads Serve status
and verifies that the root mapping and loopback target match its persisted
current-user ownership record. An unrelated or ambiguous route is not
overwritten or deleted. A configuration change requests UAC only for the
maintenance operation that needs it; steady-state supervision remains
unelevated.

EverVigil never elevates the tray executable, a PowerShell script, or another
file that remains writable by the application user. A medium-integrity client
contacts only the versioned canonical `EverVigil.Broker.exe` below
`%ProgramData%\EverVigil\Broker`. The broker authenticates the named-pipe client
by process handle, SID, session, integrity level, and one-time nonce. It exposes
only fixed system-configuration operations and discovers Tailscale from its
fixed protected installation path; caller-supplied programs and scripts are not
executed at high integrity.

The canonical broker, not the unelevated process, owns the authoritative,
write-through `pending-system-configuration.json`, applied ledger, previous
ledger snapshot, and transaction receipt under the ACL-protected ProgramData
state directory for the original user SID. The journal records exact previous
and target ports, preflight route ownership, full Firewall-rule identity, and a
monotonic mutation phase. Each external mutation is authorized durably
immediately before it runs. Receipt replay makes a lost response or a crash
between commit writes idempotent. LocalAppData transaction data coordinates the
installer but is never privileged ownership evidence.

A crash therefore leaves enough protected evidence to finalize an exactly
verified completed change or restore only the verified previous state. Funnel
exposure, an unknown route, a duplicate or mismatched Firewall rule, an
untrusted Tailscale executable, and a journal or client-identity mismatch all
fail closed and leave the backend blocked for recovery.

## 4. QR connection flow

The connection value is:

```text
http://<Tailscale-hostname>:3456/?token=<bridge-token>&defaultProvider=codex
```

The QR code is generated in-process with the bundled QRCoder library. Neither
the URL nor token is sent to an external QR service. The URL, QR code, and token
are credentials and are hidden by default. An explicit Reveal action displays
them; they are concealed again after approximately 60 seconds and immediately
when the window deactivates.

The host is not user-configurable. Reveal and Copy fail closed unless the
read-only protected broker ledger matches the active configuration, its
Tailscale addresses are currently assigned to this device, and every current
DNS answer for the recorded Tailscale Self name is one of those protected local
addresses. The current Serve root must also still map the protected public port
to the protected loopback backend with Funnel disabled. There is no machine-name
or arbitrary-host fallback.

Copying displays a warning that the credential may remain in clipboard history
or other applications. EverVigil clears the clipboard after the configured
timeout only if its content is unchanged. QR pixels, connection URLs, and token
values are never intentionally written to logs.

The approximately 60-second interval is a display lifetime, not token expiry.
Hiding the panel or deactivating the window does not rotate the token. A user
must regenerate the token after suspected disclosure.

## 5. Network boundaries

Tailscale Serve targets `127.0.0.1:3457`, and the Codex app-server uses
`127.0.0.1:8765`. Serve on port 3456 is the only intended client entry point.
An application-owned, SID-identifiable Windows Firewall rule blocks direct
inbound traffic to the Even Terminal backend. Removal verifies ownership and
never removes an unrelated rule.

The tested upstream `@evenrealities/even-terminal` 0.8.1 listener binds to
`0.0.0.0`. EverVigil does not patch that package and therefore cannot currently
guarantee a strict loopback-only bind. The Firewall rule is required mitigation,
and the upstream bind behavior remains an explicit release risk.

The security boundary is the combination of Windows user isolation, the owned
Firewall rule, Tailscale device identity, Tailnet ACLs, and loopback-only Codex
app-server access.
EverVigil does not configure a public-Internet listener, use Funnel, add a cloud
backend, or create an external relay.

## 6. Credential handling

EverVigil generates at least 16 bytes with a cryptographically secure random
number generator and represents them as a 32-character hexadecimal bridge
token. The token is protected with Windows DPAPI `CurrentUser`,
application-specific entropy, and a restrictive file ACL. Writes use a
temporary file followed by replacement to avoid a partially written token.

The plaintext is passed to the managed bridge only in the `BRIDGE_TOKEN`
environment variable. It is never placed on a process command line. The
connection URL and QR code are treated as equivalent credentials.

The launcher and Node bridge receive a newly constructed environment containing
only fixed Windows/profile paths, the configured executable search directories,
non-secret EverVigil runtime values, and `BRIDGE_TOKEN`. Parent entries such as
`OPENAI_API_KEY`, `GH_TOKEN`, `CODEX_HOME`, proxy settings, and an inherited
`PATH` are not forwarded. Environment-based Codex credentials are deliberately
unsupported; Codex authentication must remain in the separately managed CLI.

While the managed bridge is running, plaintext necessarily exists in that
child's environment and may appear in a same-user process inspection or crash
dump. DPAPI protects the token at rest; it does not protect the live process
from software running as the same user or from an administrator.

EverVigil does not read, store, copy, export, or transmit Codex authentication
credentials. Codex authentication remains owned by the user's separately
installed Codex CLI.

DPAPI `CurrentUser` is not a boundary against malicious code already running as
the same user. A local administrator is also not treated as a security boundary.

## 7. Logging and redaction

Logging is bounded by file size and generation count. Before writing, the
redactor removes URL `token` query values, bearer credentials, the known bridge
token, and 32-character hexadecimal token-shaped values. QR payloads and full
connection URLs are not diagnostic events. The upstream child's stdout and
stderr are drained to prevent process blockage but are never retained or
forwarded into EverVigil logs because its startup banner contains credentials
and a machine-readable QR code.

Diagnostics can still contain local paths, hostnames, dependency errors, or
application content. Users must inspect and sanitize logs before sharing them.
EverVigil does not log or collect Codex authentication data.

## 8. Update mechanism

EverVigil has no automatic updater. The user manually downloads an approved
`EverVigil-<version>-Setup.exe` from GitHub Releases, compares its SHA-256 with
the published value, and runs it over the existing installation. Community
binaries are unsigned and may trigger Microsoft Defender SmartScreen.

The checksum establishes that a file matches the value published by the
repository. When the installer and checksum are obtained from the same Release,
the checksum does not independently authenticate the publisher; users must also
confirm the repository and Release identity.

Before mutation, setup records a durable transaction, snapshots mutable data,
and retains the previous working application. Settings, the DPAPI-protected
token, and startup preference are preserved. All fallible external retirement
(legacy shortcuts, support, plaintext credentials, and temporary trees) is
completed while those snapshots can still restore the prior version. A failure
before the durable `SystemCommitPrepared` boundary restores the verified
snapshots, prior program, system configuration, startup state, and running
state. An unverified rollback leaves startup blocked rather than starting a
partially installed service.

`SystemCommitPrepared` is recorded only after the replacement and all external
post-state have been validated. From that point the protected broker may have
committed even if its response is lost, so recovery proceeds forward and never
guesses that rollback is safe. If final evidence cleanup is interrupted, setup
returns its recovery-required code, keeps the validated new installation
active, and requires the same installer to resume the exact transaction. Only
backup and transaction evidence removal remains after the protected commit.

Setup performs a bootstrap-only broker preparation even when runtime
dependencies are incomplete, so a CONFIGURATION REQUIRED installation still
has a protected cleanup path. Bootstrap installs and verifies the canonical
broker but performs no Serve or Firewall mutation. Apply, commit, recovery,
rollback, and uninstall operations then run only through that canonical broker.

## 9. Upgrade from Even Terminal Supervisor

EverVigil v2.1.1 adopts an in-place upgrade from legacy v1.2.1. Keeping the
existing Inno Setup AppId is the preferred design because it lets Windows treat
v2.1.1 as the replacement installation and preserves same-user settings and the
DPAPI-protected token. The retained AppId, entropy compatibility, old paths,
mutexes, task names, and other predecessor identifiers are centralized in the
implementation's `LegacyCompatibility` boundary. They are not shown as the
EverVigil product name.

Migration validates the predecessor installation and resource ownership before
any stop, move, or deletion. It preserves settings, token, and startup choice;
changes user-visible names to EverVigil; and removes only owned predecessor
processes, startup entries, shortcuts, Firewall rules, Serve mappings,
transaction data, support files, and install files after EverVigil is healthy.
Unrelated resources are retained. Ambiguous ownership fails closed.

Legacy conversion participates in the same durable transaction as activation.
The predecessor program and verified snapshots remain available until setup
commits; a failure restores the pre-migration state before the prior runtime is
restarted.

The validated predecessor data root, DPAPI entropy context, and synchronization
names may remain active while required to decrypt and coordinate v1.2.1 state.
They are compatibility internals, not user-facing branding. If both current and
predecessor data roots contain persistent state, startup fails closed rather
than choosing one implicitly.

Release approval requires a real v1.2.1-to-v2.1.1 migration test confirming
that settings and token remain usable and no duplicate owned process, route,
rule, shortcut, startup entry, or installation directory remains.

## 10. Uninstall process

Uninstall is available through Windows Installed Apps and the EverVigil Start
menu shortcut. It:

1. checks for pending install recovery and acquires the transaction lock;
2. stops EverVigil and the child process tree it owns;
3. removes only ownership-verified Tailscale Serve and Firewall configuration;
4. removes the EverVigil startup entry and shortcuts;
5. removes the verified install directory, transaction journal, and temporary files; and
6. retains or deletes settings and the DPAPI token according to the user's choice.

Choosing retention intentionally leaves the encrypted token and settings in
the EverVigil data directory. Stopping the owned child removes its process-local
`BRIDGE_TOKEN` environment. If owned system cleanup cannot be verified,
uninstall reports failure instead of claiming complete removal.

The canonical privileged broker keeps machine-wide ownership evidence per
Windows SID. Uninstall always retires the current SID's protected state,
regardless of the settings/token retention choice. If another SID still has
protected EverVigil state, the shared canonical broker remains installed and
the uninstall report says so. For the last SID, the broker first writes a
durable retirement receipt and grants the original user delete-only access to
the fixed canonical files and empty directories. After the elevated broker
exits, the medium-integrity uninstaller verifies the receipt, image hash,
bounded tree, ACLs, and absence of reparse points before deleting those exact
paths bottom-up. A lost response or interruption resumes from the protected
receipt. If Windows must defer deletion until restart, uninstall stops and
reports the exact residue; it must be run again after restart before complete
removal is claimed.

Hard-crash atomic temporaries are never removed by filename alone. Settings and
applied-state JSON must match their bounded schemas, token data must decrypt as
the expected CurrentUser DPAPI token with fixed application entropy, and every
file must have the current-owner restricted ACL. A pending-system temporary is
deleted only after its transaction is reconciled with the protected broker.
Obsolete verified temporaries are removed even when settings/token retention is
selected; unknown or redirected files stop uninstall fail-closed.

It never removes Tailscale, Node.js, Codex,
`@evenrealities/even-terminal`, an unrelated route or Firewall rule, an
unverified directory, or settings created independently by the user. A failed
ownership check stops cleanup before destructive work.

## 11. Security limitations

- The project is a community utility, not a vendor security product or audit.
- Unsigned binaries may be blocked or warned about by Windows.
- The v2.1.1 broker bootstrap is unsigned. Its first installation therefore
  cannot provide a publisher-authenticated trust anchor; future broker binary
  replacement requires an approved signing or OS-trusted installer design.
- SHA-256 verifies file identity, not publisher identity or code safety.
- Tailnet membership alone does not authorize access; administrators must
  maintain appropriate ACLs.
- Network reachability controls do not replace bridge-token authentication;
  same-host software can attempt to reach loopback services.
- DPAPI does not protect against same-user malware or a local administrator.
- Anyone who obtains the connection URL or QR code obtains the bridge token.
- The tested upstream Even Terminal listener is not loopback-only; direct
  inbound traffic depends on the owned Firewall block rule.
- Clipboard history, screen capture, accessibility tools, or another process in
  the same user session may observe a revealed secret.
- External dependencies retain their own security, update, and availability risks.
- Ownership checks intentionally fail closed and may require manual repair.

## 12. No affiliation statement

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

References to Even Terminal describe compatibility only and are not part of the
EverVigil product name. No certification or recognition badge is provided.
