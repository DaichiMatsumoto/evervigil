[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApplicationPath,
    [Parameter(Mandatory)][string]$BrokerExecutablePath,
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$AuditInstallerPath,
    [Parameter(Mandatory)][string]$AuditRoot,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$InstallerScriptPath,
    [Parameter(Mandatory)][string]$NoticePreviewPath,
    [Parameter(Mandatory)][string]$ExpectedIconPath,
    [Parameter(Mandatory)][string]$Version,
    [string[]]$DenySha256 = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WindowsExecutableResourceAudit.psm1') -Force
. (Join-Path $PSScriptRoot 'LegacyCompatibility.generated.ps1')

$auditAppId = 'A17D6AC4-2F11-45CF-A0BE-42C2F607F7B8'
$auditUninstallRegistryPath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{$auditAppId}_is1"
$resolvedAuditRoot = [IO.Path]::GetFullPath($AuditRoot).TrimEnd('\')
$resolvedReportPath = [IO.Path]::GetFullPath($ReportPath)
$resolvedReportParent = Split-Path -Parent $resolvedReportPath
$resolvedNoticePreviewPath = [IO.Path]::GetFullPath($NoticePreviewPath)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts')).TrimEnd('\')
if (-not $resolvedAuditRoot.StartsWith("$allowedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "AuditRoot must be inside '$allowedRoot'."
}
if (-not $resolvedReportPath.StartsWith("$allowedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "ReportPath must be inside '$allowedRoot'."
}
if (-not $resolvedNoticePreviewPath.StartsWith("$allowedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "NoticePreviewPath must be inside '$allowedRoot'."
}
if ([string]::Equals($resolvedAuditRoot, $allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'AuditRoot must not be the artifacts root itself.'
}
if (Test-Path -LiteralPath $auditUninstallRegistryPath) {
    throw "The dedicated resource-audit AppId is unexpectedly registered: $auditUninstallRegistryPath"
}

function Get-RegistryFingerprintLines {
    param([Parameter(Mandatory)][string[]]$Path)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @($Path | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $registryPath)) {
            $lines.Add("REG|$registryPath|MISSING")
            continue
        }
        $key = Get-Item -LiteralPath $registryPath -ErrorAction Stop
        $lines.Add("REG|$registryPath|PRESENT")
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $kind = $key.GetValueKind($name).ToString()
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $serialized = if ($value -is [Array]) {
                @($value | ForEach-Object { [string]$_ }) -join "`u{001f}"
            } elseif ($null -eq $value) {
                '<null>'
            } else {
                [string]$value
            }
            $lines.Add("VALUE|$registryPath|$name|$kind|$serialized")
        }
    }
    @($lines)
}

function Get-FileSurfaceFingerprintLines {
    param([Parameter(Mandatory)][string[]]$Path)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } |
            Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            $lines.Add("PATH|$candidate|MISSING")
            continue
        }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $lines.Add("PATH|$candidate|REPARSE|$($item.LinkType)|$($item.Target -join ',')")
            continue
        }
        if (-not $item.PSIsContainer) {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $lines.Add("FILE|$candidate|$($item.Length)|$hash")
            continue
        }
        $lines.Add("DIR|$candidate|PRESENT")
        foreach ($child in @(Get-ChildItem -LiteralPath $candidate -Force -Recurse -ErrorAction Stop |
                Sort-Object FullName)) {
            $relative = [IO.Path]::GetRelativePath($candidate, $child.FullName)
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $lines.Add("ENTRY|$candidate|$relative|REPARSE|$($child.LinkType)|$($child.Target -join ',')")
            } elseif ($child.PSIsContainer) {
                $lines.Add("ENTRY|$candidate|$relative|DIR")
            } else {
                $hash = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash
                $lines.Add("ENTRY|$candidate|$relative|FILE|$($child.Length)|$hash")
            }
        }
    }
    @($lines)
}

