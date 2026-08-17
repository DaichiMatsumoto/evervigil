# Third-Party Notices

EverVigil release binaries include the following redistributable components.

## Microsoft .NET 8

The self-contained Windows application includes Microsoft .NET runtime
components. The release package carries the applicable Microsoft license and
third-party notices.

Project information: <https://dotnet.microsoft.com/>

## QRCoder 1.8.0

Copyright (c) 2013-2025 Raffael Herrmann and 2024-2025 Shane Krueger.
QRCoder is provided under the MIT License; the release package carries its
license in `licenses/QRCODER-LICENSE.txt`. QR codes are generated locally; no
QR payload is sent to an external service.

Project information: <https://github.com/Shane32/QRCoder>

## Inno Setup 6.7.1 or later

The single-file Windows setup program is produced with Inno Setup. The release
package carries the applicable license in `licenses/INNO-SETUP-LICENSE.txt`.

Project information: <https://jrsoftware.org/isinfo.php>

## Separately installed dependencies

Even Terminal, Codex CLI, Node.js, and Tailscale are external applications
invoked from the user's installation. They are not bundled in the EverVigil
release package. In particular, EverVigil does not fork, patch, or redistribute
`@evenrealities/even-terminal`.
