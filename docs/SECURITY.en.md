# EverVigil Security Details

[日本語](SECURITY.ja.md) | [Reporting policy](../SECURITY.md) | [Technical overview](TECHNICAL_OVERVIEW.en.md)

Target release: EverVigil v2.0.0. Repository:
<https://github.com/DaichiMatsumoto/evervigil>.

## Bridge token

- EverVigil generates 16 bytes with a cryptographically secure random number
  generator and encodes them as 32 lowercase hexadecimal characters.
- The token is protected with Windows DPAPI `CurrentUser` and
  application-specific entropy.
- The data directory and token file receive a restrictive ACL for the current
  user, `SYSTEM`, and local administrators.
- Replacement uses a temporary file and an atomic move so a partial write is
  not accepted as a token.
- The token is passed to the managed bridge through the `BRIDGE_TOKEN`
  environment variable and is never included in command-line arguments.
- Plaintext tokens are not stored in settings, Git, setup packages, or logs.

While the managed bridge is running, the token is plaintext inside that child
process environment and may be visible to same-user process inspection, crash
dumps, or an administrator. DPAPI protects the stored token at rest; it does not
protect a live process from those actors.

DPAPI `CurrentUser` is not a boundary against malicious software running as the
same Windows user. A local administrator can also access or influence the user
session and is not a security boundary. Protect the Windows account and device.

## Codex credentials

EverVigil does not request, inspect, read, store, copy, export, or transmit
Codex authentication credentials. Authentication is managed by the user's
separately installed Codex CLI. EverVigil stores only the configured executable
path and local app-server port required to start and health-check the child.
The managed bridge environment is rebuilt from an explicit non-secret allowlist;
parent API keys, Codex environment credentials, proxy variables, and inherited
search paths are not forwarded to the third-party Node process.

## QR, display, and clipboard

- The token, connection URL, and QR code are credentials and are hidden by default.
- The QR code is generated locally; no QR payload is sent to an external service.
- Explicit Reveal is required, and the display is hidden again after
  approximately 60 seconds.
- Window deactivation hides the secret immediately.
- Copying displays a warning about clipboard history and other applications.
- Unchanged copied content is cleared after the configured timeout; locked
  clipboard access uses bounded retry.
- Token regeneration requires confirmation and restarts the managed service only
  if it was running before regeneration.

The approximately 60-second display limit does not expire or rotate the token.
Regenerate it after suspected disclosure.

Anyone who obtains the URL or QR code obtains the bridge token. Screen capture,
accessibility software, clipboard managers, and same-user processes may observe
a deliberately revealed secret.

## Network

- The intended path is Tailnet client -> Tailscale Serve `:3456` ->
  `127.0.0.1:3457` -> `127.0.0.1:8765`.
- Serve targets and the Codex app-server use loopback addresses. An
  application-owned, SID-identifiable Windows Firewall rule blocks direct
  inbound access to the Even Terminal backend.
- The tested upstream `@evenrealities/even-terminal` 0.8.1 listener binds to
  `0.0.0.0`. EverVigil does not patch it and therefore cannot currently
  guarantee a strict loopback-only bind. The owned Firewall rule is required
  mitigation; this remains an explicit release risk.
- Tailscale Serve is Tailnet-only, depends on the Tailnet ACL policy, and does
  not use Funnel.
- EverVigil does not configure a public-Internet listener, telemetry endpoint,
  proprietary cloud backend, or external relay.
- Serve routes and Firewall rules are changed or removed only after the stored
  protected broker ledger, user identity, target, and expected properties match.
- Health, Reveal, and Copy additionally require a fresh read-only Serve status
  check showing the exact protected root proxy and no active Funnel.
- An unrelated or ambiguous route/rule is left unchanged.
- UAC launches only the canonical ProgramData broker. The tray executable,
  PowerShell scripts, and user-writable installed files are never elevated.
- The broker authenticates its medium-integrity named-pipe client by process,
  SID, session, integrity level, and nonce; privileged ownership evidence is
  written only to its protected per-SID ProgramData journal and ledger.
- UAC is requested only for bootstrap or a system operation that requires it;
  normal supervision is never continuously elevated.
- Missing, invalid, or unapplied system configuration blocks backend startup.

Tailnet membership does not by itself authorize access. Tailnet administrators
must maintain an ACL policy appropriate for the bridge credential and devices.
Network reachability controls do not replace bridge-token authentication, and
same-host software can attempt to connect to loopback endpoints.

## Process supervision

- EverVigil and Node.js are launched without visible console windows.
- The bridge launcher joins a Windows Job Object before descendants are created.
- Job Object termination reclaims the owned process tree during restart,
  rollback, exit, and uninstall.
- Single-instance synchronization is scoped to the Windows user.
- Restart backoff and crash-loop suppression bound repeated failure recovery.
- Startup runs as the user; elevated maintenance is separate and short-lived.

## Logging and redaction

- URL `token` query values, bearer credentials, the known bridge token, and
  32-character hexadecimal token-shaped values are redacted before writing.
- QR payloads and full connection URLs are not logged.
- Logs are bounded by file size and generation count and use restrictive ACLs.
- Normal operation drains but does not retain child-process stdout or stderr.
- No Codex authentication credential is collected or logged.

Diagnostic output can still contain local paths, hostnames, process errors, or
application content. Inspect and sanitize it manually before sharing.

## Install, manual update, rollback, and removal

- EverVigil has no automatic updater. The user manually downloads a GitHub
  Release, verifies SHA-256, and runs the installer.
- Community binaries are unsigned and may trigger Microsoft Defender SmartScreen.
- The unsigned v2.0.0 first broker bootstrap is not a publisher-authenticated
  trust anchor. A future broker replacement requires an approved signing or
  OS-trusted installer design.
- A SHA-256 match proves file identity, not publisher identity or safety.
- When the installer and checksum come from the same Release, SHA-256 does not
  independently authenticate the publisher; verify the repository and Release
  identity as well.
- Setup validates the final filesystem target and rejects ambiguous aliases,
  reparse points, protected trees, and unrelated non-empty destinations.
- A durable journal and verified snapshots precede mutation. Settings, token,
  and startup preference are restored if update activation fails.
- Rollback must be verified before the prior service restarts; otherwise startup
  remains blocked.
- Uninstall stops owned processes and removes only ownership-verified routes,
  rules, startup entries, shortcuts, support data, transactions, temporary data,
  and the verified install directory.
- The user chooses whether settings and the DPAPI token are retained or deleted.
- Retention intentionally leaves the encrypted token and settings in the data
  directory. Complete removal deletes them after ownership checks.
- Tailscale, Node.js, Codex, `@evenrealities/even-terminal`, unrelated routes or
  rules, and independently created user data are never removed.

## External dependency limitations

EverVigil depends on Windows, Tailscale, Node.js, Even Terminal, and Codex. Each
retains its own update, availability, authentication, and security model.
EverVigil's health checks and ownership checks do not certify those products.
