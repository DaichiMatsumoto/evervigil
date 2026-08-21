# Security Policy

[English details](docs/SECURITY.en.md) | [日本語の詳細](docs/SECURITY.ja.md)

## Supported versions

Security fixes target the latest public EverVigil v2.x Release. EverVigil
v2.0.0 is the first and currently only public Release. An unpublished release
candidate is not supported until its build, clean-install, update, uninstall,
and security validation has completed.

EverVigil has no automatic updater. Download updates manually from
<https://github.com/DaichiMatsumoto/evervigil/releases>, verify the published
SHA-256, and remember that current community binaries are unsigned and may
trigger Microsoft Defender SmartScreen.

## Reporting a vulnerability

Do not include bridge tokens, connection URLs, QR codes, logs, usernames,
hostnames, file paths, Codex credentials, or conversation content in a public
Issue.

Use GitHub private vulnerability reporting for
<https://github.com/DaichiMatsumoto/evervigil>. Include the affected version,
expected security boundary, sanitized reproduction steps, and observed impact.
If private reporting is unavailable, open a public Issue without exploit
details or secrets and request a private contact channel.

This volunteer community project provides no response-time guarantee.