function Get-ProtectedHostSnapshot {
    $uninstallRegistry =
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D1ACB787-2308-4AC4-91BD-A6A3856E7AF0}_is1'
    $runRegistry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $installLocation = $null
    if (Test-Path -LiteralPath $uninstallRegistry) {
        $installLocation = (Get-ItemProperty -LiteralPath $uninstallRegistry -ErrorAction Stop).InstallLocation
    }
    $startupRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $programsRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $protectedPaths = @(
        $installLocation,
        (Join-Path $env:LOCALAPPDATA 'Programs\EverVigil'),
        (Join-Path $env:LOCALAPPDATA $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData),
        (Join-Path $env:LOCALAPPDATA 'EverVigil'),
        (Join-Path $env:LOCALAPPDATA $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData),
        (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall'),
        (Join-Path $env:LOCALAPPDATA $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData),
        (Join-Path $programsRoot 'EverVigil'),
        (Join-Path $programsRoot $script:LegacyCompatibilityApplicationProductName),
        (Join-Path $startupRoot 'EverVigil.lnk'),
        (Join-Path $startupRoot $script:LegacyCompatibilityApplicationStartupShortcutFileName)
    )
    $lines = @(
        Get-RegistryFingerprintLines -Path @($uninstallRegistry, $runRegistry)
        Get-FileSurfaceFingerprintLines -Path $protectedPaths
    ) | Sort-Object
    $json = ConvertTo-Json @($lines) -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    [pscustomobject]@{
        sha256 = $hash
        lines = @($lines)
    }
}

function Invoke-HiddenProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Process did not start: $FilePath"
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
        }
        $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Remove-AuditRootSafely {
    if (-not (Test-Path -LiteralPath $resolvedAuditRoot)) {
        return
    }
    $item = Get-Item -LiteralPath $resolvedAuditRoot -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Resource audit root is a reparse point and was not removed: $resolvedAuditRoot"
    }
    Remove-Item -LiteralPath $resolvedAuditRoot -Recurse -Force
}

$versionPattern = [regex]::Escape($Version)
$manifestVersionPattern = [regex]::Escape("$($Version.Split('-')[0]).0")
$report = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    version = $Version
    passed = $false
    dedicatedAuditAppId = $auditAppId
    auditRoot = $resolvedAuditRoot
    protectedHostBeforeSha256 = $null
    protectedHostAfterSha256 = $null
    protectedHostUnchanged = $false
    auditInstallExitCode = $null
    auditUninstallExitCode = $null
    cleanupComplete = $false
    artifacts = @()
    installerNotice = $null
    failures = @()
}
$failureMessages = [Collections.Generic.List[string]]::new()
$before = $null
$uninstallerPath = Join-Path $resolvedAuditRoot 'unins000.exe'

