[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'scripts\WindowsExecutableResourceAudit.psm1'
$auditScriptPath = Join-Path $repositoryRoot 'scripts\Invoke-ReleaseResourceAudit.ps1'
$buildScriptPath = Join-Path $repositoryRoot 'scripts\Build-Release.ps1'
$installerScriptPath = Join-Path $repositoryRoot 'installer\EverVigil.iss'
$iconPath = Join-Path $repositoryRoot 'src\EverVigil\Assets\evervigil-placeholder.ico'
$applicationPath = Join-Path $repositoryRoot 'src\EverVigil\bin\Release\net8.0-windows\EverVigil.exe'
$brokerPath = Join-Path `
    $repositoryRoot `
    'src\EverVigil.Broker\bin\Release\net8.0-windows\EverVigil.Broker.exe'

foreach ($requiredPath in @(
        $modulePath,
        $auditScriptPath,
        $buildScriptPath,
        $installerScriptPath,
        $iconPath,
        $applicationPath
        $brokerPath
    )) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Release resource-audit test prerequisite is missing: $requiredPath"
    }
}

Import-Module $modulePath -Force
$expectedSizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$iconFrames = @(Get-EverVigilIcoFrameInventory -Path $iconPath)
if ($iconFrames.Count -ne $expectedSizes.Count -or
    @(Compare-Object $expectedSizes @($iconFrames.Width)).Count -ne 0 -or
    @($iconFrames | Where-Object { $_.Sha256 -notmatch '\A[0-9A-F]{64}\z' }).Count -ne 0) {
    throw 'Placeholder ICO frame inventory is incomplete or malformed.'
}

$positive = Assert-EverVigilExecutableResources `
    -Path $applicationPath `
    -ArtifactKind Application `
    -ExpectedIconPath $iconPath `
    -Version 2.0.0 `
    -ExpectedVersionInfo @{
        ProductName = '\AEverVigil\z'
        CompanyName = '\ADaichi Matsumoto\z'
        FileVersion = '\A2\.0\.0\.0\z'
        ProductVersion = '\A2\.0\.0\z'
        FileDescription = '\AEverVigil\z'
        OriginalFilename = '\AEverVigil\.exe\z'
    }
if (-not $positive.passed -or
    $positive.iconResources.groupCount -lt 1 -or
    $positive.iconResources.iconCount -lt 9 -or
    -not $positive.iconResources.shellSelection.matchesPlaceholder) {
    throw 'Known-good application resource inventory did not pass.'
}

$brokerPositive = Assert-EverVigilExecutableResources `
    -Path $brokerPath `
    -ArtifactKind Broker `
    -ExpectedIconPath $iconPath `
    -Version 2.0.0 `
    -ExpectedExecutionLevel asInvoker `
    -ExpectedVersionInfo @{
        ProductName = '\AEverVigil\z'
        CompanyName = '\ADaichi Matsumoto\z'
        FileVersion = '\A2\.0\.0\.0\z'
        ProductVersion = '\A2\.0\.0\z'
        FileDescription = '\AEverVigil fixed-operation privileged broker\.\z'
        OriginalFilename = '\AEverVigil\.Broker\.exe\z'
    }
if (-not $brokerPositive.passed -or
    $brokerPositive.manifest.level -cne 'asInvoker' -or
    $brokerPositive.manifest.uiAccess -cne 'false' -or
    $brokerPositive.iconResources.groupCount -lt 1 -or
    $brokerPositive.iconResources.iconCount -lt 9 -or
    -not $brokerPositive.iconResources.shellSelection.matchesPlaceholder) {
    throw 'Known-good broker resources or asInvoker manifest did not pass.'
}

$brokerManifestNegativeRejected = $false
try {
    Assert-EverVigilExecutableResources `
        -Path $brokerPath `
        -ArtifactKind Broker `
        -ExpectedIconPath $iconPath `
        -Version 2.0.0 `
        -ExpectedExecutionLevel highestAvailable `
        -ExpectedVersionInfo @{ ProductName = '\AEverVigil\z' } | Out-Null
} catch {
    $brokerManifestNegativeRejected =
        $_.Exception.Message.Contains(
            'Manifest requestedExecutionLevel mismatch',
            [StringComparison]::Ordinal)
}
if (-not $brokerManifestNegativeRejected) {
    throw 'A broker manifest with the wrong expected execution level was not rejected.'
}

$brokerMetadataNegativeRejected = $false
try {
    Assert-EverVigilExecutableResources `
        -Path $brokerPath `
        -ArtifactKind Broker `
        -ExpectedIconPath $iconPath `
        -Version 2.0.0 `
        -ExpectedExecutionLevel asInvoker `
        -ExpectedVersionInfo @{ OriginalFilename = '\ANotEverVigil\.exe\z' } | Out-Null
} catch {
    $brokerMetadataNegativeRejected =
        $_.Exception.Message.Contains(
            'OriginalFilename mismatch',
            [StringComparison]::Ordinal)
}
if (-not $brokerMetadataNegativeRejected) {
    throw 'A broker with mismatched VersionInfo was not rejected.'
}

$brokerDenyIconHashRejected = $false
try {
    Assert-EverVigilExecutableResources `
        -Path $brokerPath `
        -ArtifactKind Broker `
        -ExpectedIconPath $iconPath `
        -Version 2.0.0 `
        -ExpectedExecutionLevel asInvoker `
        -DenySha256 (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash `
        -ExpectedVersionInfo @{ ProductName = '\AEverVigil\z' } | Out-Null
} catch {
    $brokerDenyIconHashRejected =
        $_.Exception.Message.Contains(
            'reconstructed RT_GROUP_ICON hash',
            [StringComparison]::OrdinalIgnoreCase)
}
if (-not $brokerDenyIconHashRejected) {
    throw 'A broker containing a deny-listed ICO resource was not rejected.'
}

