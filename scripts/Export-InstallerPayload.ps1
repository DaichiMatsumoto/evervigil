[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Audit source directory not found: $source"
}
if (Test-Path -LiteralPath $destination) {
    throw "Audit destination already exists: $destination"
}
if ($destination.StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith("$destination\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Audit source and destination directories cannot contain one another.'
}

New-Item -ItemType Directory -Path $destination | Out-Null
Get-ChildItem -LiteralPath $source -Force |
    Copy-Item -Destination $destination -Recurse
"Extracted installer payload: $destination"