try {
    foreach ($requiredPath in @(
            $ApplicationPath,
            $BrokerExecutablePath,
            $InstallerPath,
            $AuditInstallerPath,
            $ExpectedIconPath,
            $InstallerScriptPath
        )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required resource-audit input was not found: $requiredPath"
        }
    }
    if (Test-Path -LiteralPath $resolvedAuditRoot) {
        Remove-AuditRootSafely
    }
    New-Item -ItemType Directory -Path $resolvedAuditRoot | Out-Null
    $before = Get-ProtectedHostSnapshot
    $report.protectedHostBeforeSha256 = $before.sha256

    $requiredLegalNotice = 'This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.'
    $installerSource = Get-Content -LiteralPath $InstallerScriptPath -Raw
    $noticeDefinition = '#define RequiredLegalNotice "' + $requiredLegalNotice + '"'
    $noticePagePattern = [regex]::new(
        "LegalNoticePage\s*:=\s*CreateOutputMsgMemoPage\(\s*" +
        "wpWelcome\s*,\s*CustomMessage\('LegalNoticeCaption'\)\s*,\s*" +
        "CustomMessage\('LegalNoticeDescription'\)\s*,\s*" +
        "CustomMessage\('LegalNoticeSubCaption'\)\s*,\s*" +
        "'\{#RequiredLegalNotice\}'\s*\);",
        [Text.RegularExpressions.RegexOptions]::Singleline)
    $definitionMatches = [regex]::Matches(
        $installerSource,
        [regex]::Escape($noticeDefinition)).Count
    $pageMatches = $noticePagePattern.Matches($installerSource).Count
    $report.installerNotice = [ordered]@{
        requiredText = $requiredLegalNotice
        exactDefinitionMatchCount = $definitionMatches
        pageConstructionMatchCount = $pageMatches
        pageType = 'TOutputMsgMemoWizardPage'
        insertionPoint = 'wpWelcome'
        placement = 'immediately after the Welcome page'
        screenshotGenerated = $false
        screenshotReason = 'The headless release audit does not automate installer UI input; page text and insertion position are verified from the compiled installer source contract.'
        textPreviewPath = $resolvedNoticePreviewPath
        passed = $definitionMatches -eq 1 -and $pageMatches -eq 1
    }
    if (-not $report.installerNotice.passed) {
        throw "Installer legal-notice page contract mismatch: definition=$definitionMatches, page=$pageMatches."
    }
    $previewText = @(
        'EverVigil installer legal notice preview (machine verified)'
        ''
        'Page type: TOutputMsgMemoWizardPage'
        'Position: immediately after the Welcome page (wpWelcome)'
        'Screenshot: not generated; headless UI automation was not treated as successful evidence.'
        ''
        $requiredLegalNotice
        ''
    ) -join "`n"
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedNoticePreviewPath) -Force | Out-Null
    [IO.File]::WriteAllText(
        $resolvedNoticePreviewPath,
        $previewText,
        [Text.UTF8Encoding]::new($false))

    $applicationAudit = Assert-EverVigilExecutableResources `
        -Path $ApplicationPath `
        -ArtifactKind Application `
        -ExpectedIconPath $ExpectedIconPath `
        -Version $Version `
        -DenySha256 $DenySha256 `
        -ExpectedVersionInfo @{
            ProductName = '\AEverVigil\z'
            CompanyName = '\ADaichi Matsumoto\z'
            FileVersion = "\A$manifestVersionPattern\z"
            ProductVersion = "\A$versionPattern\z"
            FileDescription = '\AEverVigil\z'
            OriginalFilename = '\AEverVigil\.exe\z'
        }
    $brokerAudit = Assert-EverVigilExecutableResources `
        -Path $BrokerExecutablePath `
        -ArtifactKind Broker `
        -ExpectedIconPath $ExpectedIconPath `
        -Version $Version `
        -ExpectedExecutionLevel asInvoker `
        -DenySha256 $DenySha256 `
        -ExpectedVersionInfo @{
            ProductName = '\AEverVigil\z'
            CompanyName = '\ADaichi Matsumoto\z'
            FileVersion = "\A$manifestVersionPattern\z"
            ProductVersion = "\A$versionPattern\z"
            FileDescription = '\AEverVigil fixed-operation privileged broker\.\z'
            OriginalFilename = '\AEverVigil\.Broker\.exe\z'
        }
    $installerAudit = Assert-EverVigilExecutableResources `
        -Path $InstallerPath `
        -ArtifactKind Installer `
        -ExpectedIconPath $ExpectedIconPath `
        -Version $Version `
        -DenySha256 $DenySha256 `
        -ExpectedVersionInfo @{
            ProductName = '\AEverVigil\z'
            CompanyName = '\ADaichi Matsumoto\z'
            FileVersion = "\A$manifestVersionPattern\z"
            ProductVersion = "\A$versionPattern\z"
            FileDescription = '\AEverVigil guided installer\z'
            OriginalFilename = "\AEverVigil-$versionPattern-Setup\.exe\z"
        }
    $report.artifacts = @($applicationAudit, $brokerAudit, $installerAudit)

    $report.auditInstallExitCode = Invoke-HiddenProcess `
        -FilePath ([IO.Path]::GetFullPath($AuditInstallerPath)) `
        -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            '/SP-',
            "/LOG=$(Join-Path $resolvedAuditRoot 'setup-audit.log')",
            "/DIR=$resolvedAuditRoot"
        ) `
        -TimeoutSeconds 120
    if ($report.auditInstallExitCode -ne 0) {
        throw "Dedicated resource-audit setup failed with exit code $($report.auditInstallExitCode)."
    }
    if (-not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)) {
        throw "Dedicated resource-audit setup did not generate unins000.exe: $uninstallerPath"
    }
    $auditPayloadPath = Join-Path $resolvedAuditRoot 'EverVigil.exe'
    if (-not (Test-Path -LiteralPath $auditPayloadPath -PathType Leaf)) {
        throw "Dedicated resource-audit setup did not install EverVigil.exe: $auditPayloadPath"
    }
    $sourceHash = (Get-FileHash -LiteralPath $ApplicationPath -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $auditPayloadPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($sourceHash, $installedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The resource-audit installation changed the EverVigil.exe payload.'
    }

    $uninstallerAudit = Assert-EverVigilExecutableResources `
        -Path $uninstallerPath `
        -ArtifactKind Uninstaller `
        -ExpectedIconPath $ExpectedIconPath `
        -Version $Version `
        -DenySha256 $DenySha256 `
        -ExpectedVersionInfo @{
            ProductName = '\AEverVigil\z'
            CompanyName = '\ADaichi Matsumoto\z'
            FileVersion = '\A51\.\d+\.0\.0\z'
            ProductVersion = "\A$versionPattern\z"
            FileDescription = '\ASetup/Uninstall\z'
            OriginalFilename = "\AEverVigil-$versionPattern-Setup\.exe\z"
        }
    $report.artifacts = @(
        $applicationAudit,
        $brokerAudit,
        $installerAudit,
        $uninstallerAudit)

    $report.auditUninstallExitCode = Invoke-HiddenProcess `
        -FilePath $uninstallerPath `
        -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            "/LOG=$(Join-Path $resolvedAuditRoot 'uninstall-audit.log')"
        ) `
        -TimeoutSeconds 120
    if ($report.auditUninstallExitCode -ne 0) {
        throw "Dedicated resource-audit uninstaller failed with exit code $($report.auditUninstallExitCode)."
    }
} catch {
    $failureMessages.Add($_.Exception.Message)
    if ($_.Exception.Data.Contains('AuditResult')) {
        $report.artifacts = @($report.artifacts) + @($_.Exception.Data['AuditResult'])
    }
} finally {
    try {
        for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $resolvedAuditRoot); $attempt++) {
            Start-Sleep -Milliseconds 250
        }
        if (Test-Path -LiteralPath $resolvedAuditRoot) {
            Remove-AuditRootSafely
        }
        $report.cleanupComplete = -not (Test-Path -LiteralPath $resolvedAuditRoot)
    } catch {
        $failureMessages.Add("Resource-audit cleanup failed: $($_.Exception.Message)")
    }
    try {
        if (Test-Path -LiteralPath $auditUninstallRegistryPath) {
            $failureMessages.Add(
                "Dedicated audit AppId unexpectedly touched ARP registration: $auditUninstallRegistryPath")
        }
        if ($before) {
            $after = Get-ProtectedHostSnapshot
            $report.protectedHostAfterSha256 = $after.sha256
            $report.protectedHostUnchanged = [string]::Equals(
                $before.sha256,
                $after.sha256,
                [StringComparison]::OrdinalIgnoreCase)
            if (-not $report.protectedHostUnchanged) {
                $difference = @(Compare-Object -ReferenceObject $before.lines -DifferenceObject $after.lines |
                        ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
                $failureMessages.Add(
                    "Protected existing install/registry/shortcut surfaces changed: $($difference -join ' | ')")
            }
        }
    } catch {
        $failureMessages.Add("Protected-host post-audit comparison failed: $($_.Exception.Message)")
    }
    $report.failures = @($failureMessages)
    $report.passed = $failureMessages.Count -eq 0 -and
        $report.cleanupComplete -and $report.protectedHostUnchanged -and
        $report.installerNotice.passed -and
        @($report.artifacts).Count -eq 4 -and
        @($report.artifacts | Where-Object { -not $_.passed }).Count -eq 0
    New-Item -ItemType Directory -Path $resolvedReportParent -Force | Out-Null
    [IO.File]::WriteAllText(
        $resolvedReportPath,
        (($report | ConvertTo-Json -Depth 20) + "`n"),
        [Text.UTF8Encoding]::new($false))
}

if (-not $report.passed) {
    throw "Release resource audit failed. See '$resolvedReportPath': $($failureMessages -join ' | ')"
}

"Release resource audit passed: $resolvedReportPath"
