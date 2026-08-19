# EverVigil User Guide

[日本語](README.ja.md) | [Technical overview](TECHNICAL_OVERVIEW.en.md) | [Technical reference](REFERENCE.en.md) | [Root README](../README.md)

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

EverVigil is an independent Windows tray utility that keeps Even Terminal
running and available. It manages a separately installed Even Terminal package
and Codex app-server; those dependencies are not part of EverVigil.

## Requirements

- Windows 11 x64
- PowerShell 7
- Node.js
- `@evenrealities/even-terminal` installed separately
- Codex CLI installed and already authenticated by the user
- Tailscale connected to the intended Tailnet

EverVigil never asks for, reads, stores, or transmits Codex authentication
credentials. It only starts the configured Codex executable as a child of the
separately installed Even Terminal process.

The setup EXE contains the .NET runtime. A .NET SDK and Inno Setup are required
only when building from source.

## Install v2.1.1

1. Download `EverVigil-2.1.1-Setup.exe` from the approved GitHub Release at
   <https://github.com/DaichiMatsumoto/evervigil/releases>.
2. Calculate its SHA-256 and compare it with the exact value in the Release.
3. Run the installer, read the independent-project notice, review the
   destination, and complete setup.

Community builds are not Authenticode-signed and may trigger Microsoft Defender
SmartScreen. A warning is not a checksum: verify SHA-256 independently before
running the file.

The default destination is `%LOCALAPPDATA%\Programs\EverVigil`. Setup rejects
unsafe or ambiguous destinations, including network paths, protected system
trees, temporary trees, reparse points, substituted drives, and path aliases.
It runs without elevation. When installation must create or change the owned
Tailscale Serve route and Windows Firewall rule, Setup uses at most two short
UAC operations: Apply, then Commit after validation. Normal supervision is
never kept permanently elevated.

If a dependency cannot be discovered, open the tray window, choose the correct
executable or project path, save the settings, and rerun the same installer to
finish system configuration.

## Network configuration

The default path is:

```text
Even client / G2
  -> Tailscale Tailnet
  -> Tailscale Serve :3456
  -> 127.0.0.1:3457 Even Terminal
  -> 127.0.0.1:8765 Codex app-server
```

The expected Serve operation is equivalent to:

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

EverVigil does not use Tailscale Funnel. Port 3456 is available only through the
Tailnet and access depends on the Tailnet ACL policy. Serve targets the loopback
address above. An application-owned, user-identifiable Windows Firewall rule
also blocks direct inbound traffic to port 3457.

The currently tested upstream package, `@evenrealities/even-terminal` 0.8.1,
binds its HTTP listener to `0.0.0.0`. EverVigil does not patch that package, so
it cannot currently enforce a strict loopback-only bind. The Firewall rule is
required mitigation, and this upstream limitation remains a release risk.

Before changing or removing a Serve route, EverVigil compares the route target
with its persisted ownership record. A route owned by another application or
user is left unchanged. The same ownership rule applies to Firewall cleanup.

## Connect with QR

Open the tray window and select the connection panel. Secrets are hidden by
default. Select `Reveal` to show the URL and locally generated QR code:

```text
http://<Tailscale-hostname>:3456/?token=<bridge-token>&defaultProvider=codex
```

The URL and QR code are credentials. EverVigil:

- generates the QR code locally and uses no external QR service;
- hides the secret again after approximately 60 seconds;
- hides it immediately when the window is deactivated;
- warns that a copied value may remain in clipboard history or other apps;
- clears unchanged clipboard content after the configured timeout; and
- never writes the QR payload or token to its logs.

Do not include the connection URL or QR code in screenshots, chats, Issues, or
diagnostic bundles.

The approximately 60-second limit hides the displayed credential; it does not
expire the token. Use token regeneration after suspected disclosure.

## Daily operation

