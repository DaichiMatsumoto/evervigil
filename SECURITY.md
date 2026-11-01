# Security Policy

[English details](docs/SECURITY.en.md) | [日本語の詳細](docs/SECURITY.ja.md)

## Supported versions

Security fixes target [EverVigil v2.1.0](https://github.com/DaichiMatsumoto/evervigil/releases/tag/v2.1.0).
Older releases, including v2.0.0, and unpublished release candidates are not supported.

EverVigil has no automatic updater. Download updates manually from
<https://github.com/DaichiMatsumoto/evervigil/releases>, verify the published
SHA-256, and remember that current community binaries are unsigned and may
trigger Microsoft Defender SmartScreen. SHA-256 verifies file integrity; it does
not independently authenticate the publisher or prove safety.

To update from v2.0.0, uninstall it while choosing to retain settings and the
encrypted bridge token, then install v2.1.0. Different protected Broker versions
cannot coexist; direct installation over v2.0.0 is rejected.

## CLI and project settings

Codex and Claude CLI paths, default project folders, and model choices are stored
as local settings. Only select executables you trust: they run with your Windows
user's permissions. Authentication and model access are managed by each CLI and
its provider. EverVigil's bridge token does not replace those credentials.

## Reporting a vulnerability

Do not include bridge tokens, connection URLs, QR codes, logs, usernames,
hostnames, project paths, Codex or Claude credentials, or conversation content in a public
Issue.

Use [GitHub private vulnerability reporting](https://github.com/DaichiMatsumoto/evervigil/security/advisories/new).
Include the affected EverVigil version, relevant CLI versions,
expected security boundary, sanitized reproduction steps, and observed impact.
If private reporting is unavailable, open a public Issue without exploit
details or secrets and request a private contact channel.

This volunteer community project provides no response-time guarantee.