$metadataNegativeRejected = $false
try {
    Assert-EverVigilExecutableResources `
        -Path $applicationPath `
        -ArtifactKind Application `
        -ExpectedIconPath $iconPath `
        -Version 2.0.0 `
        -ExpectedVersionInfo @{ ProductName = '\ANotEverVigil\z' } | Out-Null
} catch {
    $metadataNegativeRejected =
        $_.Exception.Message.Contains('ProductName mismatch', [StringComparison]::Ordinal)
}
if (-not $metadataNegativeRejected) {
    throw 'Negative VersionInfo fixture was not rejected.'
}

$denyIconHashRejected = $false
try {
    Assert-EverVigilExecutableResources `
        -Path $applicationPath `
        -ArtifactKind Application `
        -ExpectedIconPath $iconPath `
        -Version 2.0.0 `
        -DenySha256 (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash `
        -ExpectedVersionInfo @{ ProductName = '\AEverVigil\z' } | Out-Null
} catch {
    $denyIconHashRejected = $_.Exception.Message.Contains(
        'reconstructed RT_GROUP_ICON hash',
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $denyIconHashRejected) {
    throw 'Negative deny-listed ICO fixture was not rejected after RT_GROUP_ICON reconstruction.'
}

$fixtureRoot = Join-Path $env:TEMP "EverVigil.ResourceAudit.Tests-$PID-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $invalidExecutable = Join-Path $fixtureRoot 'missing-resources.exe'
    [IO.File]::WriteAllBytes($invalidExecutable, [byte[]](0x4D, 0x5A, 0x00, 0x00))
    $invalidPeRejected = $false
    try {
        Get-EverVigilExecutableIconInventory -Path $invalidExecutable | Out-Null
    } catch {
        $invalidPeRejected = $true
    }
    if (-not $invalidPeRejected) {
        throw 'Negative PE fixture without RT_GROUP_ICON/RT_ICON was not rejected.'
    }

    $wrongIconPath = Join-Path $fixtureRoot 'wrong-placeholder.ico'
    $wrongIconBytes = [IO.File]::ReadAllBytes($iconPath)
    if ($wrongIconBytes.Length -lt 100) {
        throw 'Placeholder ICO is unexpectedly too small for the negative fixture.'
    }
    $wrongIconBytes[$wrongIconBytes.Length - 1] = $wrongIconBytes[$wrongIconBytes.Length - 1] -bxor 0x01
    [IO.File]::WriteAllBytes($wrongIconPath, $wrongIconBytes)
    $wrongIconRejected = $false
    try {
        Assert-EverVigilExecutableResources `
            -Path $applicationPath `
            -ArtifactKind Application `
            -ExpectedIconPath $wrongIconPath `
            -Version 2.0.0 `
            -ExpectedVersionInfo @{ ProductName = '\AEverVigil\z' } | Out-Null
    } catch {
        $wrongIconRejected = $_.Exception.Message.Contains(
            'placeholder ICO frames',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $wrongIconRejected) {
        throw 'Negative icon-provenance fixture was not rejected.'
    }

    $brokerWrongIconRejected = $false
    try {
        Assert-EverVigilExecutableResources `
            -Path $brokerPath `
            -ArtifactKind Broker `
            -ExpectedIconPath $wrongIconPath `
            -Version 2.0.0 `
            -ExpectedExecutionLevel asInvoker `
            -ExpectedVersionInfo @{ ProductName = '\AEverVigil\z' } | Out-Null
    } catch {
        $brokerWrongIconRejected = $_.Exception.Message.Contains(
            'placeholder ICO frames',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $brokerWrongIconRejected) {
        throw 'A broker with icon resources differing from the expected placeholder was not rejected.'
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

$installerContent = Get-Content -LiteralPath $installerScriptPath -Raw
$buildContent = Get-Content -LiteralPath $buildScriptPath -Raw
$auditContent = Get-Content -LiteralPath $auditScriptPath -Raw
$moduleContent = Get-Content -LiteralPath $modulePath -Raw
if (-not $auditContent.Contains(
        ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }',
        [StringComparison]::Ordinal) -or
    $auditContent.IndexOf(
        ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }',
        [StringComparison]::Ordinal) -gt
    $auditContent.IndexOf(
        'Get-FileSurfaceFingerprintLines -Path $protectedPaths',
        [StringComparison]::Ordinal)) {
    throw 'The release resource audit must remove an absent install location before binding its protected path array.'
}
foreach ($requiredInstallerGuard in @(
        '#ifdef ResourceAuditBuild',
        'AppId={{{#ResourceAuditAppId}}',
        'CreateUninstallRegKey=no',
        'UninstallFilesDir={app}',
        'Source: "{#PackageRoot}\payload\EverVigil.exe"; DestDir: "{app}"',
        '#ifndef ResourceAuditBuild'
        'UsePreviousAppDir=no'
        'PreviousInstallRoot := PreviousInstallDirectory;'
        "' -PreviousInstallRoot '"
    )) {
    if (-not $installerContent.Contains($requiredInstallerGuard, [StringComparison]::Ordinal)) {
        throw "Resource-audit Inno guard is missing: $requiredInstallerGuard"
    }
}
$expectedUninstallSupportSources = @(
    'Source: "{#PackageRoot}\Uninstall.ps1"; DestDir: "{#MySupportRoot}\Support"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\Complete-InstallTransaction.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\InstallTransactionData.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\Invoke-InteractiveUserTask.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\Invoke-SystemMaintenance.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\LegacyCompatibility.generated.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
    'Source: "{#PackageRoot}\scripts\Resolve-SafeInstallRoot.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion'
)
$actualUninstallSupportSources = @(
    [regex]::Matches(
        $installerContent,
        '(?m)^Source: .*DestDir: "\{#MySupportRoot\}\\Support(?:\\scripts)?"; Flags: ignoreversion$') |
        ForEach-Object { $_.Value })
if ($actualUninstallSupportSources.Count -ne
        $expectedUninstallSupportSources.Count -or
    @(Compare-Object `
            $expectedUninstallSupportSources `
            $actualUninstallSupportSources `
            -CaseSensitive).Count -ne 0) {
    throw 'The resource-audit source does not contain the exact seven-file uninstall-support manifest.'
}
foreach ($requiredBuildGuard in @(
        '/DResourceAuditBuild=1',
        '/DResourceAuditAppId=A17D6AC4-2F11-45CF-A0BE-42C2F607F7B8',
        'Invoke-ReleaseResourceAudit.ps1',
        'resource-audit-report.json'
        'installer-notice-preview.txt'
        '-BrokerExecutablePath $publishedBroker'
    )) {
    if (-not $buildContent.Contains($requiredBuildGuard, [StringComparison]::Ordinal)) {
        throw "Release-build resource-audit guard is missing: $requiredBuildGuard"
    }
}
foreach ($requiredAuditGuard in @(
        'Get-ProtectedHostSnapshot',
        "(Join-Path `$env:LOCALAPPDATA 'EverVigil')",
        'LegacyCompatibilityApplicationDataRootRelativeToLocalAppData',
        'protectedHostUnchanged',
        'Assert-EverVigilExecutableResources',
        'Icon.ExtractAssociatedIcon',
        'unins000.exe',
        'setup-audit.log',
        'uninstall-audit.log',
        'cleanupComplete',
        'installerNotice',
        "insertionPoint = 'wpWelcome'",
        'screenshotGenerated = $false',
        'ConvertTo-Json -Depth 20'
        '[Parameter(Mandatory)][string]$BrokerExecutablePath'
        '-ArtifactKind Broker'
        '-ExpectedExecutionLevel asInvoker'
        "OriginalFilename = '\AEverVigil\.Broker\.exe\z'"
        '@($report.artifacts).Count -eq 4'
        'Get-EverVigilExecutableManifestAudit'
        'requestedExecutionLevel'
        'RT_MANIFEST'
    )) {
    if (-not ($auditContent + $moduleContent).Contains(
            $requiredAuditGuard,
            [StringComparison]::Ordinal)) {
        throw "Release resource-audit implementation guard is missing: $requiredAuditGuard"
    }
}

'Release resource-audit tests passed: application/broker native icons, VersionInfo, broker asInvoker manifest, exact uninstall-support manifest, negative fixtures, isolated audit setup contract, and JSON evidence contract are present.'