Use the notification-area menu to open EverVigil, start, stop, or restart the
managed service, view health, and inspect redacted logs. Closing the window
returns it to the notification area. Use the tray `Exit` command to stop
EverVigil.

When startup is enabled, the `EverVigil` Startup entry launches the tray-only
application at Windows login. The child process tree is placed in a Windows Job
Object so EverVigil can stop owned descendants during restart, update, or
uninstall. Repeated failures use bounded exponential backoff and crash-loop
suppression.

## Manual update

EverVigil has no automatic updater. Download a newer installer from the GitHub
Release page and verify its SHA-256. To update from EverVigil v2.1.0 to
v2.1.1, uninstall v2.1.0 first. Choose **Yes** at the uninstall data prompt to
retain same-user settings and the DPAPI-protected bridge token, or **No** for a
complete removal. Then run the v2.1.1 installer. The v2.1.1 installer refuses a
remaining v2.1.0 protected Broker rather than modifying ambiguous privileged
state. This uninstall/reinstall requirement does not change the separate,
authenticated in-place migration from the legacy v1.2.1 product described
below.

## Upgrade from legacy v1.2.1

EverVigil v2.1.1 uses an in-place upgrade because preserving the established
installer identity allows the existing settings and DPAPI-protected token to
remain usable by the same Windows user. The preserved identity is an internal
migration key, not a user-facing product name.

During migration, the installer validates ownership before stopping or removing
legacy resources. It preserves the user's settings, token, and startup choice;
replaces user-facing names with EverVigil; and removes only owned duplicate
process, startup, shortcut, Firewall, Serve, transaction, support, and program
resources after the new installation is healthy. Ambiguous ownership fails
closed and requires manual resolution.

To preserve DPAPI decryptability, a validated v1.2.1 installation may continue
to use its compatibility data root, entropy context, and synchronization names
while migration is active. These values remain inside `LegacyCompatibility`;
do not manually move `token.dat`. If both current and predecessor data roots
contain persistent state, EverVigil fails closed instead of guessing which copy
is authoritative.

## Uninstall

Start uninstall from either:

- Windows `Settings > Apps > Installed apps`; or
- the EverVigil Start menu uninstall shortcut.

The uninstaller stops EverVigil and child processes it started, removes only
owned Tailscale Serve and Windows Firewall configuration, removes EverVigil
startup and shortcuts, and deletes only an ownership-verified installation
directory plus its transaction and temporary files. It asks whether settings
and the encrypted token should be retained for a future reinstall or removed.

Uninstall does not remove Tailscale, Node.js, Codex,
`@evenrealities/even-terminal`, or unrelated routes, rules, folders, settings,
or user-created files.

## Security boundaries

- The bridge token is 16 random bytes encoded as 32 hexadecimal characters.
- It is protected by DPAPI `CurrentUser` with application-specific entropy and
  stored with a restrictive ACL.
- It is passed to the managed child through `BRIDGE_TOKEN`, never on a command line.
- While the child is running, `BRIDGE_TOKEN` is plaintext in that process
  environment and may be observable by same-user software, an administrator,
  or a process dump. DPAPI protects the stored token at rest only.
- URL query tokens, bearer credentials, known token values, and 32-hex
  token-shaped values are redacted before logging.
- DPAPI `CurrentUser` does not defend against malicious code already running as
  the same Windows user, and an administrator is not treated as a security
  boundary.
- Tailnet access is controlled by Tailscale identity and ACL policy.
- Tailnet controls reduce network reachability but do not replace the bridge token.
- EverVigil adds no telemetry, cloud backend, public relay, or Funnel exposure.

See [Security details](SECURITY.en.md) and the
[Technical overview](TECHNICAL_OVERVIEW.en.md).

## License

EverVigil source code is licensed under
[GNU General Public License version 3 only](../LICENSE) (`GPL-3.0-only`). The
icon is independently created original artwork; its provenance is documented
in [NOTICE.md](../NOTICE.md).
