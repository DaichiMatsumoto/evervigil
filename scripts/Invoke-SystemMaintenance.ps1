[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'Apply',
        'Recover',
        'Rollback',
        'Commit',
        'UninstallCleanup',
        'LegacyTaskCleanup',
        'Status')]
    [string]$Operation,

    [Parameter(Mandatory)]
    [ValidatePattern(
        '^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')]
    [string]$TransactionId,

    [Parameter(Mandatory)]
    [ValidateSet('Interactive', 'Installer')]
    [string]$Initiator,

    [ValidateRange(0, 65535)]
    [int]$PublicPort = 0,

    [ValidateRange(0, 65535)]
    [int]$BackendPort = 0,

    [switch]$MigrateV121SystemState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    [Console]::Error.WriteLine('ERROR: {0}', $_.Exception.Message)
    exit 1
}

# This script is intentionally a medium-integrity protocol adapter. It must
# never contain privileged Tailscale, Firewall, Task Scheduler, process, or
# filesystem mutation logic. The ACL-protected compiled broker is the sole
# elevation boundary and independently derives the invoking SID from its pipe.
$installPathResolver = Join-Path $PSScriptRoot 'Resolve-SafeInstallRoot.ps1'
if (-not (Test-Path -LiteralPath $installPathResolver -PathType Leaf)) {
    throw "Required broker client not found: $installPathResolver"
}
. $installPathResolver

$response = Invoke-EverVigilSystemBroker `
    -Operation $Operation `
    -TransactionId ([guid]$TransactionId) `
    -Initiator $Initiator `
    -PublicPort $PublicPort `
    -BackendPort $BackendPort `
    -MigrateV121SystemState:$MigrateV121SystemState
$response | ConvertTo-Json -Compress -Depth 4
