[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-WindowsManifestVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $coreVersion = ($Version -split '[-+]', 2)[0]
    if ($coreVersion -cnotmatch '\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
        throw "Project version '$Version' does not have a three-part numeric core version."
    }

    return "$coreVersion.0"
}

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()
$requiredLegalNotice = 'This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.'
$manifestVersionCases = @(
    [pscustomobject]@{ Project = '1.2.3'; Expected = '1.2.3.0' }
    [pscustomobject]@{ Project = '1.2.3-alpha.1'; Expected = '1.2.3.0' }
    [pscustomobject]@{ Project = '1.2.3+build.4'; Expected = '1.2.3.0' }
    [pscustomobject]@{ Project = '1.2.3-rc.1+build.4'; Expected = '1.2.3.0' }
)
foreach ($manifestVersionCase in $manifestVersionCases) {
    $actualManifestVersion = ConvertTo-WindowsManifestVersion -Version $manifestVersionCase.Project
    if ($actualManifestVersion -cne $manifestVersionCase.Expected) {
        $failures.Add(
            "Project version '$($manifestVersionCase.Project)' must map to manifest version " +
            "'$($manifestVersionCase.Expected)', not '$actualManifestVersion'.")
    }
}

$requiredFiles = @(
    'EverVigil.sln'
    'Install.ps1'
    'Uninstall.ps1'
    'README.md'
    'SECURITY.md'
    'LICENSE'
    'NOTICE.md'
    'THIRD-PARTY-NOTICES.md'
    'RELEASE_NOTES.md'
    'global.json'
    'Directory.Build.props'
    'NuGet.config'
    '.github\release-host-lock.json'
    '.github\release-source-manifest.json'
    'installer\EverVigil.iss'
    'licenses\INNO-SETUP-LICENSE.txt'
    'licenses\QRCODER-LICENSE.txt'
    '.gitignore'
    'docs\README.ja.md'
    'docs\README.en.md'
    'docs\REFERENCE.ja.md'
    'docs\REFERENCE.en.md'
    'docs\SECURITY.ja.md'
    'docs\SECURITY.en.md'
    'scripts\Build-Release.ps1'
    'scripts\Compile-WindowsResource.ps1'
    'scripts\Complete-InstallTransaction.ps1'
    'scripts\Export-InstallerPayload.ps1'
    'scripts\InstallTransactionData.ps1'
    'scripts\Invoke-InteractiveUserTask.ps1'
    'scripts\Invoke-ReleaseResourceAudit.ps1'
    'scripts\Invoke-SystemMaintenance.ps1'
    'scripts\New-PlaceholderIcon.ps1'
    'scripts\Resolve-InnoCompiler.ps1'
    'scripts\Resolve-SafeInstallRoot.ps1'
    'scripts\Test-NuGetVulnerabilities.ps1'
    'scripts\Test-PublicRelease.ps1'
    'scripts\Test-ReleaseVersion.ps1'
    'scripts\WindowsExecutableResourceAudit.psm1'
    'src\EverVigil.Core\EverVigil.Core.csproj'
    'src\EverVigil.Core\packages.lock.json'
    'src\EverVigil.Core\Localization\AppLocalizer.cs'
    'src\EverVigil.Core\Localization\AppResources.resx'
    'src\EverVigil.Core\Localization\AppResources.ja.resx'
    'src\EverVigil.Broker.Protocol\EverVigil.Broker.Protocol.csproj'
    'src\EverVigil.Broker.Protocol\packages.lock.json'
    'src\EverVigil.Broker.Protocol\TailscaleServeStatus.cs'
    'src\EverVigil.Broker\EverVigil.Broker.csproj'
    'src\EverVigil.Broker\packages.lock.json'
    'src\EverVigil.Broker\app.manifest'
    'src\EverVigil.Broker\BrokerJsonContext.cs'
    'src\EverVigil.Broker\NativeComDispatch.cs'
    'src\EverVigil.Broker\NativeLibraryPolicy.cs'
    'src\EverVigil\EverVigil.csproj'
    'src\EverVigil\packages.lock.json'
    'src\EverVigil\EverVigil.rc'
    'src\EverVigil\ApplicationMetadata.cs'
    'src\EverVigil\Assets\evervigil-placeholder-source.png'
    'src\EverVigil\Assets\evervigil-placeholder.ico'
    'src\EverVigil\Program.cs'
    'src\EverVigil\Services\BridgeProcessEnvironment.cs'
    'src\EverVigil\Services\BridgeLauncher.cs'
    'src\EverVigil\Services\ManagedBridgeProcess.cs'
    'src\EverVigil\Services\SupervisorEngine.cs'
    'src\EverVigil\Infrastructure\AsyncRestartSignal.cs'
    'src\EverVigil\Infrastructure\ProcessCommandRunner.cs'
    'src\EverVigil\Infrastructure\PendingSystemConfigurationStore.cs'
    'src\EverVigil\Infrastructure\ProtectedTailscaleIdentityStore.cs'
    'src\EverVigil\Infrastructure\WindowsJobObject.cs'
    'src\EverVigil\Services\PrivilegedBrokerClient.cs'
    'src\EverVigil\Services\SystemConfigurationService.cs'
    'src\EverVigil\UI\CyberPanel.cs'
    'src\EverVigil\UI\CyberTabControl.cs'
    'src\EverVigil\UI\DashboardForm.cs'
    'tests\EverVigil.Tests\EverVigil.Tests.csproj'
    'tests\EverVigil.Tests\packages.lock.json'
    'tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj'
    'tests\EverVigil.Broker.Tests\packages.lock.json'
    'tests\EverVigil.Broker.Tests\Program.cs'
    'tests\Test-ExternalInstallTransaction.ps1'
    'tests\Test-InnoCompiler.ps1'
    'tests\Test-InstallTransaction.ps1'
    'tests\Test-ProductionInstallerAuditReport.ps1'
    'tests\Test-ReleaseResourceAudit.ps1'
    'tests\Test-ReleaseHost.ps1'
    'tests\ReleasePathIsolation.ps1'
    'tests\Invoke-ReleaseShell.cmd'
    'tests\Test-SystemMaintenance.ps1'
    '.github\workflows\release.yml'
    '.github\workflows\validate.yml'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relativePath))) {
        $failures.Add("Missing required file: $relativePath")
    }
}

$bridgeLauncherContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\BridgeLauncher.cs') `
    -Raw
if (-not $bridgeLauncherContent.Contains(
        'process.StandardOutput.BaseStream.CopyToAsync(Stream.Null)',
        [StringComparison]::Ordinal) -or
    -not $bridgeLauncherContent.Contains(
        'process.StandardError.BaseStream.CopyToAsync(Stream.Null)',
        [StringComparison]::Ordinal) -or
    $bridgeLauncherContent.Contains(
        'process.StandardOutput.BaseStream.CopyToAsync(launcherOutput)',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Credential-bearing Even Terminal output, including its QR banner, must be drained without logging.')
}

$managedBridgeContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\ManagedBridgeProcess.cs') `
    -Raw
$bridgeEnvironmentContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\BridgeProcessEnvironment.cs') `
    -Raw
$jobObjectContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\WindowsJobObject.cs') `
    -Raw
foreach ($ownershipGuard in @(
        'GetNamedPipeClientProcessId',
        'RequirePipeClientProcess(pidPipe, launcherProcess.Id)',
        'job.Contains(process)',
        'IsProcessInJob')) {
    if (-not ($managedBridgeContent + $jobObjectContent).Contains(
            $ownershipGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Bridge child-process ownership guard is missing: $ownershipGuard")
    }
}
foreach ($bridgeEnvironmentGuard in @(
        'BridgeProcessEnvironment.ConfigureLauncher(startInfo, settings, token);'
        'BridgeProcessEnvironment.ConfigureBridgeChild('
        'startInfo.Environment.Clear();'
        'ApplicationVariableNames.ToDictionary('
        'TokenUtility.IsValid('
        'BuildExecutablePath(settings, environment)'
        'AllowedVariableNames.Contains(name)'
        '["BRIDGE_TOKEN"] = token'
        '["DEFAULT_PROVIDER"] = "codex"'
        '["EVEN_HOST_MODE"] = "tailscale"'
    )) {
    if (-not ($managedBridgeContent + $bridgeLauncherContent + $bridgeEnvironmentContent).Contains(
            $bridgeEnvironmentGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Bridge credential-environment guard is missing: $bridgeEnvironmentGuard")
    }
}
foreach ($forbiddenBridgeParentCredential in @(
        'OPENAI_API_KEY'
        'GH_TOKEN'
        'CODEX_HOME'
    )) {
    if ($bridgeEnvironmentContent.Contains(
            $forbiddenBridgeParentCredential,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add(
            "Bridge production code must not inherit a parent credential environment entry: $forbiddenBridgeParentCredential")
    }
}

$englishResourcePath = Join-Path $RepositoryRoot `
    'src\EverVigil.Core\Localization\AppResources.resx'
$japaneseResourcePath = Join-Path $RepositoryRoot `
    'src\EverVigil.Core\Localization\AppResources.ja.resx'
if ((Test-Path -LiteralPath $englishResourcePath) -and
    (Test-Path -LiteralPath $japaneseResourcePath)) {
    $englishResources = [xml](Get-Content -LiteralPath $englishResourcePath -Raw -Encoding UTF8)
    $japaneseResources = [xml](Get-Content -LiteralPath $japaneseResourcePath -Raw -Encoding UTF8)
    $englishValues = @{}
    $japaneseValues = @{}
    foreach ($entry in $englishResources.root.data) {
        $englishValues[[string]$entry.name] = [string]$entry.value
    }
    foreach ($entry in $japaneseResources.root.data) {
        $japaneseValues[[string]$entry.name] = [string]$entry.value
    }
    $resourceDifference = Compare-Object `
        -ReferenceObject @($englishValues.Keys) `
        -DifferenceObject @($japaneseValues.Keys)
    if ($resourceDifference) {
        $failures.Add('English and Japanese application resource keys must match exactly.')
    }
    if ($englishValues.Count -lt 120 -or
        @($englishValues.Values).Where({ [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($japaneseValues.Values).Where({ [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $failures.Add('Application localization resources must be complete and non-empty.')
    }
    foreach ($localizedNotice in @(
            [pscustomobject]@{ Language = 'English'; Value = $englishValues['AboutCommunityNotice'] }
            [pscustomobject]@{ Language = 'Japanese'; Value = $japaneseValues['AboutCommunityNotice'] }
        )) {
        if (-not [string]::Equals(
                [string]$localizedNotice.Value,
                $requiredLegalNotice,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "$($localizedNotice.Language) About notice must preserve the required English text exactly.")
        }
    }
}

foreach ($noticeSurface in @(
        [pscustomobject]@{ Path = 'README.md'; MaximumIndex = 2048 }
        [pscustomobject]@{ Path = 'RELEASE_NOTES.md'; MaximumIndex = 2048 }
    )) {
    $noticeSurfaceContent = Get-Content `
        -LiteralPath (Join-Path $RepositoryRoot $noticeSurface.Path) `
        -Raw
    $noticeIndex = $noticeSurfaceContent.IndexOf(
        $requiredLegalNotice,
        [StringComparison]::Ordinal)
    if ($noticeIndex -lt 0 -or $noticeIndex -gt $noticeSurface.MaximumIndex) {
        $failures.Add(
            "$($noticeSurface.Path) must contain the exact required legal notice near its beginning.")
    }
}
$releaseNotesContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'RELEASE_NOTES.md') `
    -Raw
$installerHashPlaceholder = '{{EVERVIGIL_INSTALLER_SHA256}}'
if ([regex]::Matches(
        $releaseNotesContent,
        [regex]::Escape($installerHashPlaceholder)).Count -ne 1 -or
    [regex]::Matches(
        $releaseNotesContent,
        '(?m)^## SHA-256$').Count -ne 1 -or
    $releaseNotesContent.Contains(
        'No installer hash is claimed',
        [StringComparison]::Ordinal) -or
    $releaseNotesContent.Contains(
        'must be inserted',
        [StringComparison]::OrdinalIgnoreCase)) {
    $failures.Add(
        'RELEASE_NOTES.md must contain one replaceable installer hash placeholder and no contradictory pending-hash text.')
}

foreach ($networkLimitationDocument in @(
        'README.md'
        'RELEASE_NOTES.md'
        'docs\README.en.md'
        'docs\README.ja.md'
        'docs\SECURITY.en.md'
        'docs\SECURITY.ja.md'
        'docs\TECHNICAL_OVERVIEW.en.md'
        'docs\TECHNICAL_OVERVIEW.ja.md'
    )) {
    $networkLimitationContent = Get-Content `
        -LiteralPath (Join-Path $RepositoryRoot $networkLimitationDocument) `
        -Raw `
        -Encoding UTF8
    if (-not $networkLimitationContent.Contains('0.0.0.0', [StringComparison]::Ordinal) -or
        -not $networkLimitationContent.Contains('loopback-only', [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add(
            "$networkLimitationDocument must disclose the tested upstream wildcard-bind limitation.")
    }
}

$noticeContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'NOTICE.md') `
    -Raw `
    -Encoding UTF8
foreach ($placeholderProvenanceGuard in @(
        '## Original icon artwork'
        "It is the project's adopted icon"
        'It is not derived from, traced from, or based on any Even Realities artwork.'
        'src/EverVigil/Assets/evervigil-placeholder-source.png'
        'src/EverVigil/Assets/evervigil-placeholder.ico'
        'Application, tray, installer, uninstaller, and About surfaces use this single'
    )) {
    if (-not $noticeContent.Contains(
            $placeholderProvenanceGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Original icon provenance notice is missing: $placeholderProvenanceGuard")
    }
}

& (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
    -RepositoryRoot $RepositoryRoot | Out-Null

$publicReleaseScannerContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
    -Raw
if ($publicReleaseScannerContent.Contains('[Environment]::UserName', [StringComparison]::Ordinal) -or
    $publicReleaseScannerContent.Contains('[Environment]::MachineName', [StringComparison]::Ordinal) -or
    $publicReleaseScannerContent.Contains('SkipExplicitDeny', [StringComparison]::Ordinal) -or
    -not $publicReleaseScannerContent.Contains(
        '$explicitDenyValues = @($fixedBrandDenyValues + $DenyValue)',
        [StringComparison]::Ordinal) -or
    -not $publicReleaseScannerContent.Contains('$fixedBrandDenyValues', [StringComparison]::Ordinal) -or
    -not $publicReleaseScannerContent.Contains('$fixedBrandDenySha256', [StringComparison]::Ordinal) -or
    -not $publicReleaseScannerContent.Contains('[string[]]$DenySha256 = @()', [StringComparison]::Ordinal) -or
    -not $publicReleaseScannerContent.Contains('Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256', [StringComparison]::Ordinal)) {
    $failures.Add('Release contamination identifiers must be explicit and scanned in every binary.')
}
$releaseBuildContentForHashScan = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Build-Release.ps1') `
    -Raw
if ([regex]::Matches(
        $releaseBuildContentForHashScan,
        '-DenySha256\s+\$brandDenySha256').Count -lt 5) {
    $failures.Add('Every source/package/publish/installer resource scan must receive the brand SHA-256 deny-list.')
}
if (-not $publicReleaseScannerContent.Contains(
        "'scripts\InstallTransactionData.ps1'",
        [StringComparison]::Ordinal)) {
    $failures.Add('The release package allowlist must include InstallTransactionData.ps1.')
}

$scannerFixtureRoot = Join-Path $env:TEMP "EverVigil.Scanner-$PID-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $scannerFixtureRoot | Out-Null
    $scannerScenarios = @(
        [pscustomobject]@{
            Name = 'Unix profile paths inside Markdown backticks'
            FileName = 'sample.md'
            Content = 'Private path: `/' + 'home/example/project`'
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'forward-slash Windows profile paths'
            FileName = 'sample.md'
            Content = 'Private path: C:' + [char]47 + 'Users/example/project'
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'short explicit deny values'
            FileName = 'sample.md'
            Content = 'Private identifier: dev'
            DenyValue = @('dev')
        }
        [pscustomobject]@{
            Name = 'fine-grained GitHub access tokens'
            FileName = 'sample.md'
            Content = 'Credential: github' + '_pat_' + ('A' * 24)
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'legacy generic OpenAI API keys'
            FileName = 'sample.md'
            Content = 'Credential: sk' + '-' + ('A' * 48)
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'credential-bearing environment files'
            FileName = '.env'
            Content = 'GITHUB_TOKEN=gh' + 'p_' + ('A' * 24)
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'JSON Even Terminal access tokens'
            FileName = 'sample.json'
            Content = '{"token": "' + ('a' * 32) + '"}'
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'YAML Even Terminal access tokens'
            FileName = 'sample.yaml'
            Content = 'token: ' + ('b' * 32)
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'private paths inside application manifests'
            FileName = 'app.manifest'
            Content = '<path>C:' + [char]47 + 'Users/example/private</path>'
            DenyValue = @()
        }
        [pscustomobject]@{
            Name = 'built-in prohibited legacy brand references'
            FileName = 'sample.md'
            Content = 'Do not retain the ' + 'official ' + 'Even Realities icon'
            DenyValue = @()
        }
    )
    foreach ($scenario in $scannerScenarios) {
        $scenarioRoot = Join-Path $scannerFixtureRoot ([Guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
            Set-Content `
                -LiteralPath (Join-Path $scenarioRoot $scenario.FileName) `
                -Value $scenario.Content `
                -Encoding UTF8
            $scannerArguments = @{
                RepositoryRoot = $scenarioRoot
                ErrorAction = 'SilentlyContinue'
            }
            if ($scenario.DenyValue.Count -gt 0) {
                $scannerArguments.DenyValue = $scenario.DenyValue
            }
            $scannerRejectedValue = $false
            try {
                & (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') @scannerArguments |
                    Out-Null
            } catch {
                $scannerRejectedValue = $true
            }
            if (-not $scannerRejectedValue) {
                $failures.Add("Release contamination scan must reject $($scenario.Name).")
            }
        } finally {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $binaryPublishRoot = Join-Path $scannerFixtureRoot 'binary-publish'
    New-Item -ItemType Directory -Path $binaryPublishRoot | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $binaryPublishRoot 'ThirdParty.Dependency.dll'),
        [Text.Encoding]::ASCII.GetBytes(
            'dependency header private-dependency-marker dependency footer'))
    $binaryDenyRejected = $false
    $binaryScanErrors = @()
    try {
        & (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
            -PublishRoot $binaryPublishRoot `
            -DenyValue 'private-dependency-marker' `
            -ErrorVariable +binaryScanErrors `
            -ErrorAction SilentlyContinue |
            Out-Null
    } catch {
        $binaryDenyRejected = $true
        $binaryScanErrors += $_
    }
    if (-not $binaryDenyRejected) {
        $failures.Add('Release contamination scan must apply explicit deny values to every publish binary.')
    }
    if (($binaryScanErrors | Out-String).Contains(
            'private-dependency-marker',
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add('Release contamination diagnostics must not disclose explicit deny values.')
    }

    $singleFilePublishRoot = Join-Path $scannerFixtureRoot 'single-file-publish'
    New-Item -ItemType Directory -Path $singleFilePublishRoot | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $singleFilePublishRoot 'EverVigil.Broker.exe'),
        [Text.Encoding]::ASCII.GetBytes('reviewed single-file native publish fixture'))
    try {
        & (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
            -PublishRoot $singleFilePublishRoot |
            Out-Null
    } catch {
        $failures.Add(
            "Release contamination scan rejected a valid single-file publish tree: $($_.Exception.Message)")
    }

    $binaryBrandPath = Join-Path $binaryPublishRoot 'LegacyBrand.Dependency.dll'
    [IO.File]::WriteAllBytes(
        $binaryBrandPath,
        [Text.Encoding]::Unicode.GetBytes(
            'binary header ' + 'Official ' + 'logo' + ' binary footer'))
    $binaryBrandRejected = $false
    try {
        & (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
            -PublishRoot $binaryPublishRoot `
            -ErrorAction SilentlyContinue |
            Out-Null
    } catch {
        $binaryBrandRejected = $true
    }
    if (-not $binaryBrandRejected) {
        $failures.Add('Release contamination scan must reject built-in legacy brand references in publish binaries.')
    }

    $hashPublishRoot = Join-Path $scannerFixtureRoot 'hash-publish'
    New-Item -ItemType Directory -Path $hashPublishRoot | Out-Null
    $hashFixturePath = Join-Path $hashPublishRoot 'opaque-resource.bin'
    [IO.File]::WriteAllBytes(
        $hashFixturePath,
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(257))
    $fixtureDigest = (Get-FileHash -LiteralPath $hashFixturePath -Algorithm SHA256).Hash
    $hashDenyRejected = $false
    $hashScanErrors = @()
    try {
        & (Join-Path $RepositoryRoot 'scripts\Test-PublicRelease.ps1') `
            -PublishRoot $hashPublishRoot `
            -DenySha256 $fixtureDigest `
            -ErrorVariable +hashScanErrors `
            -ErrorAction SilentlyContinue |
            Out-Null
    } catch {
        $hashDenyRejected = $true
        $hashScanErrors += $_
    }
    if (-not $hashDenyRejected) {
        $failures.Add('Release contamination scan must reject an exact deny-listed file SHA-256.')
    }
    if (($hashScanErrors | Out-String).Contains(
            $fixtureDigest,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add('Release contamination diagnostics must not disclose deny-listed SHA-256 values.')
    }
} finally {
    Remove-Item -LiteralPath $scannerFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$validateWorkflowContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\validate.yml') `
    -Raw
foreach ($versionOutputGuard in @(
        'id: release'
        'version=$version'
        'EverVigil-${{ steps.release.outputs.version }}-Setup'
        'EverVigil-${{ steps.release.outputs.version }}-Setup.exe'
        '.\tests\Test-InnoCompiler.ps1'
        '.\tests\Test-InstallTransaction.ps1'
        '.\tests\Test-ReleaseResourceAudit.ps1'
        '--configfile .\NuGet.config'
        '--packages $env:NUGET_PACKAGES'
        '--locked-mode'
        '-r win-x64'
        '-p:RestoreBuildInParallel=false'
        '-p:RestoreConfigFile=$env:GITHUB_WORKSPACE\NuGet.config'
        '-p:RestorePackagesPath=$env:NUGET_PACKAGES'
        '-p:RestoreSources=https://api.nuget.org/v3/index.json'
        '-p:RestoreFallbackFolders='
        '-p:RestoreAdditionalProjectSources='
        '-p:RestoreAdditionalProjectFallbackFolders='
        '-p:ContinuousIntegrationBuild=true'
        'dotnet run --project .\tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj -c Release --no-build'
        '.\scripts\Build-Release.ps1 -Version $version -BrokerTestSkipPolicy Report'
    )) {
    if (-not $validateWorkflowContent.Contains($versionOutputGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Validate artifact version output guard is missing: $versionOutputGuard")
    }
}

$releaseWorkflowContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\release.yml') `
    -Raw
foreach ($releaseGuard in @(
        'workflow_dispatch:'
        'approval_phrase:'
        'CREATE PRIVATE DRAFT RC'
        'github.event.repository.private'
        "github.event.repository.default_branch == 'main'"
        "github.ref == 'refs/heads/main'"
        'group: evervigil-release'
        'labels: [self-hosted, Windows, X64, ephemeral, windows-11-pro, tailscale-pinned]'
        'persist-credentials: false'
        'C:\Program Files\EverVigil Release Host\Invoke-ReleaseShell.cmd'
        '.\tests\Test-ReleaseHost.ps1'
        '.\.github\release-host-lock.json'
        'contents: read'
        'contents: write'
        "environment: private-release-candidate"
        'id: release'
        '.\scripts\Test-ReleaseVersion.ps1 -Version $requestedVersion'
        'version=$version'
        '- validate-private-candidate'
        '$event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json'
        '$requestedVersion = [string]$event.inputs.version'
        'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
        'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
        'candidate-manifest.json'
        'candidate-manifest-sha256: ${{ steps.release.outputs.candidate-manifest-sha256 }}'
        'installer-sha256: ${{ steps.release.outputs.installer-sha256 }}'
        'report-sha256: ${{ steps.audit.outputs.report-sha256 }}'
        'The downloaded candidate manifest does not match the validation job output.'
        'A downloaded production audit report does not match its audit job output.'
        'release-host-evidence.json'
        '$powerShellPath = [string]$lock.powerShell.hostPath'
        '$resourceCompilerPath = [string]$lock.windowsResourceCompiler.compilerPath'
        '-p:EverVigilPowerShellPath=$powerShellPath'
        '-p:EverVigilResourceCompilerPath=$resourceCompilerPath'
        '--configfile .\NuGet.config'
        '--packages $env:NUGET_PACKAGES'
        '--locked-mode'
        '-r win-x64'
        '-p:RestoreBuildInParallel=false'
        '-p:RestoreConfigFile=$env:GITHUB_WORKSPACE\NuGet.config'
        '-p:RestorePackagesPath=$env:NUGET_PACKAGES'
        '-p:RestoreSources=https://api.nuget.org/v3/index.json'
        '-p:RestoreFallbackFolders='
        '-p:RestoreAdditionalProjectSources='
        '-p:RestoreAdditionalProjectFallbackFolders='
        '-p:ContinuousIntegrationBuild=true'
        '[string]$releaseCriticalSourceContents[''.\tests\ReleasePathIsolation.ps1'']'
        'The release-build working directory must exactly match GITHUB_WORKSPACE.'
        'Assert-EverVigilDirectoryOutside'
        'Assert-EverVigilReleaseStateDirectorySecurity'
        'New-EverVigilFreshIsolatedRoot'
        'Lock-EverVigilDirectoryAncestries'
        'New-EverVigilDirectorySentinelLocks'
        'New-EverVigilSourceTreeLocks'
        'Assert-EverVigilSourceTreeLockState'
        'Close-EverVigilSourceTreeLocks'
        'Assert-EverVigilGeneratedOutputTreeState'
        'Assert-EverVigilReleaseIsolationState'
        'Assert-NoEverVigilSourceNuGetMigrationState'
        'Close-EverVigilDirectorySentinelLocks'
        'Close-EverVigilDirectoryLocks'
        '$releaseCriticalSourceLocks'
        '$releaseCriticalSourceHashes'
        '$releaseCriticalSourceContents'
        '$releaseSourceManifest'
        '$sourceManifestEntries'
        '$heldSourceFiles'
        'The reviewed source lock set does not exactly match the release source manifest.'
        'A reviewed source hash does not match the release source manifest:'
        '[Security.Cryptography.SHA256]::HashData($criticalSourceBytes)'
        '[ScriptBlock]::Create('
        '$releaseSourceTreeLocks'
        '$releaseArtifactFileLocks'
        '-ExcludedRootNames @(''.git'', ''artifacts'')'
        '$dependencyRootIdentity'
        '$releaseFailure = $null'
        'Release isolation cleanup also failed:'
        'Remove-Item -LiteralPath $dependencyRoot -Recurse -Force -ErrorAction Stop'
        '$isolatedUserProfile = Join-Path $dependencyRoot ''user-profile'''
        'APPDATA = Join-Path $isolatedUserProfile ''AppData\Roaming'''
        'LOCALAPPDATA = Join-Path $isolatedUserProfile ''AppData\Local'''
        'USERPROFILE = $isolatedUserProfile'
        '''NUGET_PLUGIN_PATHS'''
        '''NUGET_NETCORE_PLUGIN_PATHS'''
        '''NUGET_NETFX_PLUGIN_PATHS'''
        '$pluginPathVariable,'
        ''';'','
        'NuGet migration state was not isolated as a regular empty marker.'
        'NuGet migration state escaped into the reviewed source checkout.'
        '-p:DirectoryBuildPropsPath=$env:GITHUB_WORKSPACE\Directory.Build.props'
        'dotnet restore failed with exit code'
        'dotnet build failed with exit code'
        '.\tests\Test-InnoCompiler.ps1'
        '.\tests\Test-InstallTransaction.ps1'
        '.\tests\Test-ReleaseResourceAudit.ps1'
        'EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj -c Release --no-build -- --fail-on-skip'
        '-BrokerTestSkipPolicy RequireNone'
        '-InnoCompilerPath $innoCompilerPath'
        '-PowerShellPath $powerShellPath'
        '-ResourceCompilerPath $resourceCompilerPath'
        '-RequireTrustedToolchain'
        'dotnet format failed with exit code'
        'test run failed with exit code'
        '.\scripts\Test-NuGetVulnerabilities.ps1 -SolutionPath .\EverVigil.sln'
        'EverVigil-$version-Setup.exe'
        '$checksumLines.Count -ne 1'
        '''\A(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)\z'''
        '$checksumMatch.Groups[''name''].Value -cne $installerName'
        'Get-FileHash $installerPath -Algorithm SHA256'
        '$checksumPlaceholder = ''{{EVERVIGIL_INSTALLER_SHA256}}'''
        '$releaseNotesTemplate.Replace($checksumPlaceholder, $checksum)'
        'RELEASE_NOTES.md has not been advanced to the requested release version.'
        'RELEASE_NOTES.md contains a stale installer basename.'
        '$requiredLegalNotice = ''This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.'''
        '$releaseNotes.Contains($requiredLegalNotice, [StringComparison]::Ordinal)'
        '[StringComparison]::Ordinal'
        'Composed GitHub Release notes are missing required notice/hash evidence or remain contradictory.'
        'Revalidate candidate and production audits without executing repository code'
        'production-installer-audit-amd:'
        'production-installer-audit-intel:'
        'schema v2 required'
        'group: evervigil-production-audit-amd'
        'group: evervigil-production-audit-intel'
        'labels: [self-hosted, Windows, X64, ephemeral, audit-controller, isolated-physical-target, windows-11-pro, evervigil-production-audit, target-cpu-amd]'
        'labels: [self-hosted, Windows, X64, ephemeral, audit-controller, isolated-physical-target, windows-11-pro, evervigil-production-audit, target-cpu-intel]'
        'environment: production-installer-audit-amd'
        'environment: production-installer-audit-intel'
        'PRODUCTION_AUDIT_HARNESS_SHA256: ${{ vars.EVERVIGIL_PRODUCTION_AUDIT_HARNESS_SHA256 }}'
        'C:\Program Files\EverVigil Production Audit\EverVigilProductionAudit.exe'
        '[IO.FileShare]::Read'
        '[EverVigilAudit.NativeFileIdentity]::Read($harnessLock.SafeFileHandle)'
        '$beforeIdentity.LinkCount -ne 1'
        'A non-administrative identity can modify audit harness ancestry'
        '.\tests\Test-ProductionInstallerAuditReport.ps1'
        '--controller-only'
        '--require-token-free-target'
        '--require-fresh-physical-target'
        '--fail-on-skip'
        'EverVigil-production-installer-audit-amd-${{ github.sha }}'
        'EverVigil-production-installer-audit-intel-${{ github.sha }}'
        '- production-installer-audit-amd'
        '- production-installer-audit-intel'
        "needs.production-installer-audit-amd.result == 'success'"
        "needs.production-installer-audit-intel.result == 'success'"
        'Assert-ProductionAudit'
        '[long]$report.schemaVersion -ne 2'
        "'cleanInstall'"
        'Assert-CleanInstallAudit'
        'Get-CanonicalCleanInstallAuditJson'
        'Assert-ProductionSetupAuditLog'
        'clean-install-execution-attestation'
        'candidate-production-setup-executed'
        'clean-product-state-absent'
        'standard-user-hkcu-install'
        'prepare-to-install-succeeded'
        'setup-exit-zero'
        'broker-authenticated-pipe-roundtrip'
        'installer-log-error-free'
        'powershell-runtime-crash-free'
        'installed-version-exact'
        'install-transaction-finalized'
        'protectedBrokerExecutableAbsent'
        'protectedBrokerRootAbsent'
        'bootstrapPipeConnected'
        'CanonicalReady'
        'canonicalPipeConnected'
        'NoChange'
        'authenticationExitCode3Count'
        'C:\Program Files\PowerShell\7\pwsh.exe'
        'C:\Program Files\PowerShell\7\coreclr.dll'
        'applicationErrorEvent1000Count'
        'dotNetRuntimeEvent1023Count'
        'internalClrError80131506Count'
        'windowsErrorReportingEvent1001Count'
        'transactionCompleted'
        'A #015 publish-job production Setup semantic negative fixture was not rejected.'
        'exited before opening its authenticated pipe'
        'AMD and Intel audits must come from distinct credential-free physical targets.'
        'target-credential-isolation'
        'github-job-token-absent-on-target'
        'runner-credentials-absent-on-target'
        'tailnet-auth-key-absent-on-target'
        'configuration-required-exact'
        'over-the-shoulder-separate-administrator'
        'pre-boundary-rollback'
        'post-boundary-forward-recovery'
        'credential-evidence-redacted'
        'normal-update'
        'skippedChecks'
        'qr-connection-redacted-log'
        'gh release create'
        '--draft'
        '--prerelease'
    )) {
    if (-not $releaseWorkflowContent.Contains($releaseGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Private draft release guard is missing: $releaseGuard")
    }
}
$reviewedBootstrapSources = [ordered]@{
    '.\.github\release-host-lock.json' = '.github\release-host-lock.json'
    '.\.github\release-source-manifest.json' = '.github\release-source-manifest.json'
    '.\tests\ReleasePathIsolation.ps1' = 'tests\ReleasePathIsolation.ps1'
    '.\tests\Test-ReleaseHost.ps1' = 'tests\Test-ReleaseHost.ps1'
}
foreach ($bootstrapSource in $reviewedBootstrapSources.GetEnumerator()) {
    $expectedBootstrapHash = (Get-FileHash `
            -LiteralPath (Join-Path $RepositoryRoot ([string]$bootstrapSource.Value)) `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedBootstrapEntry =
        "'$([string]$bootstrapSource.Key)' = '$expectedBootstrapHash'"
    if (-not $releaseWorkflowContent.Contains(
            $expectedBootstrapEntry,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "The server-reviewed release bootstrap hash is stale or missing: $($bootstrapSource.Value)")
    }
}
if (-not $releaseWorkflowContent.Contains(
        '$releaseCriticalSourceLocks.Count -ne 4',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Private release must keep all four server-reviewed bootstrap sources locked and live.')
}

$releaseSourceManifestPath =
    Join-Path $RepositoryRoot '.github\release-source-manifest.json'
try {
    $releaseSourceManifest =
        Get-Content -LiteralPath $releaseSourceManifestPath -Raw | ConvertFrom-Json
    $manifestTopLevelProperties = @(
        $releaseSourceManifest.PSObject.Properties.Name | Sort-Object)
    if ([string]::Join("`n", $manifestTopLevelProperties) -cne
            "files`nschemaVersion" -or
        [int]$releaseSourceManifest.schemaVersion -ne 1 -or
        @($releaseSourceManifest.files).Count -eq 0) {
        throw 'The source manifest top-level schema is invalid.'
    }

    $manifestSourcePaths = [Collections.Generic.List[string]]::new()
    $manifestSourceEntries =
        [Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::OrdinalIgnoreCase)
    $previousManifestSourcePath = $null
    foreach ($manifestEntry in @($releaseSourceManifest.files)) {
        $entryProperties = @($manifestEntry.PSObject.Properties.Name | Sort-Object)
        $manifestSourcePath = [string]$manifestEntry.path
        if ([string]::Join("`n", $entryProperties) -cne "length`npath`nsha256" -or
            [string]::IsNullOrWhiteSpace($manifestSourcePath) -or
            $manifestSourcePath.Contains('\') -or
            [IO.Path]::IsPathFullyQualified($manifestSourcePath) -or
            @($manifestSourcePath.Split('/') | Where-Object {
                    [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..'
                }).Count -ne 0 -or
            @($manifestSourcePath.Split('/') | Where-Object {
                    $_ -ieq 'bin' -or $_ -ieq 'obj'
                }).Count -ne 0 -or
            $manifestSourcePath -ieq '.github/release-source-manifest.json' -or
            $manifestSourcePath -ieq '.github/workflows/release.yml' -or
            [string]$manifestEntry.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            [string]$manifestEntry.length -cnotmatch '\A(?:0|[1-9]\d*)\z' -or
            [long]$manifestEntry.length -lt 0 -or
            ($null -ne $previousManifestSourcePath -and
                [string]::CompareOrdinal(
                    $previousManifestSourcePath,
                    $manifestSourcePath) -ge 0) -or
            -not $manifestSourceEntries.TryAdd($manifestSourcePath, $manifestEntry)) {
            throw "The source manifest contains a non-canonical entry: $manifestSourcePath"
        }
        $manifestSourcePaths.Add($manifestSourcePath)
        $previousManifestSourcePath = $manifestSourcePath
        $manifestFile = Get-Item `
            -LiteralPath (Join-Path $RepositoryRoot $manifestSourcePath) `
            -Force `
            -ErrorAction Stop
        $manifestFileHash = (Get-FileHash `
                -LiteralPath $manifestFile.FullName `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($manifestFile.PSIsContainer -or
            ($manifestFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $manifestFile.Length -ne [long]$manifestEntry.length -or
            $manifestFileHash -cne [string]$manifestEntry.sha256) {
            throw "The source manifest does not match the current file bytes: $manifestSourcePath"
        }
    }

    $actualManifestSourcePathList = [Collections.Generic.List[string]]::new()
    foreach ($actualSourceFile in @(
            Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse -Force)) {
        $actualRelativePath = [IO.Path]::GetRelativePath(
            $RepositoryRoot,
            $actualSourceFile.FullName).Replace('\', '/')
        $actualPathSegments = @($actualRelativePath.Split('/'))
        if ($actualPathSegments[0] -in @('.git', '.jj', '.codex', 'artifacts') -or
            $actualPathSegments -contains 'bin' -or
            $actualPathSegments -contains 'obj' -or
            $actualRelativePath -in @(
                '.github/release-source-manifest.json',
                '.github/workflows/release.yml')) {
            continue
        }
        $actualManifestSourcePathList.Add($actualRelativePath)
    }
    [string[]]$actualManifestSourcePaths = @($actualManifestSourcePathList)
    [Array]::Sort($actualManifestSourcePaths, [StringComparer]::Ordinal)
    if ($manifestSourcePaths.Count -ne $actualManifestSourcePaths.Count -or
        [string]::Join("`n", $manifestSourcePaths) -cne
            [string]::Join("`n", $actualManifestSourcePaths)) {
        throw 'The source manifest file set is not the exact current repository file set.'
    }

    $attributesContent = Get-Content `
        -LiteralPath (Join-Path $RepositoryRoot '.gitattributes') `
        -Raw
    foreach ($requiredLfAttribute in @(
            '* text=auto eol=lf',
            '*.ps1 text eol=lf',
            '*.psd1 text eol=lf',
            '*.cmd text eol=lf')) {
        if (-not $attributesContent.Contains(
                $requiredLfAttribute,
                [StringComparison]::Ordinal)) {
            throw "The release source EOL contract is missing: $requiredLfAttribute"
        }
    }
    if ($attributesContent.Contains('eol=crlf', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The release source EOL contract must not request CRLF checkout bytes.'
    }

    $strictManifestUtf8 = [Text.UTF8Encoding]::new($false, $true)
    foreach ($manifestEntry in @($releaseSourceManifest.files)) {
        $manifestExtension = [IO.Path]::GetExtension([string]$manifestEntry.path)
        if ($manifestExtension -in @('.png', '.ico')) {
            continue
        }
        $manifestTextBytes = [IO.File]::ReadAllBytes(
            (Join-Path $RepositoryRoot ([string]$manifestEntry.path)))
        [void]$strictManifestUtf8.GetString($manifestTextBytes)
        if ($manifestTextBytes -contains 13) {
            throw "A release source does not use canonical LF bytes: $($manifestEntry.path)"
        }
    }
} catch {
    $failures.Add("Release source manifest validation failed: $($_.Exception.Message)")
}
foreach ($unsafeReleaseProfilePath in @(
        "APPDATA = Join-Path `$dependencyRoot 'app-data'",
        "LOCALAPPDATA = Join-Path `$dependencyRoot 'local-app-data'")) {
    if ($releaseWorkflowContent.Contains(
            $unsafeReleaseProfilePath,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Private release paths must use the coherent isolated user profile hierarchy: $unsafeReleaseProfilePath")
    }
}
foreach ($unsafeReleaseIsolationPattern in @(
        '[IO.Directory]::CreateDirectory($dependencyRoot)',
        'if (Test-Path $bundleRoot) { Remove-Item $bundleRoot -Recurse -Force }',
        "[string[]]`$ExcludedRootNames = @('.git', 'artifacts')",
        '$isolatedPath.StartsWith(',
        "foreach (`$sourceRootName in @('.github', 'docs', 'installer', 'scripts', 'src', 'tests'))")) {
    if ($releaseWorkflowContent.Contains(
            $unsafeReleaseIsolationPattern,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Private release still contains a weak lexical or partial-scan isolation pattern: $unsafeReleaseIsolationPattern")
    }
}
$releaseNuGetPluginSentinelMatch = [regex]::Match(
    $releaseWorkflowContent,
    '(?s)foreach \(\$pluginPathVariable in @\((?<variables>.*?)\)\) \{(?<body>.*?)\n\s*\}')
if (-not $releaseNuGetPluginSentinelMatch.Success) {
    $failures.Add('Private release NuGet plugin isolation block is missing.')
} else {
    $pluginVariables = $releaseNuGetPluginSentinelMatch.Groups['variables'].Value
    foreach ($requiredPluginVariable in @(
            'NUGET_PLUGIN_PATHS',
            'NUGET_NETCORE_PLUGIN_PATHS',
            'NUGET_NETFX_PLUGIN_PATHS')) {
        if ([regex]::Matches(
                $pluginVariables,
                "'" + [regex]::Escape($requiredPluginVariable) + "'").Count -ne 1) {
            $failures.Add(
                "Private release must disable each NuGet plugin selector exactly once: $requiredPluginVariable")
        }
    }
    $pluginIsolationBody = $releaseNuGetPluginSentinelMatch.Groups['body'].Value
    if (-not $pluginIsolationBody.Contains("';'", [StringComparison]::Ordinal) -or
        -not $pluginIsolationBody.Contains('-cne '';''', [StringComparison]::Ordinal)) {
        $failures.Add(
            'Private release must set and re-read the NuGet 6.8.2 explicit zero-plugin sentinel.')
    }
    $firstDotnetInvocationIndex = $releaseWorkflowContent.IndexOf(
        '& $dotnetPath',
        [StringComparison]::Ordinal)
    if ($firstDotnetInvocationIndex -lt 0 -or
        $releaseNuGetPluginSentinelMatch.Index +
            $releaseNuGetPluginSentinelMatch.Length -ge $firstDotnetInvocationIndex -or
        [regex]::Matches(
            $releaseWorkflowContent,
            '(?s)SetEnvironmentVariable\(\s*\$pluginPathVariable,\s*'';''').Count -ne 1 -or
        [regex]::IsMatch(
            $releaseWorkflowContent,
            '(?im)^\s*\$env:NUGET_(?:NETCORE_|NETFX_)?PLUGIN_PATHS\s*=')) {
        $failures.Add(
            'Private release must set the zero-plugin sentinel once before the first dotnet invocation and never overwrite it.')
    }
}
foreach ($releaseIsolationGuard in @(
        'Assert-EverVigilDirectoryWithin',
        'The isolated release environment changed:',
        'The release directory locks are not held.',
        '$nuGetMigrationMarker = Join-Path $env:LOCALAPPDATA ''NuGet\Migrations\1''',
        'Get-ChildItem -LiteralPath $workspaceRoot -Force',
        '$sourceEntry.Name -ceq ''.git''',
        '$sourceMigrationMarkers.Count -ne 0')) {
    if (-not $releaseWorkflowContent.Contains(
            $releaseIsolationGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Private release isolation guard is missing: $releaseIsolationGuard")
    }
}
if ([regex]::Matches(
        $releaseWorkflowContent,
        '(?m)^\s+Assert-EverVigilReleaseIsolationState\s*$').Count -ne 12) {
    $failures.Add(
        'Private release must revalidate and retain isolation before every restore/build/test boundary.')
}
$releaseAncestryLockIndex = $releaseWorkflowContent.IndexOf(
    '$releaseDirectoryLocks += @(Lock-EverVigilDirectoryAncestries',
    [StringComparison]::Ordinal)
$releaseSourceTreeLockIndex = $releaseWorkflowContent.IndexOf(
    '$releaseSourceTreeLocks = New-EverVigilSourceTreeLocks',
    [StringComparison]::Ordinal)
$releaseRepositoryTestIndex = $releaseWorkflowContent.IndexOf(
    '.\tests\Test-Repository.ps1',
    [StringComparison]::Ordinal)
if ($releaseAncestryLockIndex -lt 0 -or
    $releaseSourceTreeLockIndex -le $releaseAncestryLockIndex -or
    $releaseRepositoryTestIndex -le $releaseSourceTreeLockIndex -or
    [regex]::Matches(
        $releaseWorkflowContent,
        'Assert-EverVigilSourceTreeLockState -LockSet \$releaseSourceTreeLocks').Count -ne 1) {
    $failures.Add(
        'Private release must lock and revalidate the complete source tree after ancestry review and before repository code runs.')
}
$releasePathIsolationContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\ReleasePathIsolation.ps1') `
    -Raw
$releasePathIsolationSha256 = (Get-FileHash `
        -LiteralPath (Join-Path $RepositoryRoot 'tests\ReleasePathIsolation.ps1') `
        -Algorithm SHA256).Hash.ToLowerInvariant()
if ([regex]::Matches(
        $releaseWorkflowContent,
        [regex]::Escape($releasePathIsolationSha256)).Count -ne 3) {
    $failures.Add(
        'Private release must bind all three release jobs to the exact reviewed path-isolation helper bytes.')
}
foreach ($releasePathGuard in @(
        'public sealed class ReleaseDirectoryLock : IDisposable'
        'FileShareRead = 0x00000001'
        'FileFlagOpenReparsePoint = 0x00200000'
        'GetFinalPathNameByHandleW'
        'QueryDosDeviceW'
        'GetVolumePathNamesForVolumeNameW'
        'IsNativeDriveRoot'
        'IsRegisteredVolumeMount'
        'public static string GetFinalPath(SafeFileHandle file)'
        '$stream.SafeFileHandle'
        'VolumeNameGuid = 0x00000001'
        'CreateFreshDirectory'
        '[IO.FileMode]::CreateNew'
        '[IO.FileShare]::Read'
        '$stream.Flush($true)'
        'RawSecurityDescriptor'
        '$null -eq $rawDescriptor.DiscretionaryAcl'
        'Assert-EverVigilAccessControlDescriptor'
        '0x50000000'
        '[Security.AccessControl.QualifiedAce]'
        'public bool IsAlive'
        'function New-EverVigilSourceTreeLocks'
        'function Assert-EverVigilSourceTreeLockState'
        'function Close-EverVigilSourceTreeLocks'
        'function Assert-EverVigilGeneratedOutputTreeState'
        'The fresh reviewed source checkout contains generated output:'
        'The reviewed non-generated source tree changed after it was locked.'
        'DeleteSubdirectoriesAndFiles'
        'ChangePermissions'
        'TakeOwnership')) {
    if (-not $releasePathIsolationContent.Contains(
            $releasePathGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Release path isolation contract is missing: $releasePathGuard")
    }
}
if (-not [regex]::IsMatch(
        $releaseWorkflowContent,
        '(?s)\.\\scripts\\Build-Release\.ps1.*?Assert-EverVigilReleaseIsolationState\s+Assert-NoEverVigilSourceNuGetMigrationState.*?\$installerName')) {
    $failures.Add(
        'Private release must perform the final isolation and migration scan after Build-Release and before manifest assembly.')
}
if (-not [regex]::IsMatch(
        $releaseWorkflowContent,
        '(?s)\$releaseFailure\s*=\s*\$null.*?try\s*\{.*?\}\s*catch\s*\{\s*\$releaseFailure\s*=\s*\$_.*?\}\s*finally\s*\{.*?Close-EverVigilSourceTreeLocks.*?\$sourceCheckoutLock\.Dispose\(\).*?\$releaseCriticalSourceLocks\[\$index\]\.Dispose\(\).*?\$releaseArtifactFileLocks\[\$index\]\.Dispose\(\).*?Close-EverVigilDirectorySentinelLocks.*?Close-EverVigilDirectoryLocks.*?Remove-Item -LiteralPath \$dependencyRoot')) {
    $failures.Add(
        'Private release must clean all isolation locks and the identity-bound dependency root in finally.')
}
if ([regex]::Matches(
        $releaseWorkflowContent,
        [regex]::Escape('schema v2 required')).Count -ne 2) {
    $failures.Add('AMD and Intel production audit jobs must both require schema v2.')
}
foreach ($controllerHarnessFlag in @(
        '--controller-only',
        '--require-token-free-target',
        '--require-fresh-physical-target')) {
    if ([regex]::Matches(
            $releaseWorkflowContent,
            [regex]::Escape($controllerHarnessFlag)).Count -ne 2) {
        $failures.Add(
            "The unchanged external harness CLI flag must occur once in each audit job: $controllerHarnessFlag")
    }
}

$productionAuditReportContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\Test-ProductionInstallerAuditReport.ps1') `
    -Raw
foreach ($productionAuditGuard in @(
        "[ValidateSet('AMD', 'Intel')]"
        'candidate-manifest.json'
        'production-installer-audit-report.json'
        'evervigil-production-installer-e2e'
        'manifestSha256'
        '[long]$report.schemaVersion -ne 2'
        "'cleanInstall'"
        'Assert-CleanInstallContract'
        'ConvertTo-CanonicalCleanInstallJson'
        'Assert-ProductionSetupLog'
        "'clean-install-execution-attestation'"
        "'candidate-production-setup-executed'"
        "'clean-product-state-absent'"
        "'standard-user-hkcu-install'"
        "'prepare-to-install-succeeded'"
        "'setup-exit-zero'"
        "'broker-authenticated-pipe-roundtrip'"
        "'installer-log-error-free'"
        "'powershell-runtime-crash-free'"
        "'installed-version-exact'"
        "'install-transaction-finalized'"
        'protectedBrokerExecutableAbsent'
        'protectedBrokerInstallationReceiptAbsent'
        'protectedBrokerRootAbsent'
        'protectedBrokerRetirementReceiptAbsent'
        'auditExtractRequested'
        'resourceAuditBuild'
        'installerSha256Before'
        'installerSha256After'
        'bootstrapPipeConnected'
        'CanonicalReady'
        'canonicalPipeConnected'
        'NoChange'
        'authenticationExitCode3Count'
        'C:\Program Files\PowerShell\7\pwsh.exe'
        'C:\Program Files\PowerShell\7\coreclr.dll'
        'applicationErrorEvent1000Count'
        'dotNetRuntimeEvent1023Count'
        'internalClrError80131506Count'
        'windowsErrorReportingEvent1001Count'
        'eventWindowCoversSetupLifecycle'
        'transactionCompleted'
        'A #015 production Setup semantic negative fixture was not rejected.'
        'exited before opening its authenticated pipe'
        '/AUDITEXTRACT'
        'EverVigil install worker exit code'
        'PrepareToInstall failed'
        '0x80131506'
        'ExpectedWorkflowRunId'
        'ExpectedWorkflowRunAttempt'
        'ExpectedAuditJob'
        "'Windows 11 Pro'"
        "'physicalMachine'"
        "'controller'"
        "'target'"
        "'target-credential-isolation'"
        "'controller-only-orchestration'"
        "'github-runner-absent-on-target'"
        "'github-job-token-absent-on-target'"
        "'runner-credentials-absent-on-target'"
        "'tailnet-auth-key-absent-on-target'"
        "'controller-credentials-unreachable-from-target'"
        "'target-session-retired'"
        "'target-isolation-attestation'"
        "'dedicated'"
        "'ephemeral'"
        "'cleanSnapshot'"
        "'clean-install'"
        "'configuration-required-exact'"
        "'normal-runtime'"
        "'windows-login-startup'"
        "'tray-operation'"
        "'even-terminal-launch'"
        "'codex-app-server-launch'"
        "'child-abnormal-exit-restart'"
        "'tailscale-serve-ownership-exact'"
        "'qr-connection'"
        "'reveal-timeout'"
        "'token-persistence'"
        "'normal-update'"
        "'v1.2.1-default-migration'"
        "'v1.2.1-custom-path-ports-migration'"
        "'pre-boundary-rollback'"
        "'post-boundary-forward-recovery'"
        "'shell-registration'"
        "'start-menu-exact'"
        "'arp-exact'"
        "'support-surface-exact'"
        "'preserve-uninstall'"
        "'complete-uninstall'"
        "'over-the-shoulder-separate-administrator'"
        "'residue-system-snapshots'"
        '[long]$report.summary.skippedChecks -ne 0'
        'Assert-NoDuplicateJsonProperties'
        '[Text.UTF8Encoding]::new($false, $true)'
        'Assert-CredentialFreeEvidenceText'
        '$credentialLeakFixtures'
        'A credential-evidence negative fixture was not rejected.'
        "'qr-connection-redacted-log'"
        "'token-persistence-redacted-log'"
        "'ots-separate-administrator-log'"
        '(?i)authorization\s*:\s*bearer'
        '(?i)[?&](?:token|bridge_token|access_token)='
        '(?i)(?:github_pat_|gh[pousr]_|tskey-(?:auth|client|api|webhook)-)'
        'sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}'
        'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
        'TAILSCALE_AUTHKEY'
        'OPENAI_API_KEY'
        'CODEX_API_KEY'
        'ANTHROPIC_API_KEY'
        'AZURE_OPENAI_API_KEY'
        'eyJ[A-Za-z0-9_-]{10,}'
        '(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])'
    )) {
    if (-not $productionAuditReportContent.Contains(
            $productionAuditGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Production installer audit report guard is missing: $productionAuditGuard")
    }
}
if ($productionAuditReportContent -match '(?i)Start-Process|&\s*\$candidateInstaller') {
    $failures.Add(
        'The report validator must not execute the production installer or replace the external audit harness.')
}

foreach ($referenceContract in @(
        [pscustomobject]@{
            Path = 'docs\REFERENCE.ja.md'
            Label = 'Japanese'
        },
        [pscustomobject]@{
            Path = 'docs\REFERENCE.en.md'
            Label = 'English'
        })) {
    $referenceContent = Get-Content `
        -LiteralPath (Join-Path $RepositoryRoot $referenceContract.Path) `
        -Raw
    foreach ($referenceGuard in @(
            'schemaVersion=2',
            'clean-install-execution-attestation',
            'protectedBrokerRootAbsent',
            'PrepareToInstall',
            '/AUDITEXTRACT',
            'broker-authenticated-pipe-roundtrip',
            'CanonicalReady',
            'NoChange',
            '0x80131506')) {
        if (-not $referenceContent.Contains($referenceGuard, [StringComparison]::Ordinal)) {
            $failures.Add(
                "$($referenceContract.Label) reference is missing the production clean-install v2 contract: $referenceGuard")
        }
    }
}

$nativeAotRestoreMatch = [regex]::Match(
    $releaseWorkflowContent,
    '(?s)& \$dotnetPath restore \.\\src\\EverVigil\.Broker\\EverVigil\.Broker\.csproj `(?<body>.*?)throw "NativeAOT broker locked restore failed')
if (-not $nativeAotRestoreMatch.Success) {
    $failures.Add('Private release workflow has no isolated NativeAOT broker restore.')
} else {
    $nativeAotRestoreBody = $nativeAotRestoreMatch.Groups['body'].Value
    foreach ($nativeAotRestoreGuard in @(
            '--locked-mode'
            '-r win-x64'
            '--disable-parallel'
            '-m:1'
            '-p:Configuration=Release'
            '-p:PublishAot=true'
            '-p:RestoreBuildInParallel=false'
        )) {
        if (-not $nativeAotRestoreBody.Contains(
                $nativeAotRestoreGuard,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "Private NativeAOT restore guard is missing: $nativeAotRestoreGuard")
        }
    }
}
if ($validateWorkflowContent.Contains('--fail-on-skip', [StringComparison]::Ordinal)) {
    $failures.Add('Normal validation must report broker skips separately without applying the release-only fail-on-skip gate.')
}
if ($releaseWorkflowContent.Contains('-BrokerTestSkipPolicy Report', [StringComparison]::Ordinal)) {
    $failures.Add('The private release workflow must never weaken the broker skip policy.')
}
$workflowPinContracts = @(
    [pscustomobject]@{
        Name = 'validate'
        Content = $validateWorkflowContent
        Pins = @(
            'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'
            'actions/setup-dotnet@67a3573c9a986a3f9c594539f4ab511d57bb3ce9'
            'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')
    }
    [pscustomobject]@{
        Name = 'release'
        Content = $releaseWorkflowContent
        Pins = @(
            'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'
            'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
            'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093')
    })
foreach ($workflowPinContract in $workflowPinContracts) {
    foreach ($requiredActionPin in $workflowPinContract.Pins) {
        if (-not $workflowPinContract.Content.Contains(
                $requiredActionPin,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "$($workflowPinContract.Name) workflow is missing immutable action pin: $requiredActionPin")
        }
    }
    if ($workflowPinContract.Content -match
        '(?m)^\s*uses:\s+actions/[^@\s]+@(?![0-9a-f]{40}(?:\s|#|$))') {
        $failures.Add(
            "$($workflowPinContract.Name) workflow contains a mutable action reference.")
    }
}

$releaseJobSeparator = '  publish-private-draft:'
$releaseJobSeparatorIndex = $releaseWorkflowContent.IndexOf(
    $releaseJobSeparator,
    [StringComparison]::Ordinal)
if ($releaseJobSeparatorIndex -lt 0) {
    $failures.Add('Private release validation and GitHub publishing must be separate jobs.')
} else {
    $releaseValidationJob = $releaseWorkflowContent.Substring(0, $releaseJobSeparatorIndex)
    $releasePublishingJob = $releaseWorkflowContent.Substring($releaseJobSeparatorIndex)
    foreach ($validationOnlyGuard in @(
            'group: evervigil-release'
            'contents: read'
            'persist-credentials: false'
            'C:\Windows\System32\cmd.exe /D /S /C'
            'C:\Program Files\EverVigil Release Host\Invoke-ReleaseShell.cmd'
            'labels: [self-hosted, Windows, X64, ephemeral, windows-11-pro, tailscale-pinned]'
            '.\tests\Test-ReleaseHost.ps1'
            '--fail-on-skip')) {
        if (-not $releaseValidationJob.Contains($validationOnlyGuard, [StringComparison]::Ordinal)) {
            $failures.Add("Private release validation job guard is missing: $validationOnlyGuard")
        }
    }
    if ($releaseValidationJob.Contains('runs-on: windows-latest', [StringComparison]::Ordinal) -or
        $releaseValidationJob.Contains('contents: write', [StringComparison]::Ordinal) -or
        $releaseValidationJob.Contains('GH_TOKEN:', [StringComparison]::Ordinal)) {
        $failures.Add('Untrusted release validation must not run on windows-latest or receive GitHub write credentials.')
    }
    foreach ($publishingGuard in @(
            'runs-on: windows-latest'
            'environment: private-release-candidate'
            'contents: write'
            '- validate-private-candidate'
            '- production-installer-audit-amd'
            '- production-installer-audit-intel'
            "needs.production-installer-audit-amd.result == 'success'"
            "needs.production-installer-audit-intel.result == 'success'"
            'Assert-ProductionAudit'
            'without executing repository code')) {
        if (-not $releasePublishingJob.Contains($publishingGuard, [StringComparison]::Ordinal)) {
            $failures.Add("Private release publishing job guard is missing: $publishingGuard")
        }
    }
    if ($releasePublishingJob.Contains('actions/checkout@', [StringComparison]::Ordinal) -or
        $releasePublishingJob.Contains('.\scripts\', [StringComparison]::Ordinal) -or
        $releasePublishingJob.Contains('.\tests\', [StringComparison]::Ordinal) -or
        $releasePublishingJob.Contains('dotnet ', [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add('The GitHub write-token job must not checkout or execute repository code.')
    }
}
if ([regex]::Matches($releaseWorkflowContent, '(?m)^\s+contents:\s+write\s*$').Count -ne 1 -or
    [regex]::Matches($releaseWorkflowContent, '(?m)^\s+GH_TOKEN:\s*').Count -ne 1) {
    $failures.Add(
        'Only the no-checkout publishing job may receive the GitHub contents write token.')
}
if ([regex]::Matches(
        $releaseWorkflowContent,
        [regex]::Escape("github.ref == 'refs/heads/main'")).Count -ne 4 -or
    [regex]::Matches(
        $releaseWorkflowContent,
        [regex]::Escape("github.event.repository.default_branch == 'main'")).Count -ne 4) {
    $failures.Add('All private release jobs must be bound exactly to the main default branch.')
}
if ($releaseWorkflowContent -match '(?im)\b(?:winget|choco)\b' -or
    $releaseWorkflowContent.Contains('dotnet-version: 8.0.x', [StringComparison]::Ordinal)) {
    $failures.Add('The private release toolchain must never use mutable latest/package-manager resolution.')
}
if (-not $validateWorkflowContent.Contains('dotnet-version: 8.0.130', [StringComparison]::Ordinal) -or
    $validateWorkflowContent.Contains('dotnet-version: 8.0.x', [StringComparison]::Ordinal) -or
    -not $validateWorkflowContent.Contains('persist-credentials: false', [StringComparison]::Ordinal)) {
    $failures.Add('Normal validation must use the exact global.json SDK and must not persist checkout credentials.')
}

$globalJson = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'global.json') -Raw |
    ConvertFrom-Json
if ([string]$globalJson.sdk.version -cne '8.0.130' -or
    [string]$globalJson.sdk.rollForward -cne 'disable' -or
    [bool]$globalJson.sdk.allowPrerelease) {
    $failures.Add('global.json must pin .NET SDK 8.0.130 with roll-forward and prerelease disabled.')
}

$nuGetConfigContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'NuGet.config') `
    -Raw
foreach ($nuGetConfigGuard in @(
        '<clear />'
        'key="nuget.org"'
        'value="https://api.nuget.org/v3/index.json"'
        '<packageSourceMapping>'
        '<package pattern="*" />'
    )) {
    if (-not $nuGetConfigContent.Contains($nuGetConfigGuard, [StringComparison]::Ordinal)) {
        $failures.Add("NuGet source lock guard is missing: $nuGetConfigGuard")
    }
}
if ([regex]::Matches($nuGetConfigContent, '(?i)<add\s+key=').Count -ne 1 -or
    $nuGetConfigContent -match '(?i)packageSourceCredentials|fallbackPackageFolders|http_proxy') {
    $failures.Add('NuGet.config must expose only the reviewed nuget.org source without credentials, proxies, or fallback folders.')
}

$directoryBuildContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'Directory.Build.props') `
    -Raw
foreach ($directoryBuildGuard in @(
        '<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>'
        '<RestoreLockedMode Condition="''$(ContinuousIntegrationBuild)'' == ''true''">true</RestoreLockedMode>'
        '<ImportUserLocationsByWildcardBeforeMicrosoftCommonProps>false</ImportUserLocationsByWildcardBeforeMicrosoftCommonProps>'
        '<ImportUserLocationsByWildcardAfterMicrosoftCommonProps>false</ImportUserLocationsByWildcardAfterMicrosoftCommonProps>'
        '<ImportUserLocationsByWildcardBeforeMicrosoftCommonTargets>false</ImportUserLocationsByWildcardBeforeMicrosoftCommonTargets>'
        '<ImportUserLocationsByWildcardAfterMicrosoftCommonTargets>false</ImportUserLocationsByWildcardAfterMicrosoftCommonTargets>'
        '<ImportUserLocationsByWildcardBeforeMicrosoftCSharpTargets>false</ImportUserLocationsByWildcardBeforeMicrosoftCSharpTargets>'
        '<ImportUserLocationsByWildcardAfterMicrosoftCSharpTargets>false</ImportUserLocationsByWildcardAfterMicrosoftCSharpTargets>'
    )) {
    if (-not $directoryBuildContent.Contains($directoryBuildGuard, [StringComparison]::Ordinal)) {
        $failures.Add("MSBuild dependency-lock guard is missing: $directoryBuildGuard")
    }
}

$expectedPackageLocks = @(
    'src\EverVigil.Core\packages.lock.json'
    'src\EverVigil.Broker.Protocol\packages.lock.json'
    'src\EverVigil.Broker\packages.lock.json'
    'src\EverVigil\packages.lock.json'
    'tests\EverVigil.Tests\packages.lock.json'
    'tests\EverVigil.Broker.Tests\packages.lock.json')
$actualPackageLocks = @(Get-ChildItem `
        -LiteralPath $RepositoryRoot `
        -Filter 'packages.lock.json' `
        -File `
        -Recurse `
        -Force | ForEach-Object {
            [IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName)
        } | Sort-Object -CaseSensitive)
if (($actualPackageLocks -join "`n") -cne
    (($expectedPackageLocks | Sort-Object -CaseSensitive) -join "`n")) {
    $failures.Add('The repository must contain exactly one reviewed packages.lock.json for each .NET project.')
}
foreach ($packageLock in $expectedPackageLocks) {
    $packageLockPath = Join-Path $RepositoryRoot $packageLock
    try {
        $packageLockDocument = Get-Content -LiteralPath $packageLockPath -Raw | ConvertFrom-Json
        $dependencyTargets = @($packageLockDocument.dependencies.PSObject.Properties.Name)
        if ([int]$packageLockDocument.version -ne 1 -or
            $dependencyTargets.Count -eq 0 -or
            @($dependencyTargets | Where-Object { $_.EndsWith('/win-x64', [StringComparison]::Ordinal) }).Count -ne 1) {
            throw 'missing schema version 1 or the exact win-x64 restore target'
        }
    } catch {
        $failures.Add("Invalid locked NuGet dependency graph '$packageLock': $($_.Exception.Message)")
    }
}
$applicationLockContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\packages.lock.json') `
    -Raw
foreach ($qRCoderLockGuard in @(
        '"requested": "[1.8.0, )"'
        '"resolved": "1.8.0"'
        '"contentHash": "RuvX3PEXU6pbY/I5ItAk800jm62r+YnoPLgyS2WTgwxkOnGkOfU9ORiipHUF0LkLyqM8rlroUCA319JjRYfRFQ=="'
    )) {
    if (-not $applicationLockContent.Contains($qRCoderLockGuard, [StringComparison]::Ordinal)) {
        $failures.Add("QRCoder dependency lock guard is missing: $qRCoderLockGuard")
    }
}

$releaseShellContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\Invoke-ReleaseShell.cmd') `
    -Raw
foreach ($releaseShellGuard in @(
        'setlocal EnableExtensions EnableDelayedExpansion'
        'set "EVERVIGIL_KEEP_GITHUB_WORKSPACE=!GITHUB_WORKSPACE!"'
        'set "EVERVIGIL_KEEP_RUNNER_TEMP=!RUNNER_TEMP!"'
        'for /f "tokens=1 delims==" %%V in (''set'') do ('
        'if /i not "!EVERVIGIL_ENV_NAME:~0,15!"=="EVERVIGIL_KEEP_" set "!EVERVIGIL_ENV_NAME!="'
        'No arbitrary inherited'
        'name can become an MSBuild property'
        'set "ComSpec=C:\Windows\System32\cmd.exe"'
        'set "PATH=C:\Program Files\dotnet;C:\Program Files\PowerShell\7;C:\Windows\System32;C:\Windows"'
        'set "PSModulePath=C:\Program Files\PowerShell\7\Modules;C:\Windows\System32\WindowsPowerShell\v1.0\Modules"'
        'set "GITHUB_WORKSPACE=!EVERVIGIL_KEEP_GITHUB_WORKSPACE!"'
        'set "RUNNER_TEMP=!EVERVIGIL_KEEP_RUNNER_TEMP!"'
        'set "EVERVIGIL_RELEASE_EPHEMERAL=!EVERVIGIL_KEEP_RELEASE_EPHEMERAL!"'
        'set "PRODUCTION_AUDIT_HARNESS_SHA256=!EVERVIGIL_KEEP_PRODUCTION_AUDIT_HARNESS_SHA256!"'
        'set "EVERVIGIL_RELEASE_SHELL_RESULT=!EVERVIGIL_KEEP_SHELL_RESULT!"'
        'set EVERVIGIL_KEEP_ 2^>nul'
        'setlocal DisableDelayedExpansion'
        '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -NonInteractive'
    )) {
    if (-not $releaseShellContent.Contains($releaseShellGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Sanitized private-release shell guard is missing: $releaseShellGuard")
    }
}

$releaseShellFixtureRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("evervigil-release-shell-" + [Guid]::NewGuid().ToString('N'))
$releaseShellProbePath = Join-Path $releaseShellFixtureRoot 'probe.ps1'
$releaseShellResultPath = Join-Path $releaseShellFixtureRoot 'result.txt'
$releaseShellMetaMarkerPath = Join-Path $releaseShellFixtureRoot 'meta-executed.txt'
$releaseShellMetaPayload =
    'safe"& echo EVERVIGIL_META_EXECUTED>"' +
    $releaseShellMetaMarkerPath +
    '" & rem "'
$releaseShellCanaries = [ordered]@{
    DOTNET_STARTUP_HOOKS = 'evervigil-test-hook'
    COMPlus_ReadyToRun = '0'
    MSBuildSDKsPath = 'evervigil-test-sdk-path'
    NUGET_PLUGIN_PATHS = 'evervigil-test-plugin-path'
    NUGET_NETCORE_PLUGIN_PATHS = 'evervigil-test-netcore-plugin-path'
    NUGET_NETFX_PLUGIN_PATHS = 'evervigil-test-netfx-plugin-path'
    RestoreFallbackFolders = 'evervigil-test-fallback-path'
    ProjectAssetsFile = 'evervigil-test-assets-path'
    NuGetLockFilePath = 'evervigil-test-lock-path'
    DirectoryBuildPropsPath = 'evervigil-test-props-path'
    CscToolPath = 'evervigil-test-csc-path'
    CscToolExe = 'evervigil-test-csc.exe'
    CSharpCoreTargetsPath = 'evervigil-test-csharp-targets'
    EVIL_UNREVIEWED_ENVIRONMENT = 'evervigil-test-arbitrary-property'
    PRODUCTION_AUDIT_HARNESS_SHA256 = ([string]::new([char]'b', 64))
    REQUESTED_VERSION = $releaseShellMetaPayload
    GITHUB_ACTOR = $releaseShellMetaPayload
    PSModulePath = 'evervigil-test-module-path'
    EVERVIGIL_RELEASE_SHELL_RESULT = $releaseShellResultPath
}
$releaseShellPreviousEnvironment = @{}
try {
    [IO.Directory]::CreateDirectory($releaseShellFixtureRoot) | Out-Null
    $probeScript = @'
$expectedModulePath = 'C:\Program Files\PowerShell\7\Modules;C:\Windows\System32\WindowsPowerShell\v1.0\Modules'
$prohibited = @(Get-ChildItem Env: | Where-Object {
    $_.Value -like 'evervigil-test-*' -or
    $_.Name -like 'EVERVIGIL_KEEP_*' -or
    $_.Name -ieq 'REQUESTED_VERSION'
})
$passed = $prohibited.Count -eq 0 -and
    $env:PSModulePath -ceq $expectedModulePath -and
    $env:PRODUCTION_AUDIT_HARNESS_SHA256 -ceq ([string]::new([char]'b', 64))
$result = if ($passed) {
    'PASS'
} else {
    'FAIL:' + (($prohibited | ForEach-Object Name | Sort-Object) -join ',') +
        '|PSModulePath=' + $env:PSModulePath
}
[IO.File]::WriteAllText(
    $env:EVERVIGIL_RELEASE_SHELL_RESULT,
    $result,
    [Text.UTF8Encoding]::new($false))
if (-not $passed) { exit 23 }
'@
    [IO.File]::WriteAllText(
        $releaseShellProbePath,
        $probeScript,
        [Text.UTF8Encoding]::new($false))
    foreach ($entry in $releaseShellCanaries.GetEnumerator()) {
        $releaseShellPreviousEnvironment[[string]$entry.Key] =
            [Environment]::GetEnvironmentVariable([string]$entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            [string]$entry.Value,
            'Process')
    }
    $releaseShellCommand =
        "`"`"$(Join-Path $RepositoryRoot 'tests\Invoke-ReleaseShell.cmd')`" " +
        "`"$releaseShellProbePath`"`""
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /D /S /C $releaseShellCommand
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $releaseShellResultPath -PathType Leaf) -or
        [IO.File]::ReadAllText($releaseShellResultPath) -cne 'PASS' -or
        (Test-Path -LiteralPath $releaseShellMetaMarkerPath)) {
        $releaseShellResult = if (Test-Path -LiteralPath $releaseShellResultPath -PathType Leaf) {
            [IO.File]::ReadAllText($releaseShellResultPath)
        } else {
            'missing result'
        }
        $failures.Add(
            'The private-release shell did not safely remove injected .NET, MSBuild, NuGet, ' +
            'compiler, arbitrary-property, or cmd metacharacter canaries before PowerShell ' +
            "startup: $releaseShellResult")
    }
} catch {
    $failures.Add("Private-release shell negative test failed: $($_.Exception.Message)")
} finally {
    foreach ($entry in $releaseShellPreviousEnvironment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable(
                [string]$entry.Key,
                [string]$entry.Value,
                'Process')
        }
    }
    Remove-Item -LiteralPath $releaseShellFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$releaseProfileFixtureRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("evervigil-release-profile-" + [Guid]::NewGuid().ToString('N'))
$releaseProfileProbePath = Join-Path $releaseProfileFixtureRoot 'probe.ps1'
$releaseProfileResultPath = Join-Path $releaseProfileFixtureRoot 'result.txt'
$releaseProfileRoot = Join-Path $releaseProfileFixtureRoot 'user-profile'
$releaseProfileEnvironment = [ordered]@{
    USERPROFILE = $releaseProfileRoot
    APPDATA = Join-Path $releaseProfileRoot 'AppData\Roaming'
    LOCALAPPDATA = Join-Path $releaseProfileRoot 'AppData\Local'
    NUGET_PLUGIN_PATHS = ';'
    NUGET_NETCORE_PLUGIN_PATHS = ';'
    NUGET_NETFX_PLUGIN_PATHS = ';'
    EVERVIGIL_RELEASE_PROFILE_RESULT = $releaseProfileResultPath
}
$releaseProfilePreviousEnvironment = @{}
try {
    foreach ($directory in @(
            $releaseProfileRoot,
            $releaseProfileEnvironment.APPDATA,
            $releaseProfileEnvironment.LOCALAPPDATA)) {
        [IO.Directory]::CreateDirectory([string]$directory) | Out-Null
    }
    $releaseProfileProbe = @'
$passed =
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData) -ceq $env:APPDATA -and
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) -ceq $env:LOCALAPPDATA -and
    $env:NUGET_PLUGIN_PATHS -ceq ';' -and
    $env:NUGET_NETCORE_PLUGIN_PATHS -ceq ';' -and
    $env:NUGET_NETFX_PLUGIN_PATHS -ceq ';'
[IO.File]::WriteAllText(
    $env:EVERVIGIL_RELEASE_PROFILE_RESULT,
    $(if ($passed) { 'PASS' } else { 'FAIL' }),
    [Text.UTF8Encoding]::new($false))
if (-not $passed) { exit 31 }
'@
    [IO.File]::WriteAllText(
        $releaseProfileProbePath,
        $releaseProfileProbe,
        [Text.UTF8Encoding]::new($false))
    foreach ($entry in $releaseProfileEnvironment.GetEnumerator()) {
        $releaseProfilePreviousEnvironment[[string]$entry.Key] =
            [Environment]::GetEnvironmentVariable([string]$entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            [string]$entry.Value,
            'Process')
    }
    & 'C:\Program Files\PowerShell\7\pwsh.exe' `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -File $releaseProfileProbePath
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $releaseProfileResultPath -PathType Leaf) -or
        [IO.File]::ReadAllText($releaseProfileResultPath) -cne 'PASS') {
        $failures.Add(
            'The coherent private-release profile did not isolate Windows known folders and NuGet plugins.')
    }
} catch {
    $failures.Add("Private-release profile isolation test failed: $($_.Exception.Message)")
} finally {
    foreach ($entry in $releaseProfilePreviousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            $entry.Value,
            'Process')
    }
    Remove-Item -LiteralPath $releaseProfileFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$nuGetPluginFixtureRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("evervigil-nuget-plugin-" + [Guid]::NewGuid().ToString('N'))
$nuGetPluginServerJob = $null
$nuGetPluginProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$nuGetPluginTimeoutMilliseconds = 15000
$invokeNuGetPluginProcess = {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$CaseRoot,

        [Parameter(Mandatory)]
        [string]$PluginPathValue,

        [Parameter(Mandatory)]
        [string]$MarkerPath
    )

    foreach ($directory in @(
            $CaseRoot,
            (Join-Path $CaseRoot 'profile'),
            (Join-Path $CaseRoot 'profile\AppData\Roaming'),
            (Join-Path $CaseRoot 'profile\AppData\Local'),
            (Join-Path $CaseRoot 'packages'),
            (Join-Path $CaseRoot 'http-cache'),
            (Join-Path $CaseRoot 'plugins-cache'))) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'C:\Program Files\dotnet\dotnet.exe'
    $startInfo.WorkingDirectory = $nuGetPluginFixtureRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    foreach ($entry in ([ordered]@{
                SystemRoot = $env:SystemRoot
                windir = $env:SystemRoot
                ComSpec = Join-Path $env:SystemRoot 'System32\cmd.exe'
                OS = 'Windows_NT'
                ProgramData = 'C:\ProgramData'
                ProgramFiles = 'C:\Program Files'
                ProgramW6432 = 'C:\Program Files'
                'ProgramFiles(x86)' = 'C:\Program Files (x86)'
                CommonProgramFiles = 'C:\Program Files\Common Files'
                CommonProgramW6432 = 'C:\Program Files\Common Files'
                'CommonProgramFiles(x86)' = 'C:\Program Files (x86)\Common Files'
                PATH = 'C:\Program Files\dotnet;C:\Windows\System32;C:\Windows'
                PATHEXT = '.COM;.EXE;.BAT;.CMD'
                DOTNET_ROOT = 'C:\Program Files\dotnet'
                DOTNET_CLI_HOME = Join-Path $CaseRoot 'profile'
                DOTNET_CLI_TELEMETRY_OPTOUT = '1'
                DOTNET_CLI_UI_LANGUAGE = 'en-US'
                DOTNET_NOLOGO = '1'
                DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
                DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
                DOTNET_MULTILEVEL_LOOKUP = '0'
                DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER = '1'
                MSBUILDDISABLENODEREUSE = '1'
                USERPROFILE = Join-Path $CaseRoot 'profile'
                USERNAME = $env:USERNAME
                USERDOMAIN = $env:USERDOMAIN
                HOMEDRIVE = [IO.Path]::GetPathRoot($CaseRoot).TrimEnd('\')
                HOMEPATH =
                    (Join-Path $CaseRoot 'profile').Substring(
                        [IO.Path]::GetPathRoot($CaseRoot).TrimEnd('\').Length)
                APPDATA = Join-Path $CaseRoot 'profile\AppData\Roaming'
                LOCALAPPDATA = Join-Path $CaseRoot 'profile\AppData\Local'
                COMPUTERNAME = $env:COMPUTERNAME
                PROCESSOR_ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE
                PROCESSOR_IDENTIFIER = $env:PROCESSOR_IDENTIFIER
                PROCESSOR_LEVEL = $env:PROCESSOR_LEVEL
                PROCESSOR_REVISION = $env:PROCESSOR_REVISION
                NUMBER_OF_PROCESSORS = $env:NUMBER_OF_PROCESSORS
                TEMP = $CaseRoot
                TMP = $CaseRoot
                NUGET_PACKAGES = Join-Path $CaseRoot 'packages'
                NUGET_HTTP_CACHE_PATH = Join-Path $CaseRoot 'http-cache'
                NUGET_PLUGINS_CACHE_PATH = Join-Path $CaseRoot 'plugins-cache'
                NUGET_PLUGIN_PATHS = $PluginPathValue
                NUGET_NETCORE_PLUGIN_PATHS = $PluginPathValue
                NUGET_NETFX_PLUGIN_PATHS = $PluginPathValue
                EVERVIGIL_NUGET_PLUGIN_MARKER = $MarkerPath
            }).GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $nuGetPluginProcesses.Add($process)
    $started = $false
    try {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $started = $process.Start()
        if (-not $started) {
            throw 'dotnet process did not start'
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($nuGetPluginTimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "dotnet process exceeded $nuGetPluginTimeoutMilliseconds ms"
        }
        $stopwatch.Stop()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
            Output =
                $standardOutput.GetAwaiter().GetResult() +
                [Environment]::NewLine +
                $standardError.GetAwaiter().GetResult()
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
        [void]$nuGetPluginProcesses.Remove($process)
    }
}
try {
    [IO.Directory]::CreateDirectory($nuGetPluginFixtureRoot) | Out-Null
    $nuGetPluginEmptySource = Join-Path $nuGetPluginFixtureRoot 'empty-source'
    $nuGetPluginProjectRoot = Join-Path $nuGetPluginFixtureRoot 'PoisonPlugin'
    $nuGetRestoreProjectRoot = Join-Path $nuGetPluginFixtureRoot 'RestoreTarget'
    foreach ($directory in @(
            $nuGetPluginEmptySource,
            $nuGetPluginProjectRoot,
            $nuGetRestoreProjectRoot)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [IO.File]::WriteAllText(
        (Join-Path $nuGetPluginFixtureRoot 'global.json'),
        '{"sdk":{"version":"8.0.130","rollForward":"disable"}}',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $nuGetPluginProjectRoot 'PoisonPlugin.csproj'),
        @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@,
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $nuGetPluginProjectRoot 'Program.cs'),
        @'
var markerPath = Environment.GetEnvironmentVariable("EVERVIGIL_NUGET_PLUGIN_MARKER");
if (!string.IsNullOrWhiteSpace(markerPath))
{
    File.WriteAllText(markerPath, "EXECUTED");
}
return 86;
'@,
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $nuGetRestoreProjectRoot 'RestoreTarget.csproj'),
        @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="EverVigil.NuGetPlugin.Probe" Version="1.0.0" />
  </ItemGroup>
</Project>
'@,
        [Text.UTF8Encoding]::new($false))

    $nuGetPluginPublishRoot = Join-Path $nuGetPluginFixtureRoot 'plugin-publish'
    $nuGetPluginBuildRoot = Join-Path $nuGetPluginFixtureRoot 'build-process'
    $nuGetPluginBuildMarker = Join-Path $nuGetPluginFixtureRoot 'build-marker.txt'
    $nuGetPluginBuild = & $invokeNuGetPluginProcess `
        -Arguments @(
            'publish'
            (Join-Path $nuGetPluginProjectRoot 'PoisonPlugin.csproj')
            '--configuration'
            'Release'
            '--source'
            $nuGetPluginEmptySource
            '--packages'
            (Join-Path $nuGetPluginBuildRoot 'packages')
            '--output'
            $nuGetPluginPublishRoot
            '--nologo'
            '-p:NuGetAudit=false'
            '-p:UseSharedCompilation=false') `
        -CaseRoot $nuGetPluginBuildRoot `
        -PluginPathValue ';' `
        -MarkerPath $nuGetPluginBuildMarker
    $nuGetPoisonPluginPath = Join-Path $nuGetPluginPublishRoot 'PoisonPlugin.dll'
    if ($nuGetPluginBuild.ExitCode -ne 0 -or
        $nuGetPluginBuild.ElapsedMilliseconds -gt $nuGetPluginTimeoutMilliseconds -or
        -not (Test-Path -LiteralPath $nuGetPoisonPluginPath -PathType Leaf) -or
        (Test-Path -LiteralPath $nuGetPluginBuildMarker)) {
        throw "poison plugin build failed: $($nuGetPluginBuild.Output.Trim())"
    }

    $nuGetPluginServerJob = Start-Job -ScriptBlock {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        "READY:$port"
        try {
            while ($true) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 20
                    continue
                }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new(
                        $stream,
                        [Text.Encoding]::ASCII,
                        $false,
                        4096,
                        $true)
                    $requestLine = $reader.ReadLine()
                    while (($headerLine = $reader.ReadLine()) -ne $null -and
                        $headerLine.Length -gt 0) {
                    }
                    $path = ($requestLine -split ' ')[1]
                    if ($path -match '\A/(?<case>baseline|guarded)/v3/index\.json\z') {
                        $caseName = $Matches['case']
                        $body =
                            '{"version":"3.0.0","resources":[{"@id":"http://127.0.0.1:' +
                            $port +
                            '/' +
                            $caseName +
                            '/flat/","@type":"PackageBaseAddress/3.0.0"}]}'
                        $status = '200 OK'
                    } else {
                        $body = ''
                        $status = '404 Not Found'
                    }
                    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
                    $header =
                        "HTTP/1.1 $status`r`n" +
                        "Content-Type: application/json`r`n" +
                        "Content-Length: $($bodyBytes.Length)`r`n" +
                        "Connection: close`r`n`r`n"
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    if ($bodyBytes.Length -gt 0) {
                        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    }
                    $stream.Flush()
                    "REQUEST:${path}:$status"
                } finally {
                    $client.Dispose()
                }
            }
        } finally {
            $listener.Stop()
        }
    }
    $nuGetPluginServerReadyWatch = [Diagnostics.Stopwatch]::StartNew()
    $nuGetPluginServerPort = $null
    while ($nuGetPluginServerReadyWatch.ElapsedMilliseconds -lt 5000) {
        foreach ($line in @(Receive-Job -Job $nuGetPluginServerJob -Keep)) {
            if ([string]$line -match '\AREADY:(?<port>\d+)\z') {
                $nuGetPluginServerPort = [int]$Matches['port']
                break
            }
        }
        if ($null -ne $nuGetPluginServerPort) {
            break
        }
        if ($nuGetPluginServerJob.State -in @('Completed', 'Failed', 'Stopped')) {
            break
        }
        Start-Sleep -Milliseconds 50
    }
    $nuGetPluginServerReadyWatch.Stop()
    if ($null -eq $nuGetPluginServerPort) {
        throw 'loopback NuGet fixture server did not become ready within 5000 ms'
    }

    $nuGetRestoreProject = Join-Path $nuGetRestoreProjectRoot 'RestoreTarget.csproj'
    $nuGetBaselineRoot = Join-Path $nuGetPluginFixtureRoot 'baseline-process'
    $nuGetBaselineMarker = Join-Path $nuGetPluginFixtureRoot 'baseline-marker.txt'
    $nuGetBaseline = & $invokeNuGetPluginProcess `
        -Arguments @(
            'restore'
            $nuGetRestoreProject
            '--source'
            "http://127.0.0.1:$nuGetPluginServerPort/baseline/v3/index.json"
            '--packages'
            (Join-Path $nuGetBaselineRoot 'packages')
            '--no-cache'
            '--force'
            '--disable-parallel'
            '--verbosity'
            'normal'
            '-p:NuGetAudit=false') `
        -CaseRoot $nuGetBaselineRoot `
        -PluginPathValue $nuGetPoisonPluginPath `
        -MarkerPath $nuGetBaselineMarker
    $nuGetBaselineServerLines = @(Receive-Job -Job $nuGetPluginServerJob -Keep)

    $nuGetGuardedRoot = Join-Path $nuGetPluginFixtureRoot 'guarded-process'
    $nuGetGuardedMarker = Join-Path $nuGetPluginFixtureRoot 'guarded-marker.txt'
    $nuGetGuarded = & $invokeNuGetPluginProcess `
        -Arguments @(
            'restore'
            $nuGetRestoreProject
            '--source'
            "http://127.0.0.1:$nuGetPluginServerPort/guarded/v3/index.json"
            '--packages'
            (Join-Path $nuGetGuardedRoot 'packages')
            '--no-cache'
            '--force'
            '--disable-parallel'
            '--verbosity'
            'normal'
            '-p:NuGetAudit=false') `
        -CaseRoot $nuGetGuardedRoot `
        -PluginPathValue ';' `
        -MarkerPath $nuGetGuardedMarker
    $nuGetGuardedServerLines = @(Receive-Job -Job $nuGetPluginServerJob -Keep)

    $signatureDiagnostic = 'did not have a valid embedded signature'
    $baselineSelectedPoison =
        $nuGetBaseline.Output.Contains($nuGetPoisonPluginPath, [StringComparison]::OrdinalIgnoreCase) -and
        $nuGetBaseline.Output.Contains($signatureDiagnostic, [StringComparison]::OrdinalIgnoreCase)
    $baselineReachedSource = @($nuGetBaselineServerLines | Where-Object {
            [string]$_ -like 'REQUEST:/baseline/flat/*'
        }).Count -gt 0
    $guardedSelectedPoison =
        $nuGetGuarded.Output.Contains($nuGetPoisonPluginPath, [StringComparison]::OrdinalIgnoreCase) -or
        $nuGetGuarded.Output.Contains($signatureDiagnostic, [StringComparison]::OrdinalIgnoreCase)
    $guardedReachedSource = @($nuGetGuardedServerLines | Where-Object {
            [string]$_ -like 'REQUEST:/guarded/flat/*'
        }).Count -gt 0
    if ($nuGetBaseline.ExitCode -eq 0 -or
        $nuGetBaseline.ElapsedMilliseconds -gt $nuGetPluginTimeoutMilliseconds -or
        -not $baselineSelectedPoison -or
        $baselineReachedSource -or
        (Test-Path -LiteralPath $nuGetBaselineMarker) -or
        $nuGetGuarded.ExitCode -eq 0 -or
        $nuGetGuarded.ElapsedMilliseconds -gt $nuGetPluginTimeoutMilliseconds -or
        $guardedSelectedPoison -or
        -not $guardedReachedSource -or
        (Test-Path -LiteralPath $nuGetGuardedMarker)) {
        $failures.Add(
            'NuGet 6.8.2 explicit-plugin isolation regression failed: ' +
            "baselineExit=$($nuGetBaseline.ExitCode), " +
            "baselineMs=$($nuGetBaseline.ElapsedMilliseconds), " +
            "baselineSelected=$baselineSelectedPoison, " +
            "baselineSource=$baselineReachedSource, " +
            "baselineMarker=$(Test-Path -LiteralPath $nuGetBaselineMarker), " +
            "guardedExit=$($nuGetGuarded.ExitCode), " +
            "guardedMs=$($nuGetGuarded.ElapsedMilliseconds), " +
            "guardedSelected=$guardedSelectedPoison, " +
            "guardedSource=$guardedReachedSource, " +
            "guardedMarker=$(Test-Path -LiteralPath $nuGetGuardedMarker).")
    }
} catch {
    $failures.Add("NuGet plugin isolation negative test failed: $($_.Exception.Message)")
} finally {
    foreach ($process in @($nuGetPluginProcesses)) {
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
        } finally {
            $process.Dispose()
        }
    }
    $nuGetPluginProcesses.Clear()
    if ($null -ne $nuGetPluginServerJob) {
        Stop-Job -Job $nuGetPluginServerJob -ErrorAction SilentlyContinue
        Remove-Job -Job $nuGetPluginServerJob -Force -ErrorAction SilentlyContinue
    }
    $fixtureRootFullPath = [IO.Path]::GetFullPath($nuGetPluginFixtureRoot)
    $temporaryRootFullPath =
        [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($fixtureRootFullPath.StartsWith(
            $temporaryRootFullPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        try {
            Remove-Item `
                -LiteralPath $fixtureRootFullPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
            if (Test-Path -LiteralPath $fixtureRootFullPath) {
                throw 'fixture root still exists after cleanup'
            }
        } catch {
            $failures.Add("NuGet fixture cleanup failed: $($_.Exception.Message)")
        }
    } else {
        $failures.Add("Refusing to clean an unexpected NuGet fixture root: $fixtureRootFullPath")
    }
}

$releasePathIsolationScript = Join-Path $RepositoryRoot 'tests\ReleasePathIsolation.ps1'
if ($null -eq ('EverVigil.ReleasePathAliasFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace EverVigil
{
    public static class ReleasePathAliasFixture
    {
        private const uint RawTargetPath = 0x00000001;
        private const uint RemoveDefinition = 0x00000002;
        private const uint ExactMatchOnRemove = 0x00000004;
        private const uint NoBroadcastSystem = 0x00000008;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DefineDosDeviceW(
            uint flags,
            string deviceName,
            string targetPath);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint QueryDosDeviceW(
            string deviceName,
            [Out] char[] targetPath,
            int maximumLength);

        public static string GetSingleMapping(string deviceName)
        {
            int capacity = 512;
            while (capacity <= 32768)
            {
                char[] targets = new char[capacity];
                uint length = QueryDosDeviceW(deviceName, targets, targets.Length);
                if (length != 0)
                {
                    string[] mappings = new string(targets, 0, checked((int)length)).Split(
                        new[] { '\0' },
                        StringSplitOptions.RemoveEmptyEntries);
                    if (mappings.Length != 1)
                    {
                        throw new InvalidOperationException("The native fixture drive has multiple mappings.");
                    }
                    return mappings[0];
                }
                int error = Marshal.GetLastWin32Error();
                if (error != 122)
                {
                    throw new Win32Exception(error, "The native fixture drive mapping could not be read.");
                }
                capacity *= 2;
            }
            throw new InvalidOperationException("The native fixture drive mapping is too long.");
        }

        public static void Create(string deviceName, string targetPath)
        {
            if (!DefineDosDeviceW(
                    RawTargetPath | NoBroadcastSystem,
                    deviceName,
                    targetPath))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The local raw drive alias could not be created.");
            }
        }

        public static void Remove(string deviceName, string targetPath)
        {
            if (!DefineDosDeviceW(
                    RawTargetPath | RemoveDefinition | ExactMatchOnRemove | NoBroadcastSystem,
                    deviceName,
                    targetPath))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The local raw drive alias could not be removed.");
            }
        }
    }
}
'@
}
$releasePathFixtureRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("evervigil-release-path-" + [Guid]::NewGuid().ToString('N'))
$releasePathWorkspaceTarget = Join-Path `
    (Join-Path $RepositoryRoot 'artifacts') `
    ("release-path-target-" + [Guid]::NewGuid().ToString('N'))
$releasePathDrive = $null
$releasePathRawAliasTarget = $null
$releasePathSubstActive = $false
$releasePathRawAliasActive = $false
$releasePathDirectoryLocks = @()
$releasePathSentinelLocks = @()
$releasePathSourceTreeLocks = $null
try {
    . $releasePathIsolationScript
    [IO.Directory]::CreateDirectory($releasePathFixtureRoot) | Out-Null
    [IO.Directory]::CreateDirectory($releasePathWorkspaceTarget) | Out-Null
    $workspaceTargetMarker = Join-Path $releasePathWorkspaceTarget 'unchanged.txt'
    [IO.File]::WriteAllText(
        $workspaceTargetMarker,
        'UNCHANGED',
        [Text.UTF8Encoding]::new($false))
    $workspaceTargetHash = (Get-FileHash `
            -LiteralPath $workspaceTargetMarker `
            -Algorithm SHA256).Hash
    $relativeRejected = $false
    try {
        Get-EverVigilNormalizedDirectoryPath `
            -Path 'relative\release-state' `
            -Description 'Relative fixture' | Out-Null
    } catch {
        $relativeRejected = $_.Exception.Message -like '*fully-qualified*'
    }
    $insideWorkspaceRejected = $false
    try {
        Assert-EverVigilDirectoryOutside `
            -Path $releasePathWorkspaceTarget `
            -ForbiddenRoot $RepositoryRoot `
            -Description 'Workspace fixture' | Out-Null
    } catch {
        $insideWorkspaceRejected = $_.Exception.Message -like '*source checkout*'
    }

    $junctionPath = Join-Path $releasePathFixtureRoot 'workspace-junction'
    New-Item `
        -ItemType Junction `
        -Path $junctionPath `
        -Target $releasePathWorkspaceTarget `
        -ErrorAction Stop | Out-Null
    $junctionRejected = $false
    try {
        Assert-EverVigilNonReparseDirectoryAncestry `
            -Path $junctionPath `
            -Description 'Junction fixture' | Out-Null
    } catch {
        $junctionRejected = $_.Exception.Message -like '*reparse*'
    }

    foreach ($candidateLetter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        $candidateDrive = "$candidateLetter`:"
        if (-not (Test-Path -LiteralPath "$candidateDrive\")) {
            $releasePathDrive = $candidateDrive
            break
        }
    }
    if ($null -eq $releasePathDrive) {
        throw 'No free drive letter is available for the release-path alias fixture.'
    }
    & (Join-Path $env:SystemRoot 'System32\subst.exe') `
        $releasePathDrive `
        ([IO.Path]::GetPathRoot($releasePathFixtureRoot))
    if ($LASTEXITCODE -ne 0) {
        throw "subst failed with exit code $LASTEXITCODE."
    }
    $releasePathSubstActive = $true
    $driveAliasRejected = $false
    try {
        Assert-EverVigilDirectoryOutside `
            -Path "$releasePathDrive\" `
            -ForbiddenRoot $RepositoryRoot `
            -Description 'Drive-alias fixture' | Out-Null
    } catch {
        $driveAliasRejected = $_.Exception.Message -like '*drive alias*'
    }
    & (Join-Path $env:SystemRoot 'System32\subst.exe') $releasePathDrive /D
    if ($LASTEXITCODE -ne 0) {
        throw "subst cleanup failed with exit code $LASTEXITCODE."
    }
    $releasePathSubstActive = $false
    $nativeFixtureDrive = [IO.Path]::GetPathRoot($releasePathFixtureRoot).Substring(0, 2)
    $releasePathRawAliasTarget =
        [EverVigil.ReleasePathAliasFixture]::GetSingleMapping($nativeFixtureDrive)
    [EverVigil.ReleasePathAliasFixture]::Create(
        $releasePathDrive,
        $releasePathRawAliasTarget)
    $releasePathRawAliasActive = $true
    $rawDriveAliasRejected = $false
    try {
        Assert-EverVigilDirectoryOutside `
            -Path "$releasePathDrive\" `
            -ForbiddenRoot $RepositoryRoot `
            -Description 'Raw drive-alias fixture' | Out-Null
    } catch {
        $rawDriveAliasRejected =
            $_.Exception.Message -like '*not registered by the volume mount manager*'
    } finally {
        [EverVigil.ReleasePathAliasFixture]::Remove(
            $releasePathDrive,
            $releasePathRawAliasTarget)
        $releasePathRawAliasActive = $false
        $releasePathRawAliasTarget = $null
    }
    $runnerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $trustedWriterSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        $runnerIdentity.User.Value)
    $trustedDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:BAG:BAD:(A;;FA;;;SY)(A;;FA;;;BA)')
    Assert-EverVigilAccessControlDescriptor `
        -Descriptor $trustedDescriptor `
        -AllowedWriterSids $trustedWriterSids `
        -DangerousAccessMask 0x000D0156 `
        -Description 'Trusted raw ACL fixture' `
        -Path '<trusted-descriptor>'
    $genericAclRejected = $true
    foreach ($genericRight in @('GA', 'GW')) {
        $genericDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            "O:BAG:BAD:(A;;$genericRight;;;BU)")
        try {
            Assert-EverVigilAccessControlDescriptor `
                -Descriptor $genericDescriptor `
                -AllowedWriterSids $trustedWriterSids `
                -DangerousAccessMask 0x000D0156 `
                -Description 'Generic raw ACL fixture' `
                -Path "<generic-$genericRight>"
            $genericAclRejected = $false
        } catch {
            if ($_.Exception.Message -notlike '*can be replaced or modified*') {
                throw
            }
        }
    }
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $nullDaclDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        [Security.AccessControl.ControlFlags]::None,
        $administratorsSid,
        $administratorsSid,
        $null,
        $null)
    $nullDaclRejected = $false
    try {
        Assert-EverVigilAccessControlDescriptor `
            -Descriptor $nullDaclDescriptor `
            -AllowedWriterSids $trustedWriterSids `
            -DangerousAccessMask 0x000D0156 `
            -Description 'Null raw ACL fixture' `
            -Path '<null-dacl>'
    } catch {
        $nullDaclRejected = $_.Exception.Message -like '*null discretionary ACL*'
    }

    $sourceWorkspace = Join-Path $releasePathFixtureRoot 'source-workspace'
    [IO.Directory]::CreateDirectory($sourceWorkspace) | Out-Null
    $sourceWorkspaceSecurity = [Security.AccessControl.DirectorySecurity]::new()
    $sourceWorkspaceSecurity.SetOwner($runnerIdentity.User)
    $sourceWorkspaceSecurity.SetAccessRuleProtection($true, $false)
    $sourceInheritance =
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sourceRuleSid in @(
            $runnerIdentity.User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            $administratorsSid)) {
        $sourceWorkspaceSecurity.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sourceRuleSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $sourceInheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl `
        -LiteralPath $sourceWorkspace `
        -AclObject $sourceWorkspaceSecurity `
        -ErrorAction Stop

    $generatedOutputRoot = Join-Path $releasePathFixtureRoot 'generated-output-root'
    [IO.Directory]::CreateDirectory($generatedOutputRoot) | Out-Null
    Set-Acl `
        -LiteralPath $generatedOutputRoot `
        -AclObject $sourceWorkspaceSecurity `
        -ErrorAction Stop
    $generatedOutputMarker = Join-Path $generatedOutputRoot 'output.txt'
    [IO.File]::WriteAllText(
        $generatedOutputMarker,
        'GENERATED',
        [Text.UTF8Encoding]::new($false))
    $generatedOutputIdentity = Get-EverVigilDirectoryIdentity `
        -Path $generatedOutputRoot `
        -Description 'Generated-output fixture'
    $releasePathSentinelLocks = @(New-EverVigilDirectorySentinelLocks `
        -Paths @($generatedOutputRoot) `
        -Description 'Generated-output fixture')
    Assert-EverVigilGeneratedOutputTreeState `
        -RootPath $generatedOutputRoot `
        -ExpectedRootIdentity $generatedOutputIdentity `
        -RunnerSid $runnerIdentity.User.Value `
        -Description 'Generated-output fixture' `
        -HeldFileLocks $releasePathSentinelLocks | Out-Null
    $generatedOutputSentinelAccepted = $true

    $builtinUsersSid =
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $generatedOutputUnsafeAclRejected = $true
    foreach ($unsafeOutputKind in @('file', 'directory')) {
        $unsafeOutputPath = Join-Path `
            $generatedOutputRoot `
            "unsafe-$unsafeOutputKind"
        if ($unsafeOutputKind -ceq 'file') {
            [IO.File]::WriteAllText(
                $unsafeOutputPath,
                'UNSAFE',
                [Text.UTF8Encoding]::new($false))
        } else {
            [IO.Directory]::CreateDirectory($unsafeOutputPath) | Out-Null
        }
        try {
            $unsafeOutputAcl = Get-Acl -LiteralPath $unsafeOutputPath -ErrorAction Stop
            $unsafeOutputAcl.SetAccessRuleProtection($true, $true)
            $unsafeOutputAcl.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $builtinUsersSid,
                    [Security.AccessControl.FileSystemRights]::WriteData,
                    [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl `
                -LiteralPath $unsafeOutputPath `
                -AclObject $unsafeOutputAcl `
                -ErrorAction Stop
            try {
                Assert-EverVigilGeneratedOutputTreeState `
                    -RootPath $generatedOutputRoot `
                    -ExpectedRootIdentity $generatedOutputIdentity `
                    -RunnerSid $runnerIdentity.User.Value `
                    -Description 'Generated-output unsafe-ACL fixture' `
                    -HeldFileLocks $releasePathSentinelLocks | Out-Null
                $generatedOutputUnsafeAclRejected = $false
            } catch {
                if ($_.Exception.Message -notlike '*can be replaced or modified*') {
                    throw
                }
            }
        } finally {
            if ($unsafeOutputKind -ceq 'file') {
                [IO.File]::Delete($unsafeOutputPath)
            } else {
                [IO.Directory]::Delete($unsafeOutputPath)
            }
        }
    }
    Assert-EverVigilGeneratedOutputTreeState `
        -RootPath $generatedOutputRoot `
        -ExpectedRootIdentity $generatedOutputIdentity `
        -RunnerSid $runnerIdentity.User.Value `
        -Description 'Generated-output fixture' `
        -HeldFileLocks $releasePathSentinelLocks | Out-Null

    $generatedOutputWrongIdentity = [pscustomobject]@{
        Volume = $generatedOutputIdentity.Volume
        VolumeSerialNumber = $generatedOutputIdentity.VolumeSerialNumber
        FileId = '0000000000000000'
        RelativePath = $generatedOutputIdentity.RelativePath
        CanonicalPath = $generatedOutputIdentity.CanonicalPath
    }
    $generatedOutputIdentityMismatchRejected = $false
    try {
        Assert-EverVigilGeneratedOutputTreeState `
            -RootPath $generatedOutputRoot `
            -ExpectedRootIdentity $generatedOutputWrongIdentity `
            -RunnerSid $runnerIdentity.User.Value `
            -Description 'Generated-output identity fixture' `
            -HeldFileLocks $releasePathSentinelLocks | Out-Null
    } catch {
        $generatedOutputIdentityMismatchRejected =
            $_.Exception.Message -like '*identity changed*'
    }

    $generatedOutputJunction = Join-Path $generatedOutputRoot 'linked-output'
    New-Item `
        -ItemType Junction `
        -Path $generatedOutputJunction `
        -Target $releasePathWorkspaceTarget `
        -ErrorAction Stop | Out-Null
    $generatedOutputReparseRejected = $false
    try {
        Assert-EverVigilGeneratedOutputTreeState `
            -RootPath $generatedOutputRoot `
            -ExpectedRootIdentity $generatedOutputIdentity `
            -RunnerSid $runnerIdentity.User.Value `
            -Description 'Generated-output reparse fixture' `
            -HeldFileLocks $releasePathSentinelLocks | Out-Null
    } catch {
        $generatedOutputReparseRejected = $_.Exception.Message -like '*reparse entry*'
    }
    [IO.Directory]::Delete($generatedOutputJunction)
    Close-EverVigilDirectorySentinelLocks -Locks $releasePathSentinelLocks
    $releasePathSentinelLocks = @()

    foreach ($sourceDirectory in @('src\nested', '.git', 'artifacts')) {
        [IO.Directory]::CreateDirectory(
            (Join-Path $sourceWorkspace $sourceDirectory)) | Out-Null
    }
    $lockedSourcePath = Join-Path $sourceWorkspace 'src\locked.cs'
    $nestedSourcePath = Join-Path $sourceWorkspace 'src\nested\data.txt'
    [IO.File]::WriteAllText(
        $lockedSourcePath,
        'internal sealed class LockedSource {}',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $nestedSourcePath,
        'NESTED',
        [Text.UTF8Encoding]::new($false))
    $releasePathSourceTreeLocks = New-EverVigilSourceTreeLocks `
        -WorkspaceRoot $sourceWorkspace `
        -RunnerSid $runnerIdentity.User.Value `
        -ExcludedRootNames @('.git', 'artifacts')
    $sourceLocksExact =
        @($releasePathSourceTreeLocks.FileLocks).Count -eq 2 -and
        @($releasePathSourceTreeLocks.DirectoryLocks).Count -eq 3
    Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks
    $sourceWriteRejected = $false
    try {
        [IO.File]::WriteAllText($lockedSourcePath, 'CHANGED')
    } catch [IO.IOException] {
        $sourceWriteRejected = $true
    } catch [UnauthorizedAccessException] {
        $sourceWriteRejected = $true
    }
    $sourceRenameRejected = $false
    try {
        [IO.File]::Move($lockedSourcePath, "$lockedSourcePath.moved")
    } catch [IO.IOException] {
        $sourceRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $sourceRenameRejected = $true
    }
    $excludedGitPath = Join-Path $sourceWorkspace '.git\mutable.txt'
    $excludedArtifactPath = Join-Path $sourceWorkspace 'artifacts\mutable.txt'
    [IO.File]::WriteAllText($excludedGitPath, 'GIT')
    [IO.File]::WriteAllText($excludedArtifactPath, 'ARTIFACT')
    $sourceExcludedWritable =
        (Get-Content -LiteralPath $excludedGitPath -Raw) -ceq 'GIT' -and
        (Get-Content -LiteralPath $excludedArtifactPath -Raw) -ceq 'ARTIFACT'
    $injectedSourcePath = Join-Path $sourceWorkspace 'src\injected.cs'
    [IO.File]::WriteAllText($injectedSourcePath, 'internal sealed class InjectedSource {}')
    $sourceInjectionRejected = $false
    try {
        Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks
    } catch {
        $sourceInjectionRejected =
            $_.Exception.Message -like '*non-generated source tree changed*'
    }
    [IO.File]::Delete($injectedSourcePath)
    Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks
    $sourceStateRecovered = $true

    $generatedSourceDirectory = Join-Path $sourceWorkspace 'src\obj'
    [IO.Directory]::CreateDirectory($generatedSourceDirectory) | Out-Null
    $generatedSourcePath = Join-Path $generatedSourceDirectory 'generated.props'
    [IO.File]::WriteAllText($generatedSourcePath, '<Project />')
    Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks
    $postLockGeneratedOutputAccepted = $true
    $generatedSourceAcl = Get-Acl -LiteralPath $generatedSourcePath -ErrorAction Stop
    $generatedSourceAcl.SetAccessRuleProtection($true, $true)
    $generatedSourceAcl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $builtinUsersSid,
            [Security.AccessControl.FileSystemRights]::WriteData,
            [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl `
        -LiteralPath $generatedSourcePath `
        -AclObject $generatedSourceAcl `
        -ErrorAction Stop
    $postLockGeneratedAclRejected = $false
    try {
        Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks
    } catch {
        $postLockGeneratedAclRejected =
            $_.Exception.Message -like '*can be replaced or modified*'
    }
    [IO.File]::Delete($generatedSourcePath)
    [IO.File]::WriteAllText($generatedSourcePath, '<Project />')
    Assert-EverVigilSourceTreeLockState -LockSet $releasePathSourceTreeLocks

    $preexistingGeneratedWorkspace = Join-Path `
        $releasePathFixtureRoot `
        'source-preexisting-generated-workspace'
    [IO.Directory]::CreateDirectory($preexistingGeneratedWorkspace) | Out-Null
    Set-Acl `
        -LiteralPath $preexistingGeneratedWorkspace `
        -AclObject $sourceWorkspaceSecurity `
        -ErrorAction Stop
    [IO.Directory]::CreateDirectory(
        (Join-Path $preexistingGeneratedWorkspace 'src\obj')) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $preexistingGeneratedWorkspace 'src\obj\stale.props'),
        '<Project />')
    $preexistingGeneratedOutputRejected = $false
    try {
        $unexpectedGeneratedLocks = New-EverVigilSourceTreeLocks `
            -WorkspaceRoot $preexistingGeneratedWorkspace `
            -RunnerSid $runnerIdentity.User.Value
        Close-EverVigilSourceTreeLocks -LockSet $unexpectedGeneratedLocks
    } catch {
        $preexistingGeneratedOutputRejected =
            $_.Exception.Message -like '*fresh reviewed source checkout contains generated output*'
    }

    $sourceReparseWorkspace = Join-Path $releasePathFixtureRoot 'source-reparse-workspace'
    [IO.Directory]::CreateDirectory($sourceReparseWorkspace) | Out-Null
    Set-Acl `
        -LiteralPath $sourceReparseWorkspace `
        -AclObject $sourceWorkspaceSecurity `
        -ErrorAction Stop
    [IO.Directory]::CreateDirectory(
        (Join-Path $sourceReparseWorkspace 'src')) | Out-Null
    New-Item `
        -ItemType Junction `
        -Path (Join-Path $sourceReparseWorkspace 'src\linked') `
        -Target $releasePathWorkspaceTarget `
        -ErrorAction Stop | Out-Null
    $sourceReparseRejected = $false
    try {
        $unexpectedSourceLocks = New-EverVigilSourceTreeLocks `
            -WorkspaceRoot $sourceReparseWorkspace `
            -RunnerSid $runnerIdentity.User.Value
        Close-EverVigilSourceTreeLocks -LockSet $unexpectedSourceLocks
    } catch {
        $sourceReparseRejected = $_.Exception.Message -like '*reparse entry*'
    }

    Close-EverVigilSourceTreeLocks -LockSet $releasePathSourceTreeLocks
    $releasePathSourceTreeLocks = $null
    [IO.File]::WriteAllText($lockedSourcePath, 'CHANGED')
    [IO.File]::Move($lockedSourcePath, "$lockedSourcePath.moved")
    [IO.File]::Move("$lockedSourcePath.moved", $lockedSourcePath)
    $sourceLocksReleased =
        (Get-Content -LiteralPath $lockedSourcePath -Raw) -ceq 'CHANGED'
    $releasePathDrive = $null

    $freshRoot = Join-Path $releasePathFixtureRoot 'fresh-root'
    New-EverVigilFreshIsolatedRoot `
        -Root $releasePathFixtureRoot `
        -Path $freshRoot `
        -Description 'Fresh-root fixture' | Out-Null
    $existingRootRejected = $false
    try {
        New-EverVigilFreshIsolatedRoot `
            -Root $releasePathFixtureRoot `
            -Path $freshRoot `
            -Description 'Existing-root fixture' | Out-Null
    } catch {
        $existingRootRejected = $true
    }
    $nestedRoot = New-EverVigilIsolatedDirectory `
        -Root $freshRoot `
        -Path (Join-Path $freshRoot 'profile\AppData\Local') `
        -Description 'Nested fixture'
    $releasePathDirectoryLocks = @(Lock-EverVigilDirectoryAncestries `
        -Paths @($releasePathFixtureRoot, $freshRoot, $nestedRoot) `
        -Description 'Release-path fixture')
    $directoryLocksLive =
        @($releasePathDirectoryLocks).Count -ne 0 -and
        @($releasePathDirectoryLocks | Where-Object { -not $_.IsAlive }).Count -eq 0
    $directoryRenameRejected = $false
    try {
        [IO.Directory]::Move($freshRoot, "$freshRoot.moved")
    } catch [IO.IOException] {
        $directoryRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $directoryRenameRejected = $true
    }
    Close-EverVigilDirectoryLocks -Locks $releasePathDirectoryLocks
    $releasePathDirectoryLocks = @()

    $releasePathSentinelLocks = @(New-EverVigilDirectorySentinelLocks `
        -Paths @($freshRoot, $nestedRoot) `
        -Description 'Release-path fixture')
    $sentinelPaths = @($releasePathSentinelLocks | ForEach-Object Name)
    $sentinelsExact =
        @($releasePathSentinelLocks).Count -eq 2 -and
        @($releasePathSentinelLocks | Where-Object {
            -not $_.CanRead -or -not $_.CanWrite -or $_.Length -ne 32
        }).Count -eq 0 -and
        @($sentinelPaths | Where-Object {
            $item = Get-Item -LiteralPath $_ -Force -ErrorAction Stop
            $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Length -ne 32
        }).Count -eq 0
    $sentinelDeleteRejected = $false
    try {
        [IO.File]::Delete($sentinelPaths[0])
    } catch [IO.IOException] {
        $sentinelDeleteRejected = $true
    } catch [UnauthorizedAccessException] {
        $sentinelDeleteRejected = $true
    }
    $sentinelRenameRejected = $false
    try {
        [IO.Directory]::Move($freshRoot, "$freshRoot.moved")
    } catch [IO.IOException] {
        $sentinelRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $sentinelRenameRejected = $true
    }
    Close-EverVigilDirectorySentinelLocks -Locks $releasePathSentinelLocks
    $releasePathSentinelLocks = @()
    $sentinelsRemoved = @($sentinelPaths | Where-Object {
        Test-Path -LiteralPath $_
    }).Count -eq 0
    [IO.Directory]::Move($freshRoot, "$freshRoot.moved")
    [IO.Directory]::Move("$freshRoot.moved", $freshRoot)
    $locksReleased = Test-Path -LiteralPath $freshRoot -PathType Container

    if (-not $relativeRejected -or
        -not $insideWorkspaceRejected -or
        -not $junctionRejected -or
        -not $driveAliasRejected -or
        -not $rawDriveAliasRejected -or
        -not $genericAclRejected -or
        -not $nullDaclRejected -or
        -not $generatedOutputSentinelAccepted -or
        -not $generatedOutputUnsafeAclRejected -or
        -not $generatedOutputIdentityMismatchRejected -or
        -not $generatedOutputReparseRejected -or
        -not $sourceLocksExact -or
        -not $sourceWriteRejected -or
        -not $sourceRenameRejected -or
        -not $sourceExcludedWritable -or
        -not $sourceInjectionRejected -or
        -not $sourceStateRecovered -or
        -not $postLockGeneratedOutputAccepted -or
        -not $postLockGeneratedAclRejected -or
        -not $preexistingGeneratedOutputRejected -or
        -not $sourceReparseRejected -or
        -not $sourceLocksReleased -or
        -not $existingRootRejected -or
        -not $directoryLocksLive -or
        -not $directoryRenameRejected -or
        -not $sentinelsExact -or
        -not $sentinelDeleteRejected -or
        -not $sentinelRenameRejected -or
        -not $sentinelsRemoved -or
        -not $locksReleased -or
        (Get-FileHash -LiteralPath $workspaceTargetMarker -Algorithm SHA256).Hash -cne
            $workspaceTargetHash) {
        $failures.Add(
            'Release path isolation did not reject a relative, workspace, reparse, alias, ' +
            'generic/null ACL, source-tree mutation, pre-existing-root, independent lock, ' +
            'or cleanup negative fixture.')
    }
} catch {
    $failures.Add("Release path isolation fixture failed: $($_.Exception.Message)")
} finally {
    try {
        Close-EverVigilSourceTreeLocks -LockSet $releasePathSourceTreeLocks
    } catch {
        $failures.Add("Source-tree fixture cleanup failed: $($_.Exception.Message)")
    }
    try {
        Close-EverVigilDirectorySentinelLocks -Locks $releasePathSentinelLocks
    } catch {
        $failures.Add("Sentinel fixture cleanup failed: $($_.Exception.Message)")
    }
    try {
        Close-EverVigilDirectoryLocks -Locks $releasePathDirectoryLocks
    } catch {
        $failures.Add("Directory-lock fixture cleanup failed: $($_.Exception.Message)")
    }
    if ($releasePathRawAliasActive -and
        $null -ne $releasePathRawAliasTarget -and $null -ne $releasePathDrive) {
        try {
            [EverVigil.ReleasePathAliasFixture]::Remove(
                $releasePathDrive,
                $releasePathRawAliasTarget)
            $releasePathRawAliasActive = $false
        } catch {
            $failures.Add("Raw drive-alias cleanup failed: $($_.Exception.Message)")
        }
    }
    if ($releasePathSubstActive -and $null -ne $releasePathDrive) {
        try {
            & (Join-Path $env:SystemRoot 'System32\subst.exe') $releasePathDrive /D | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "subst cleanup failed with exit code $LASTEXITCODE."
            }
            $releasePathSubstActive = $false
        } catch {
            $failures.Add("Subst fixture cleanup failed: $($_.Exception.Message)")
        }
    }
    if ($releasePathFixtureRoot.StartsWith(
            ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item `
            -LiteralPath $releasePathFixtureRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ($releasePathWorkspaceTarget.StartsWith(
            ([IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'artifacts')).TrimEnd('\') + '\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item `
            -LiteralPath $releasePathWorkspaceTarget `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

$releaseHostLockContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot '.github\release-host-lock.json') `
    -Raw
$releaseHostTestContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\Test-ReleaseHost.ps1') `
    -Raw
foreach ($releaseHostGuard in @(
        'evervigil-win11-pro-amd64-2026-08-18'
        '"schemaVersion": 3'
        '$root.GetProperty(''schemaVersion'').GetInt32() -ne 3'
        'schemaVersion = 3'
        '"hostPath": "C:\\Program Files\\EverVigil Release Host\\Invoke-ReleaseShell.cmd"'
        '"sha256": "30a75e30a3b3ba29b5b2b809c3805929351c95f78de7ddb82bfc37ffbb789a23"'
        'The reviewed release shell hash does not match.'
        '"buildNumber": "26200"'
        '"executablePath": "C:\\Program Files\\Tailscale\\tailscale.exe"'
        '"compilerPath": "C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe"'
        '"sdkVersion": "8.0.130"'
        '"nugetProtocolPath": "C:\\Program Files\\dotnet\\sdk\\8.0.130\\NuGet.Protocol.dll"'
        '"nugetProtocolVersion": "6.8.2.3"'
        '"nugetProtocolSha256": "2aeb20c4edd7a0f1efd54d499c9cf8009bf9a54520a660a0da0657c579d75c89"'
        'The reviewed NuGet protocol assembly hash does not match.'
        'nugetProtocolSignerSubject'
        '"hostPath": "C:\\Program Files\\PowerShell\\7\\pwsh.exe"'
        '"compilerPath": "C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\rc.exe"'
        'officialMsiSha256'
        'Get-AuthenticodeSignature'
        'RequireSingleLink'
        'Assert-EverVigilAccessControlDescriptor'
        'Assert-ReleaseHostNullDaclGuard'
        'Lock-ReleaseHostCriticalSourceFile'
        'A release-host critical source file has a null discretionary ACL'
        'Test-DedicatedStandardUserGroupRows'
        '''S-1-5-32-544'''
        '''S-1-5-114'''
        'The release-host standard-user guard accepted a deny-only Administrators token.'
        'The release runner token groups could not be enumerated.'
        'Release-host evidence must be written only to the reviewed artifacts root.'
        '[IO.FileMode]::CreateNew'
        '[IO.FileOptions]::WriteThrough'
        '$evidenceStream.Flush($true)'
        'S-1-16-8192'
        'RUNNER_ENVIRONMENT'
        'EVERVIGIL_RELEASE_EPHEMERAL'
        'one-job ephemeral runner'
        'PSModulePath -cne $expectedModulePath'
        '''DOTNET_'''
        '''CORECLR_'''
        '''COMPLUS_'''
        '''MSBUILD'''
        '''NUGET_'''
        '''RESTORE'''
        '$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(''\'')'
        '$releasePathIsolationPath = Join-Path $RepositoryRoot ''tests\ReleasePathIsolation.ps1'''
        '$null -eq (Get-Command Assert-EverVigilReleaseStateDirectorySecurity -ErrorAction SilentlyContinue)'
        'The release-host working directory must exactly match GITHUB_WORKSPACE.'
        'Assert-EverVigilReleaseStateDirectorySecurity'
        'Lock-EverVigilDirectoryAncestries'
        'New-EverVigilDirectorySentinelLocks'
        'EVERVIGIL_RELEASE_SNAPSHOT_ID'
        'refs/heads/main')) {
    if (-not ($releaseHostLockContent + $releaseHostTestContent).Contains(
            $releaseHostGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Dedicated release-host contract is missing: $releaseHostGuard")
    }
}
if ($releaseHostTestContent.Contains(
        '@($identity.Groups.Value)',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'The dedicated release-host guard still ignores deny-only administrator groups.')
}

$brokerTestRunnerContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\EverVigil.Broker.Tests\Program.cs') `
    -Raw
foreach ($brokerSkipGuard in @(
        '--fail-on-skip'
        'Fail-on-skip policy rejects skipped tests'
        'BrokerTestExitCode(0, 1, failOnSkip: true) != 0'
        'return BrokerTestExitCode(failures.Count, skipped.Count, failOnSkip);'
    )) {
    if (-not $brokerTestRunnerContent.Contains($brokerSkipGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Broker fail-on-skip negative contract is missing: $brokerSkipGuard")
    }
}
if ($releaseWorkflowContent -match '(?m)^\s{2}(?:push|pull_request|schedule):\s*$' -or
    $releaseWorkflowContent -match '(?m)^\s+tags:\s*$' -or
    $releaseWorkflowContent.Contains('gh release edit', [StringComparison]::OrdinalIgnoreCase) -or
    $releaseWorkflowContent.Contains('--draft=false', [StringComparison]::OrdinalIgnoreCase)) {
    $failures.Add(
        'Release candidates must be manual, approval-gated, draft, and prerelease-only.')
}
if ($releaseWorkflowContent.Contains('-win-x64.zip', [StringComparison]::Ordinal) -or
    $releaseWorkflowContent.Contains(
        '(Get-Content .\RELEASE_NOTES.md -Raw).TrimEnd() +',
        [StringComparison]::Ordinal)) {
    $failures.Add('GitHub Releases must not publish a ZIP or compose release notes by unchecked concatenation.')
}

$versionValidatorPath = Join-Path $RepositoryRoot 'scripts\Test-ReleaseVersion.ps1'
foreach ($validVersion in @('0.0.0', '1.0.0', '10.20.30-0', '1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-x-y')) {
    try {
        $validatedVersion = & $versionValidatorPath -Version $validVersion
        $validatedTagVersion = & $versionValidatorPath -Tag "v$validVersion"
        if ($validatedVersion -ne $validVersion -or $validatedTagVersion -ne $validVersion) {
            $failures.Add("Canonical release version changed during validation: $validVersion")
        }
    } catch {
        $failures.Add("Canonical release version was rejected: $validVersion ($($_.Exception.Message))")
    }
}
foreach ($invalidVersion in @(
        '01.0.0'
        '1.00.0'
        '1.0.01'
        '1.0.0-01'
        '1.0.0-alpha.01'
        '1.0.0-alpha..1'
        '1.0.0+build'
        'v1.0.0'
    )) {
    $invalidVersionRejected = $false
    try {
        & $versionValidatorPath -Version $invalidVersion -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $invalidVersionRejected = $true
    }
    if (-not $invalidVersionRejected) {
        $failures.Add("Noncanonical release version was accepted: $invalidVersion")
    }
}
foreach ($invalidTag in @('1.0.0', 'vv1.0.0', 'v1.0.0-01')) {
    $invalidTagRejected = $false
    try {
        & $versionValidatorPath -Tag $invalidTag -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $invalidTagRejected = $true
    }
    if (-not $invalidTagRejected) {
        $failures.Add("Noncanonical release tag was accepted: $invalidTag")
    }
}
foreach ($workflow in @(
        [pscustomobject]@{ Name = 'validate'; Content = $validateWorkflowContent }
        [pscustomobject]@{ Name = 'release'; Content = $releaseWorkflowContent }
    )) {
    if (-not $workflow.Content.Contains(
            '.\scripts\Test-NuGetVulnerabilities.ps1 -SolutionPath .\EverVigil.sln',
            [StringComparison]::Ordinal)) {
        $failures.Add("$($workflow.Name) workflow does not use the machine-readable NuGet vulnerability gate.")
    }
    if ($workflow.Content -match '(?i)dotnet\s+list\b[^\r\n]*--vulnerable') {
        $failures.Add("$($workflow.Name) workflow bypasses the parsed NuGet vulnerability gate.")
    }
}

$nugetAuditScript = Join-Path $RepositoryRoot 'scripts\Test-NuGetVulnerabilities.ps1'
$nugetFixtureRoot = Join-Path $env:TEMP "EverVigil.NuGetAudit-$PID-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $nugetFixtureRoot | Out-Null
    $cleanAuditPath = Join-Path $nugetFixtureRoot 'clean.json'
    $vulnerableAuditPath = Join-Path $nugetFixtureRoot 'vulnerable.json'
    @{
        version = 1
        projects = @(@{ path = 'Sample.csproj'; frameworks = @() })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cleanAuditPath -Encoding UTF8
    @{
        version = 1
        projects = @(@{
                path = 'Sample.csproj'
                frameworks = @(@{
                        framework = 'net8.0'
                        topLevelPackages = @(@{
                                id = 'Example.Package'
                                resolvedVersion = '1.0.0'
                                vulnerabilities = @(@{
                                        severity = 'High'
                                        advisoryUrl = 'https://example.invalid/advisory'
                                    })
                            })
                        transitivePackages = @()
                    })
            })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $vulnerableAuditPath -Encoding UTF8

    try {
        & $nugetAuditScript -AuditJsonPath $cleanAuditPath | Out-Null
    } catch {
        $failures.Add("Clean NuGet audit fixture failed: $($_.Exception.Message)")
    }
    $vulnerabilityRejected = $false
    try {
        & $nugetAuditScript -AuditJsonPath $vulnerableAuditPath | Out-Null
    } catch {
        $vulnerabilityRejected =
            $_.Exception.Message.Contains('Example.Package', [StringComparison]::Ordinal) -and
            $_.Exception.Message.Contains('example.invalid/advisory', [StringComparison]::Ordinal)
    }
    if (-not $vulnerabilityRejected) {
        $failures.Add('NuGet vulnerability gate did not reject a machine-readable vulnerability finding.')
    }
} finally {
    Remove-Item -LiteralPath $nugetFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$legacyRuntimeFiles = @(
    'Deploy.ps1'
    'scripts\Start-EvenTerminalCodex.ps1'
    'scripts\Install-EvenTerminalCodexTask.ps1'
    'scripts\Invoke-ElevatedInstall.ps1'
    'scripts\Get-EvenTerminalCodexStatus.ps1'
    'scripts\Get-EvenTerminalCodexUrl.ps1'
    'scripts\Show-EvenTerminalCodexConnection.ps1'
)
foreach ($relativePath in $legacyRuntimeFiles) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relativePath)) {
        $failures.Add("Legacy runtime file remains: $relativePath")
    }
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -Filter '*.ps1' -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/](?:bin|obj|artifacts)[\\/]' })
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in $parseErrors) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
        $failures.Add("PowerShell parse error: ${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}

$forbiddenNames = @(
    'token.txt'
    'token.dat'
    'settings.json'
    'state.json'
    'supervisor.lock'
    'diagnostic-logging.enabled'
)
foreach ($file in Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse -Force) {
    if ($file.FullName -match '[\\/](?:\.git|bin|obj|artifacts)[\\/]') {
        continue
    }
    $isEnvironmentFile = $file.Name.Equals('.env', [StringComparison]::OrdinalIgnoreCase) -or
        $file.Name.StartsWith('.env.', [StringComparison]::OrdinalIgnoreCase)
    if ($file.Name -in $forbiddenNames -or
        $file.Extension -eq '.log' -or
        $file.Extension -eq '.user' -or
        $isEnvironmentFile) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
        $failures.Add("Forbidden runtime or user file present: $relativePath")
    }
}

$secretPatterns = [ordered]@{
    'GitHub token' = '\b(?:gh[opsur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
    'OpenAI key' = '\bsk-(?:(?:proj|svcacct|admin)-)?[A-Za-z0-9_-]{20,}\b'
    'Private key' = '-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----'
    'Even Terminal token value' = '(?i)(?:["'']?token["'']?\s*(?:=|:|%3D)\s*["'']?|bearer\s+)[0-9a-f]{32}\b'
}
$scanFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse |
    Where-Object {
        $_.FullName -notmatch '[\\/](?:\.git|bin|obj|artifacts)[\\/]' -and
        ($_.Extension -in @(
                '.bat', '.cmd', '.conf', '.config', '.cs', '.csproj', '.editorconfig',
                '.gitattributes', '.gitignore', '.ini', '.iss', '.isl', '.json', '.manifest', '.md',
                '.properties', '.props', '.ps1', '.psd1', '.psm1', '.resx', '.sh',
                '.sln', '.targets', '.toml', '.txt', '.xml', '.yaml', '.yml'
            ) -or
            $_.Name.Equals('.env', [StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.env.', [StringComparison]::OrdinalIgnoreCase))
    })
$legacyAssetStem = 'even' + '-realities'
$prohibitedLegacyAssetNames = @(
    $legacyAssetStem + '-favicon.png'
    $legacyAssetStem + '.ico'
)
$prohibitedLegacyReferences = @(
    $prohibitedLegacyAssetNames
    ('https://www.' + 'evenrealities.com/android-chrome-' + '512x512.png')
    ('Official ' + 'logo')
    ('official ' + 'Even Realities icon')
    ('Even Realities' + '公式' + 'アイコン')
    ('公式' + 'アイコン')
    ('公式' + 'ロゴ')
    ('upstream ' + 'brand asset')
    ('brand assets are not covered by ' + 'GPL')
    ('brand assets are excluded from ' + 'GPL coverage')
    ('ブランド資産は' + 'GPL対象外')
)
$legacyBrandDigests = @(
    '520F30AD208EE7F88F10E2CBC08A0169' + 'D2B3C0BBF8D57C34A6E9207E4FD8DAA6'
    '5450B5B0300267199207DE95CE795A3' + '52C174BBB37661471C96D24D6FA7007D8'
)
$repositoryFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse -Force |
    Where-Object {
        $_.FullName -notmatch '[\\/](?:\.git|\.jj|bin|obj|artifacts)[\\/]'
    })
foreach ($repositoryFile in $repositoryFiles) {
    if ($repositoryFile.Name -in $prohibitedLegacyAssetNames) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $repositoryFile.FullName)
        $failures.Add("A prohibited legacy brand asset file remains: $relativePath")
    }
    $digest = (Get-FileHash -LiteralPath $repositoryFile.FullName -Algorithm SHA256).Hash
    if ($digest -in $legacyBrandDigests) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $repositoryFile.FullName)
        $failures.Add("A file matches a prohibited legacy brand digest: $relativePath")
    }
}
foreach ($file in $scanFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($prohibitedReference in @($prohibitedLegacyReferences + $legacyBrandDigests)) {
        if ($content.IndexOf(
                $prohibitedReference,
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
            $failures.Add("A prohibited legacy brand reference remains in: $relativePath")
        }
    }
    foreach ($entry in $secretPatterns.GetEnumerator()) {
        if ($content -match $entry.Value) {
            $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
            $failures.Add("Potential $($entry.Key) found in: $relativePath")
        }
    }
}

$applicationProject = [xml](Get-Content -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\EverVigil.csproj') -Raw)
if ($applicationProject.Project.PropertyGroup.OutputType -ne 'WinExe') {
    $failures.Add('Application OutputType must be WinExe.')
}
$applicationManifest = [xml](Get-Content -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\app.manifest') -Raw)
$manifestIdentity = $applicationManifest.assembly.assemblyIdentity
$projectVersion = [string]$applicationProject.Project.PropertyGroup.Version
if ($projectVersion -cne '2.1.1') {
    $failures.Add("The EverVigil release version must be exactly 2.1.1, not '$projectVersion'.")
}
$expectedManifestVersion = ConvertTo-WindowsManifestVersion -Version $projectVersion
if ($manifestIdentity.name -ne 'EverVigil.app' -or
    $manifestIdentity.version -ne $expectedManifestVersion) {
    $failures.Add(
        "The Windows application manifest identity must match version $projectVersion.")
}
if ($applicationProject.Project.PropertyGroup.PackageLicenseExpression -ne 'GPL-3.0-only' -or
    $applicationProject.Project.PropertyGroup.Authors -ne 'Daichi Matsumoto' -or
    $applicationProject.Project.PropertyGroup.Company -ne 'Daichi Matsumoto' -or
    $applicationProject.Project.PropertyGroup.Copyright -ne 'Copyright © 2026 Daichi Matsumoto') {
    $failures.Add('Application metadata must identify Daichi Matsumoto and GPL-3.0-only.')
}
if ($applicationProject.Project.PropertyGroup.InformationalVersion -ne '2.1.1' -or
    $applicationProject.Project.PropertyGroup.IncludeSourceRevisionInInformationalVersion -ne 'false') {
    $failures.Add('Release VersionInfo must not include the temporary pre-initialization Git revision.')
}
$applicationIconNodes = @($applicationProject.SelectNodes(
        '/Project/PropertyGroup/ApplicationIcon'))
$applicationManifestNodes = @($applicationProject.SelectNodes(
        '/Project/PropertyGroup/ApplicationManifest'))
if ($applicationProject.Project.PropertyGroup.NoWin32Manifest -ne 'true' -or
    -not $applicationProject.Project.PropertyGroup.Win32Resource -or
    [string]$applicationProject.Project.PropertyGroup.EverVigilPowerShellPath.InnerText -cne 'pwsh' -or
    $applicationIconNodes.Count -gt 0 -or
    $applicationManifestNodes.Count -gt 0) {
    $failures.Add('EverVigil must use the single custom Win32 resource for manifest, icon, and VersionInfo.')
}
$win32ResourceSource = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\EverVigil.rc') `
    -Raw
foreach ($win32ResourceGuard in @(
        '1 RT_MANIFEST "app.manifest"'
        '32512 ICON "Assets\\evervigil-placeholder.ico"'
        'VALUE "OriginalFilename", "EverVigil.exe\0"'
        'VALUE "ProductVersion", "2.1.1\0"'
    )) {
    if (-not $win32ResourceSource.Contains($win32ResourceGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Custom Win32 resource guard is missing: $win32ResourceGuard")
    }
}
$projectLicensePath = Join-Path $RepositoryRoot 'LICENSE'
if ((Get-FileHash -LiteralPath $projectLicensePath -Algorithm SHA256).Hash -ne
    '3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986') {
    $failures.Add('The checked-in verbatim GNU GPLv3 license text changed unexpectedly.')
}
$innoLicensePath = Join-Path $RepositoryRoot 'licenses\INNO-SETUP-LICENSE.txt'
if ((Get-FileHash -LiteralPath $innoLicensePath -Algorithm SHA256).Hash -ne
    '48BF0CC6A6204435295F240612C247E424F0C69025321AACC560B4016978668B') {
    $failures.Add('The checked-in Inno Setup 6.7.1 license changed unexpectedly.')
}
$qrPackage = @($applicationProject.SelectNodes("/Project/ItemGroup/PackageReference[@Include='QRCoder']"))
if ($qrPackage.Count -ne 1 -or -not $qrPackage[0].GetAttribute('Version')) {
    $failures.Add('QRCoder must be pinned to an explicit version.')
}
$qrLicensePath = Join-Path $RepositoryRoot 'licenses\QRCODER-LICENSE.txt'
if ((Get-FileHash -LiteralPath $qrLicensePath -Algorithm SHA256).Hash -ne
    '22E4C25E35C416B15F655A62378D964597C15C6C27FE2FF123444491EEC0649B') {
    $failures.Add('The checked-in QRCoder 1.8.0 license changed unexpectedly.')
}
$buildReleaseContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Build-Release.ps1') `
    -Raw
$resourceCompilerContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Compile-WindowsResource.ps1') `
    -Raw
foreach ($trustedResourceGuard in @(
        '[string]$PowerShellPath'
        '[string]$ResourceCompilerPath'
        'Trusted release compilation must run under the explicitly reviewed PowerShell executable.'
        'Trusted release compilation requires the explicitly reviewed Windows resource compiler.'
        '-p:EverVigilPowerShellPath='
        '-p:EverVigilResourceCompilerPath='
        '-p:ContinuousIntegrationBuild=true'
        '-p:DirectoryBuildPropsPath='
        '-p:ImportDirectoryBuildTargets=false'
        '-p:RestoreConfigFile='
        '-p:RestoreSources=https://api.nuget.org/v3/index.json'
        '-p:RestoreFallbackFolders='
        '-p:RestoreAdditionalProjectSources='
        '-p:RestoreAdditionalProjectFallbackFolders='
        '-p:RestorePackagesWithLockFile=true'
        '-p:RestoreLockedMode=true'
        '-p:ImportUserLocationsByWildcardBeforeMicrosoftCommonProps=false'
        '-p:ImportUserLocationsByWildcardAfterMicrosoftCommonTargets=false'
        '-p:ImportUserLocationsByWildcardBeforeMicrosoftCSharpTargets=false'
        '-p:ImportUserLocationsByWildcardAfterMicrosoftCSharpTargets=false'
        '[string]$CompilerPath'
        'An explicitly selected Windows resource compiler path must be absolute.')) {
    if (-not ($buildReleaseContent + $resourceCompilerContent).Contains(
            $trustedResourceGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Trusted PowerShell/resource-compiler gate is missing: $trustedResourceGuard")
    }
}
if ([regex]::Matches($buildReleaseContent, '(?m)^\s*&\s+\$dotnetCommand\.Source\s+publish\s+`').Count -ne 3 -or
    [regex]::Matches($buildReleaseContent, '(?m)^\s+--no-restore\s+`').Count -lt 3) {
    $failures.Add('Every release publish must consume the one locked restore without performing an implicit restore.')
}
foreach ($formalBrokerSkipGuard in @(
        "[ValidateSet('RequireNone', 'Report')]"
        '[string]$BrokerTestSkipPolicy = ''RequireNone'''
        "'tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj'"
        "if (`$BrokerTestSkipPolicy -eq 'RequireNone')"
        "@('--', '--fail-on-skip')"
        '$brokerTestBuildArguments'
        "foreach (`$releaseCleanRuntimeIdentifier in @(`$null, 'win-x64'))"
        "'clean'"
        '$solutionPath'
        "'-p:PublishAot=false'"
        '$releaseCleanArguments += @($toolchainBuildProperties)'
        'Release output cleanup failed with exit code'
        "'-m:1'"
        "'-p:PublishAot=false'"
        "'--no-build'"
        'Privileged broker release-gate build failed with exit code'
        'Privileged broker release-gate tests failed with exit code'
    )) {
    if (-not $buildReleaseContent.Contains(
            $formalBrokerSkipGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Formal Build-Release broker skip gate is missing: $formalBrokerSkipGuard")
    }
}
$brokerManagedBuildMatch = [regex]::Match(
    $buildReleaseContent,
    '(?ms)^\$brokerTestBuildArguments\s*=\s*@\(\r?\n(?<body>.*?)^\)\r?\n\$brokerTestBuildArguments\s*\+=\s*@\(\$toolchainBuildProperties\)\r?\n& \$dotnetCommand\.Source @brokerTestBuildArguments$')
if (-not $brokerManagedBuildMatch.Success) {
    $failures.Add('Formal Build-Release managed broker-test build block is not uniquely identifiable.')
} else {
    $brokerManagedBuildBody = $brokerManagedBuildMatch.Groups['body'].Value
    foreach ($requiredManagedBuildArgument in @(
            "'build'"
            '$brokerTestProjectPath'
            "'--no-restore'"
            "'-m:1'"
            "'-p:PublishAot=false'"
        )) {
        if ([regex]::Matches(
                $brokerManagedBuildBody,
                [regex]::Escape($requiredManagedBuildArgument)).Count -ne 1) {
            $failures.Add(
                "Managed broker-test build argument must occur exactly once: $requiredManagedBuildArgument")
        }
    }
    foreach ($forbiddenManagedBuildArgument in @("'--project'", "'-p:PublishAot=true'")) {
        if ($brokerManagedBuildBody.Contains(
                $forbiddenManagedBuildArgument,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "Managed broker-test build retained a forbidden argument: $forbiddenManagedBuildArgument")
        }
    }
}
$brokerManagedRunMatch = [regex]::Match(
    $buildReleaseContent,
    '(?ms)^\$brokerTestArguments\s*=\s*@\(\r?\n(?<body>.*?)^\)\r?\nif \(\$BrokerTestSkipPolicy -eq ''RequireNone''\)')
if (-not $brokerManagedRunMatch.Success) {
    $failures.Add('Formal Build-Release managed broker-test run block is not uniquely identifiable.')
} else {
    $brokerManagedRunBody = $brokerManagedRunMatch.Groups['body'].Value
    foreach ($requiredManagedRunArgument in @(
            "'run'"
            "'--project'"
            '$brokerTestProjectPath'
            "'--no-build'"
        )) {
        if ([regex]::Matches(
                $brokerManagedRunBody,
                [regex]::Escape($requiredManagedRunArgument)).Count -ne 1) {
            $failures.Add(
                "Managed broker-test run argument must occur exactly once: $requiredManagedRunArgument")
        }
    }
    foreach ($forbiddenManagedRunArgument in @('PublishAot', '$toolchainBuildProperties')) {
        if ($brokerManagedRunBody.Contains(
                $forbiddenManagedRunArgument,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "Managed broker-test run retained a forbidden argument: $forbiddenManagedRunArgument")
        }
    }
}
$innoResolverContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Resolve-InnoCompiler.ps1') `
    -Raw
$interactiveTaskContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Invoke-InteractiveUserTask.ps1') `
    -Raw
if (-not $buildReleaseContent.Contains(
        "Join-Path `$repositoryRoot 'licenses\QRCODER-LICENSE.txt'",
        [StringComparison]::Ordinal) -or
    $buildReleaseContent.Contains('.nuget\packages\qrcoder', [StringComparison]::OrdinalIgnoreCase)) {
    $failures.Add('Release builds must source the QRCoder license from the repository.')
}
foreach ($guidedInstallerGuard in @(
        "Join-Path `$repositoryRoot 'installer\EverVigil.iss'"
        "Join-Path `$repositoryRoot 'licenses\INNO-SETUP-LICENSE.txt'"
        'Resolve-InnoCompiler'
        "Join-Path `$PSScriptRoot 'Resolve-InnoCompiler.ps1'"
        'New-InstallerWizardImage'
        '-PublishRoot $auditPublishRoot'
        '/AUDITEXTRACT='
        '-PackageRoot $auditExtractRoot'
        'EverVigil-$Version-Setup.exe'
        'EverVigil-$Version-PayloadAudit.exe'
        '-m:1'
        '-nr:false'
        '-p:UseSharedCompilation=false'
        '-BinaryPath $installerPath'
        '/DResourceAuditBuild=1'
        '/DResourceAuditAppId=A17D6AC4-2F11-45CF-A0BE-42C2F607F7B8'
        '/DPayloadAuditBuild=1'
        '/DPayloadAuditAppId=C8E6DE5F-A2D9-4D6B-889F-8CF43F588E88'
        '-PayloadAuditInstallerPath $payloadAuditInstallerPath'
        '-ProductionInstallerPath $installerPath'
        'The production installer must never be executed for payload extraction.'
        'Invoke-ReleaseResourceAudit.ps1'
        'resource-audit-report.json'
        'installer-notice-preview.txt'
        'function Test-InstallerAuditExtraction'
        'function Invoke-InstallerAuditExtraction'
        'function Test-PublishedLocalization'
        "`$startInfo.ArgumentList.Add('--verify-localization')"
        "Join-Path `$resolvedOutputRoot 'localization-smoke'"
        "Copy-Item -LiteralPath `$publishedExecutable -Destination `$isolatedExecutable"
        'if ($isolatedFiles.Count -ne 1)'
        'Test-PublishedLocalization -ExecutablePath $isolatedExecutable'
        'function Remove-ReleaseWorkingTreesWithRetry'
        '$attempt -le 3'
        'exactPayload='
        'Release working-tree cleanup failed after 3 attempts'
        'Get-FileHash'
        'SHA-256:'
    )) {
    if (-not $buildReleaseContent.Contains($guidedInstallerGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Guided installer release guard is missing: $guidedInstallerGuard")
    }
}
$releaseResourceAuditContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Invoke-ReleaseResourceAudit.ps1') `
    -Raw
if (-not $releaseResourceAuditContent.Contains(
        ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'The resource audit must exclude an absent current install location before binding protected paths.')
}
$releaseResourceAuditTokens = $null
$releaseResourceAuditParseErrors = $null
$releaseResourceAuditAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'scripts\Invoke-ReleaseResourceAudit.ps1'),
    [ref]$releaseResourceAuditTokens,
    [ref]$releaseResourceAuditParseErrors)
$resourceAuditProcessInvocations = @($releaseResourceAuditAst.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-HiddenProcess'
        },
        $true))
$productionInstallerResourceAuditExecutions = @($resourceAuditProcessInvocations | Where-Object {
        $_.Extent.Text.Contains('$InstallerPath', [StringComparison]::OrdinalIgnoreCase) -and
            -not $_.Extent.Text.Contains('$AuditInstallerPath', [StringComparison]::OrdinalIgnoreCase)
    })
$productionInstallerResourceAuditDirectExecutions = @($releaseResourceAuditAst.FindAll(
        {
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst] -or
                $node.CommandElements.Count -eq 0) {
                return $false
            }
            return [string]::Equals(
                $node.CommandElements[0].Extent.Text,
                '$InstallerPath',
                [StringComparison]::OrdinalIgnoreCase)
        },
        $true))
if ($releaseResourceAuditParseErrors.Count -gt 0 -or
    $resourceAuditProcessInvocations.Count -ne 2 -or
    @($resourceAuditProcessInvocations | Where-Object {
            $_.Extent.Text.Contains(
                '-FilePath ([IO.Path]::GetFullPath($AuditInstallerPath))',
                [StringComparison]::Ordinal)
        }).Count -ne 1 -or
    $productionInstallerResourceAuditExecutions.Count -ne 0 -or
    $productionInstallerResourceAuditDirectExecutions.Count -ne 0) {
    $failures.Add(
        'The resource audit may inspect production Setup resources but must execute only the dedicated ResourceAudit installer and its generated uninstaller.')
}
$releaseCleanupCallCount = ([regex]::Matches(
        $buildReleaseContent,
        '(?m)^\s*Remove-ReleaseWorkingTreesWithRetry\s*`?\s*$')).Count
if ($releaseCleanupCallCount -ne 3) {
    $failures.Add(
        "Release working-tree cleanup must retry before, immediately after payload audit, and after the resource audit; found $releaseCleanupCallCount of 3 calls.")
}
$buildReleaseTokens = $null
$buildReleaseParseErrors = $null
$buildReleaseAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'scripts\Build-Release.ps1'),
    [ref]$buildReleaseTokens,
    [ref]$buildReleaseParseErrors)
$auditExtractionFunctionAst = $buildReleaseAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-InstallerAuditExtraction'
    },
    $true)
$auditCleanupAst = if ($auditExtractionFunctionAst) {
    $auditExtractionFunctionAst.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Remove-Item' -and
                $node.Extent.Text.Contains('$DestinationRoot', [StringComparison]::Ordinal)
        },
        $true)
}
$auditCleanupParent = if ($auditCleanupAst) { $auditCleanupAst.Parent } else { $null }
while ($auditCleanupParent -and
    $auditCleanupParent -isnot [Management.Automation.Language.TryStatementAst] -and
    $auditCleanupParent -ne $auditExtractionFunctionAst) {
    $auditCleanupParent = $auditCleanupParent.Parent
}
if ($buildReleaseParseErrors.Count -gt 0 -or
    -not $auditExtractionFunctionAst -or
    -not $auditCleanupAst -or
    $auditCleanupParent -isnot [Management.Automation.Language.TryStatementAst]) {
    $failures.Add('Installer audit destination cleanup must remain inside each bounded retry attempt.')
}
$auditStartProcessAsts = @()
if ($auditExtractionFunctionAst) {
    $auditStartProcessAsts = @($auditExtractionFunctionAst.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Start-Process'
            },
            $true))
}
$auditInvocationAsts = @($buildReleaseAst.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-InstallerAuditExtraction'
        },
        $true))
$productionInstallerStartAsts = @($buildReleaseAst.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Start-Process' -and
                $node.Extent.Text.Contains(
                    '-FilePath $installerPath',
                    [StringComparison]::OrdinalIgnoreCase)
        },
        $true))
$productionInstallerDirectInvocationAsts = @($buildReleaseAst.FindAll(
        {
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst] -or
                $node.CommandElements.Count -eq 0) {
                return $false
            }
            return [string]::Equals(
                $node.CommandElements[0].Extent.Text,
                '$installerPath',
                [StringComparison]::OrdinalIgnoreCase)
        },
        $true))
$auditFunctionText = if ($auditExtractionFunctionAst) {
    $auditExtractionFunctionAst.Extent.Text
} else {
    ''
}
$auditInvocationText = if ($auditInvocationAsts.Count -eq 1) {
    $auditInvocationAsts[0].Extent.Text
} else {
    ''
}
$auditInvocationTryAst = if ($auditInvocationAsts.Count -eq 1) {
    $parent = $auditInvocationAsts[0].Parent
    while ($parent -and
        $parent -isnot [Management.Automation.Language.TryStatementAst]) {
        $parent = $parent.Parent
    }
    $parent
}
$payloadAuditCleanupText = if ($auditInvocationTryAst -and $auditInvocationTryAst.Finally) {
    $auditInvocationTryAst.Finally.Extent.Text
} else {
    ''
}
if ($auditStartProcessAsts.Count -ne 1 -or
    -not $auditStartProcessAsts[0].Extent.Text.Contains(
        '-FilePath $resolvedPayloadAuditInstallerPath',
        [StringComparison]::Ordinal) -or
    $auditInvocationAsts.Count -ne 1 -or
    -not $auditInvocationText.Contains(
        '-PayloadAuditInstallerPath $payloadAuditInstallerPath',
        [StringComparison]::Ordinal) -or
    -not $auditInvocationText.Contains(
        '-ProductionInstallerPath $installerPath',
        [StringComparison]::Ordinal) -or
    -not $auditFunctionText.Contains(
        '[IO.Path]::GetFullPath($PayloadAuditInstallerPath)',
        [StringComparison]::Ordinal) -or
    -not $auditFunctionText.Contains(
        '[IO.Path]::GetFullPath($ProductionInstallerPath)',
        [StringComparison]::Ordinal) -or
    -not $auditFunctionText.Contains(
        '[StringComparison]::OrdinalIgnoreCase',
        [StringComparison]::Ordinal) -or
    -not $payloadAuditCleanupText.Contains(
        'Remove-ReleaseWorkingTreesWithRetry',
        [StringComparison]::Ordinal) -or
    -not $payloadAuditCleanupText.Contains(
        '-Path $payloadAuditInstallerPath',
        [StringComparison]::Ordinal) -or
    $productionInstallerStartAsts.Count -ne 0 -or
    $productionInstallerDirectInvocationAsts.Count -ne 0) {
    $failures.Add(
        'Payload extraction must execute only the dedicated payload-audit EXE after a fail-closed absolute-path comparison with the production installer.')
}
foreach ($innoFallbackGuard in @(
        '$rejectedCandidates.Add('
        "[Version]'6.7.1'"
        'continue'
        'Rejected candidates:'
    )) {
    if (-not $innoResolverContent.Contains($innoFallbackGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Inno compiler fallback guard is missing: $innoFallbackGuard")
    }
}
foreach ($interactiveTaskGuard in @(
        "`$script:EverVigilInteractiveTaskPrefix = 'EverVigil Installer'"
        "`$script:TaskCreate = 2"
        "`$script:TaskLogonInteractiveToken = 3"
        "`$script:TaskRunLevelLeastPrivilege = 0"
        "`$definition.Principal.UserId = `$OwnerSid"
        "`$definition.Principal.LogonType = `$script:TaskLogonInteractiveToken"
        "`$definition.Principal.RunLevel = `$script:TaskRunLevelLeastPrivilege"
        "`$definition.Settings.ExecutionTimeLimit = 'PT0S'"
        'function Get-EverVigilAllowedTaskArgumentLines'
        'function Test-EverVigilAllowedTaskArgumentLine'
        "'Command' { return @('--validate-settings', '--installer-runtime-check') }"
        "'Launch' { return @('--background', '--background --force-start-service') }"
        "'RecoveryLaunch' { return @('--background') }"
        "'\A--background(?: --force-start-service)? --wait-for-pid (?<pid>[1-9][0-9]{0,9})\z'"
        '[switch]$PostSetupLaunch'
        '[ValidateRange(0, 2147483647)][int]$SetupProcessId = 0'
        'Refusing to remove an interactive task that is not owned by this transaction'
        'Refusing to remove an interactive task with an unexpected action'
        '$state -ne $script:TaskStateRunning'
        '$task.LastTaskResult'
        'The interactive launch task did not remain running'
        '$script:InteractiveLaunchStabilitySeconds = 2'
        'The interactive launch task exited during its stability check'
        "`$Folder.DeleteTask(`$TaskName, 0)"
        'function Invoke-EverVigilBoundedProcess'
        '[Diagnostics.ProcessStartInfo]::new()'
        '$startInfo.UseShellExecute = $false'
        '$startInfo.CreateNoWindow = $true'
        '$startInfo.ArgumentList.Add([string]$argument)'
        '$process.Start()'
        '$process.WaitForExit($TimeoutSeconds * 1000)'
        '$process.Dispose()'
    )) {
    if (-not $interactiveTaskContent.Contains($interactiveTaskGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Temporary interactive task guard is missing: $interactiveTaskGuard")
    }
}
if ($interactiveTaskContent.Contains('.Triggers.Create(', [StringComparison]::Ordinal) -or
    $interactiveTaskContent.Contains('TASK_CREATE_OR_UPDATE', [StringComparison]::OrdinalIgnoreCase) -or
    $interactiveTaskContent.Contains("ExecutionTimeLimit = 'PT10M'", [StringComparison]::Ordinal)) {
    $failures.Add(
        'Installer interactive tasks must be demand-only, non-replacing, and unlimited after launch.')
}
try {
    & {
        . (Join-Path $RepositoryRoot 'scripts\Invoke-InteractiveUserTask.ps1')
        foreach ($validLine in @(
                '--background --wait-for-pid 123'
                '--background --force-start-service --wait-for-pid 123'
            )) {
            if (-not (Test-EverVigilAllowedTaskArgumentLine `
                        -Purpose Launch `
                        -ArgumentLine $validLine)) {
                throw "A valid post-setup launch line was rejected: $validLine"
            }
        }
        foreach ($invalidLine in @(
                '--background --wait-for-pid 0'
                '--background --wait-for-pid -1'
                '--background --wait-for-pid 123 --unexpected'
            )) {
            if (Test-EverVigilAllowedTaskArgumentLine `
                    -Purpose Launch `
                    -ArgumentLine $invalidLine) {
                throw "An invalid post-setup launch line was accepted: $invalidLine"
            }
        }
        if (Test-EverVigilAllowedTaskArgumentLine `
                -Purpose Command `
                -ArgumentLine '--background --wait-for-pid 123') {
            throw 'A post-setup launch line was accepted for an interactive command task.'
        }
    }
} catch {
    $failures.Add("Post-setup interactive launch validation failed: $($_.Exception.Message)")
}
if ($buildReleaseContent.Contains('Compress-Archive', [StringComparison]::Ordinal) -or
    $buildReleaseContent.Contains('-win-x64.zip', [StringComparison]::Ordinal)) {
    $failures.Add('Release builds must produce one guided setup EXE instead of a ZIP.')
}
$installerContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'installer\EverVigil.iss') `
    -Raw
foreach ($installerGuard in @(
        '#define MyAppPublisher "Daichi Matsumoto"'
        'AppPublisher={#MyAppPublisher}'
        'AppCopyright=Copyright © 2026 Daichi Matsumoto'
        'DefaultDirName={localappdata}\Programs\EverVigil'
        'UsePreviousAppDir=no'
        'AllowCancelDuringInstall=no'
        'LicenseFile={#RepositoryRoot}\LICENSE'
        'PrivilegesRequired=lowest'
        'SetupLogging=yes'
        'WizardImageFile={#WizardBrandImage}'
        'SetupIconFile={#RepositoryRoot}\src\EverVigil\Assets\evervigil-placeholder.ico'
        'WizardSmallImageFile={#RepositoryRoot}\src\EverVigil\Assets\evervigil-placeholder-source.png'
        'UninstallFilesDir={#MySupportRoot}'
        '#ifdef ResourceAuditBuild'
        'AppId={{{#ResourceAuditAppId}}'
        '#ifdef PayloadAuditBuild'
        '#error ResourceAuditBuild and PayloadAuditBuild cannot be combined.'
        '#error PayloadAuditAppId must be defined for a payload-audit build.'
        'AppId={{{#PayloadAuditAppId}}'
        'DefaultDirName={tmp}\EverVigil.PayloadAudit'
        'OutputBaseFilename=EverVigil-{#MyAppVersion}-PayloadAudit'
        'VersionInfoDescription={#MyAppName} payload audit extractor'
        'VersionInfoOriginalFileName=EverVigil-{#MyAppVersion}-PayloadAudit.exe'
        'VersionInfoProductName={#MyAppName} Payload Audit'
        'Payload audit build requires /AUDITEXTRACT.'
        '/AUDITEXTRACT is rejected by this build.'
        'CreateUninstallRegKey=no'
        'UninstallFilesDir={app}'
        'Source: "{#PackageRoot}\payload\EverVigil.exe"; DestDir: "{app}"; Flags: ignoreversion'
        '#define MyUninstallRegistryKey'
        '#define RequiredLegalNotice'
        'CreateOutputMsgMemoPage('
        "'{#RequiredLegalNotice}'"
        'Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"'
        'function InstallEverVigil: String;'
        'function ExecuteInstallWorker('
        'function IsPowerShellInternalRuntimeFailure('
        'Result := ResultCode = -2146233082;'
        'Recovering the authenticated transaction before one retry.'
        'No further retry will be attempted;'
        'if HasUnresolvedInstallTransaction then'
        'function RunInstallTransaction'
        'procedure CurStepChanged(CurStep: TSetupStep);'
        'procedure DeinitializeSetup;'
        'FinalizingEverVigil'
        'PostSetupLaunchScheduled'
        'GetCurrentProcessId'
        'function InteractiveTaskScriptPath: String;'
        'function SchedulePostSetupLaunch(var Detail: String): Boolean;'
        "' -PostSetupLaunch'"
        "' -SetupProcessId ' + IntToStr(GetCurrentProcessId)"
        "' -ForceStartService'"
        'if SchedulePostSetupLaunch(Detail) then'
        "Log('EverVigil clean-context launch scheduled after Setup process exit.');"
        "CustomMessage('PostSetupLaunchFailed')"
        'Start EverVigil from the Windows Start menu.'
        'WindowsのスタートメニューからEverVigilを起動してください。'
        "' -DeferCommit'"
        "'Rollback'"
        "'Seal'"
        "'Commit'"
        '{param:AUDITEXTRACT|}'
        '{param:FAILINNOFILECOPY|0}'
        'Check: ShouldInstallFailureProbe'
        "ExtractTemporaryFiles('{tmp}\EverVigil.Package\*')"
        'Result := InstallEverVigil;'
        'ExecAndCaptureOutput('
        "' -InstallRoot '"
        "' -TargetVersion ' + QuoteArgument('{#MyAppVersion}')"
        'function PreviousInstallDirectory: String;'
        "'InstallLocation'"
        "' -PreviousInstallRoot '"
        'function InitializeUninstall: Boolean;'
        'MB_YESNOCANCEL'
        "Parameters := Parameters + ' -KeepData'"
        'SuppressibleMsgBox('
        'Abort;'
    )) {
    if (-not $installerContent.Contains($installerGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Guided setup contract is missing: $installerGuard")
    }
}
$postInstallStepIndex = $installerContent.IndexOf(
    'if CurStep = ssPostInstall then',
    [StringComparison]::Ordinal)
$protectedCommitIndex = $installerContent.IndexOf(
    "RunInstallTransaction('Commit', Detail)",
    [StringComparison]::Ordinal)
$doneStepIndex = $installerContent.IndexOf(
    'else if CurStep = ssDone then',
    [StringComparison]::Ordinal)
$postSetupLaunchIndex = $installerContent.IndexOf(
    'if SchedulePostSetupLaunch(Detail) then',
    [StringComparison]::Ordinal)
if ($postInstallStepIndex -lt 0 -or
    $protectedCommitIndex -le $postInstallStepIndex -or
    $doneStepIndex -le $protectedCommitIndex -or
    $postSetupLaunchIndex -le $doneStepIndex) {
    $failures.Add(
        'Setup must commit protected configuration before completion, then defer visible startup until Setup exits.')
}
if ($installerContent.Contains('ShellExec(', [StringComparison]::Ordinal) -or
    $installerContent.Contains('ewNoWait', [StringComparison]::Ordinal)) {
    $failures.Add(
        'Setup must not launch EverVigil directly because child processes inherit the installer compatibility context.')
}
$updateDocumentContracts = @(
    [pscustomobject]@{
        Path = 'README.md'
        Required = @(
            'If EverVigil v2.1.0 is installed, uninstall it first.'
            'EverVigil v2.1.0 to v2.1.1 is an uninstall/reinstall update.'
            'removal deletes them.'
        )
    }
    [pscustomobject]@{
        Path = 'docs\README.en.md'
        Required = @(
            'To update from EverVigil v2.1.0 to'
            'uninstall v2.1.0 first.'
            'or **No** for a'
            'complete removal.'
        )
    }
    [pscustomobject]@{
        Path = 'docs\README.ja.md'
        Required = @(
            'EverVigil v2.1.0からv2.1.1へ更新する場合は、先にv2.1.0を'
            'アンインストールしてください。'
            '完全削除するなら「いいえ」'
        )
    }
)
foreach ($updateDocumentContract in $updateDocumentContracts) {
    $updateDocumentContent = Get-Content `
        -LiteralPath (Join-Path $RepositoryRoot $updateDocumentContract.Path) `
        -Raw `
        -Encoding UTF8
    foreach ($requiredUpdateText in $updateDocumentContract.Required) {
        if (-not $updateDocumentContent.Contains(
                $requiredUpdateText,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "$($updateDocumentContract.Path) does not document the mandatory v2.1.0 uninstall flow: $requiredUpdateText")
        }
    }
}
if ([regex]::Matches($installerContent, '(?m)^Source: ').Count -ne 10) {
    $failures.Add('The guided setup must embed nine production sources plus one isolated resource-audit payload source; the broker is inside the recursively embedded package source.')
}
$initializeSetupStart = $installerContent.IndexOf(
    'function InitializeSetup: Boolean;',
    [StringComparison]::Ordinal)
$initializeSetupEnd = $installerContent.IndexOf(
    'function SetupLogDescription: String;',
    [StringComparison]::Ordinal)
$payloadAuditBranch = if ($initializeSetupStart -ge 0) {
    $installerContent.IndexOf(
        '#ifdef PayloadAuditBuild',
        $initializeSetupStart,
        [StringComparison]::Ordinal)
} else {
    -1
}
$payloadAuditExtraction = if ($payloadAuditBranch -ge 0) {
    $installerContent.IndexOf(
        "ExtractTemporaryFiles('{tmp}\EverVigil.Package\*')",
        $payloadAuditBranch,
        [StringComparison]::Ordinal)
} else {
    -1
}
$productionAuditRejectionBranch = if ($payloadAuditExtraction -ge 0) {
    $installerContent.IndexOf(
        '#else',
        $payloadAuditExtraction,
        [StringComparison]::Ordinal)
} else {
    -1
}
$productionAuditRejection = if ($productionAuditRejectionBranch -ge 0) {
    $installerContent.IndexOf(
        "Log('/AUDITEXTRACT is rejected by this build.');",
        $productionAuditRejectionBranch,
        [StringComparison]::Ordinal)
} else {
    -1
}
if ($initializeSetupStart -lt 0 -or
    $initializeSetupEnd -le $initializeSetupStart -or
    $payloadAuditBranch -le $initializeSetupStart -or
    $payloadAuditExtraction -le $payloadAuditBranch -or
    $productionAuditRejectionBranch -le $payloadAuditExtraction -or
    $productionAuditRejection -le $productionAuditRejectionBranch -or
    $productionAuditRejection -ge $initializeSetupEnd) {
    $failures.Add(
        'Only PayloadAuditBuild may extract embedded payload; production InitializeSetup must reject /AUDITEXTRACT.')
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
    $failures.Add('The installed uninstall-support source manifest is not the exact fixed seven-file manifest.')
}
if (-not $buildReleaseContent.Contains(
        "Join-Path `$PSScriptRoot 'Test-ReleaseVersion.ps1'",
        [StringComparison]::Ordinal) -or
    -not $buildReleaseContent.Contains(
        '& $versionValidatorPath -Version $Version',
        [StringComparison]::Ordinal)) {
    $failures.Add('Release package builds must use the shared canonical semantic-version validator.')
}
if (-not $installerContent.Contains($requiredLegalNotice, [StringComparison]::Ordinal)) {
    $failures.Add('The installer must display the exact required legal notice.')
}
if (-not $win32ResourceSource.Contains(
        '32512 ICON "Assets\\evervigil-placeholder.ico"',
        [StringComparison]::Ordinal)) {
    $failures.Add('The Windows executable must embed the centralized placeholder ICO through its custom resource.')
}
$embeddedBrandAsset = @($applicationProject.SelectNodes(
    "/Project/ItemGroup/EmbeddedResource[@Include='Assets\evervigil-placeholder-source.png']"))
if ($embeddedBrandAsset.Count -ne 1) {
    $failures.Add('The placeholder source PNG must be embedded exactly once.')
}

$placeholderSourcePath = Join-Path `
    $RepositoryRoot `
    'src\EverVigil\Assets\evervigil-placeholder-source.png'
$placeholderIconPath = Join-Path `
    $RepositoryRoot `
    'src\EverVigil\Assets\evervigil-placeholder.ico'
$placeholderGeneratorPath = Join-Path $RepositoryRoot 'scripts\New-PlaceholderIcon.ps1'
try {
    & $placeholderGeneratorPath -RepositoryRoot $RepositoryRoot -Check | Out-Null
} catch {
    $failures.Add("Placeholder assets are not reproducible: $($_.Exception.Message)")
}

if (Test-Path -LiteralPath $placeholderSourcePath -PathType Leaf) {
    [byte[]]$pngBytes = [IO.File]::ReadAllBytes($placeholderSourcePath)
    [byte[]]$pngSignature = @(137, 80, 78, 71, 13, 10, 26, 10)
    $validPngSignature = $pngBytes.Length -ge 24
    for ($index = 0; $validPngSignature -and $index -lt $pngSignature.Count; $index++) {
        $validPngSignature = $pngBytes[$index] -eq $pngSignature[$index]
    }
    if (-not $validPngSignature) {
        $failures.Add('The placeholder source is not a valid PNG with an IHDR record.')
    } else {
        $pngWidth = ([int]$pngBytes[16] * 16777216) +
            ([int]$pngBytes[17] * 65536) +
            ([int]$pngBytes[18] * 256) +
            [int]$pngBytes[19]
        $pngHeight = ([int]$pngBytes[20] * 16777216) +
            ([int]$pngBytes[21] * 65536) +
            ([int]$pngBytes[22] * 256) +
            [int]$pngBytes[23]
        if ($pngWidth -lt 512 -or $pngHeight -lt 512 -or $pngWidth -ne $pngHeight) {
            $failures.Add(
                "The placeholder source PNG must be square and at least 512 px; found ${pngWidth}x${pngHeight}.")
        }
    }
}

if (Test-Path -LiteralPath $placeholderIconPath -PathType Leaf) {
    [byte[]]$iconBytes = [IO.File]::ReadAllBytes($placeholderIconPath)
    $actualIconSizes = [Collections.Generic.List[int]]::new()
    if ($iconBytes.Length -lt 6 -or
        [BitConverter]::ToUInt16($iconBytes, 0) -ne 0 -or
        [BitConverter]::ToUInt16($iconBytes, 2) -ne 1) {
        $failures.Add('The placeholder ICO header is invalid.')
    } else {
        $iconCount = [BitConverter]::ToUInt16($iconBytes, 4)
        if ($iconBytes.Length -lt (6 + (16 * $iconCount))) {
            $failures.Add('The placeholder ICO directory is truncated.')
        } else {
            for ($entryIndex = 0; $entryIndex -lt $iconCount; $entryIndex++) {
                $entryOffset = 6 + (16 * $entryIndex)
                $width = if ($iconBytes[$entryOffset] -eq 0) { 256 } else { [int]$iconBytes[$entryOffset] }
                $height = if ($iconBytes[$entryOffset + 1] -eq 0) { 256 } else { [int]$iconBytes[$entryOffset + 1] }
                $imageLength = [BitConverter]::ToUInt32($iconBytes, $entryOffset + 8)
                $imageOffset = [BitConverter]::ToUInt32($iconBytes, $entryOffset + 12)
                if ($width -ne $height -or
                    $imageLength -eq 0 -or
                    ([uint64]$imageOffset + [uint64]$imageLength) -gt $iconBytes.Length) {
                    $failures.Add("The placeholder ICO entry $entryIndex is invalid.")
                }
                $actualIconSizes.Add($width)
            }
        }
    }
    $expectedIconSizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $sortedActualIconSizes = @($actualIconSizes | Sort-Object)
    if ($sortedActualIconSizes.Count -ne $expectedIconSizes.Count -or
        (Compare-Object `
            -ReferenceObject $expectedIconSizes `
            -DifferenceObject $sortedActualIconSizes)) {
        $failures.Add(
            "The placeholder ICO must contain exactly $($expectedIconSizes -join ', '); " +
            "found $($sortedActualIconSizes -join ', ').")
    }
}

$startupRegistrationContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\StartupRegistration.cs') `
    -Raw
if (-not $startupRegistrationContent.Contains(
        'SetProperty(shortcutType, shortcut, "Arguments", "--background")',
        [StringComparison]::Ordinal)) {
    $failures.Add('Windows startup must launch the application with --background.')
}
$trayContextContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\UI\TrayApplicationContext.cs') `
    -Raw
foreach ($backgroundGuard in @(
        'showInitially: !HasArgument(arguments, "--background")'
        '_dashboard.ShowInTaskbar = false;'
        '_dashboard.Hide();'
    )) {
    $content = if ($backgroundGuard.StartsWith('showInitially', [StringComparison]::Ordinal)) {
        Get-Content -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Program.cs') -Raw
    } else {
        $trayContextContent
    }
    if (-not $content.Contains($backgroundGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Tray-only startup guard is missing: $backgroundGuard")
    }
}
$trayLanguageSubscriptionIndex = $trayContextContent.IndexOf(
    'AppLocalizer.LanguageChanged += OnLanguageChanged;',
    [StringComparison]::Ordinal)
$trayInitialLocalizationIndex = if ($trayLanguageSubscriptionIndex -ge 0) {
    $trayContextContent.IndexOf(
        'ApplyLocalization();',
        $trayLanguageSubscriptionIndex,
        [StringComparison]::Ordinal)
} else { -1 }
if ($trayLanguageSubscriptionIndex -lt 0 -or
    $trayInitialLocalizationIndex -lt $trayLanguageSubscriptionIndex) {
    $failures.Add('The tray must localize its initial state after subscribing to language changes.')
}

$appLocalizerContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Core\Localization\AppLocalizer.cs') `
    -Raw
if (-not $appLocalizerContent.Contains(
        'CultureInfo.CurrentUICulture.TwoLetterISOLanguageName',
        [StringComparison]::Ordinal) -or
    $appLocalizerContent.Contains('CultureInfo.InstalledUICulture', [StringComparison]::Ordinal)) {
    $failures.Add('System language selection must follow the active Windows display language.')
}

$singleInstanceContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\SingleInstanceCoordinator.cs') `
    -Raw
foreach ($crossIntegrityGuard in @(
        'MutexAcl.Create('
        'EventWaitHandleAcl.Create('
        'MutexRights.FullControl'
        'EventWaitHandleRights.FullControl'
        'WellKnownSidType.LocalSystemSid'
        'WellKnownSidType.BuiltinAdministratorsSid'
    )) {
    if (-not $singleInstanceContent.Contains($crossIntegrityGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Cross-integrity single-instance ACL guard is missing: $crossIntegrityGuard")
    }
}

$dashboardContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\UI\DashboardForm.cs') `
    -Raw
$metadataContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\ApplicationMetadata.cs') `
    -Raw
foreach ($aboutGuard in @(
        'BuildAboutPage()'
        'ApplicationMetadata.Version'
        'Text = ApplicationMetadata.LegalNotice'
        'ApplicationMetadata.Copyright'
        'ApplicationMetadata.LicenseName'
        'Tag = "loc:AboutLicenseNotice"'
        'ApplicationMetadata.GitHubProfileUrl'
        'ApplicationMetadata.LicenseUrl'
        'NewExternalLink('
    )) {
    if (-not $dashboardContent.Contains($aboutGuard, [StringComparison]::Ordinal)) {
        $failures.Add("In-app About information guard is missing: $aboutGuard")
    }
}
if (-not $metadataContent.Contains($requiredLegalNotice, [StringComparison]::Ordinal) -or
    -not $metadataContent.Contains('internal const string LegalNotice', [StringComparison]::Ordinal)) {
    $failures.Add('The About metadata must preserve the exact required legal notice.')
}
foreach ($secretDisclosureGuard in @(
        'internal const int SecretRevealSeconds = 60;'
        '_secretTimer.Tick += (_, _) => HideSecrets();'
        'Deactivate += (_, _) => HideSecrets();'
        '_secretTimer.Interval = SecretRevealSeconds * 1000;'
        '_qrPicture.Visible = false;'
        '_qrHiddenLabel.Visible = true;'
        'private void ToggleSecrets()'
        'SetConnectionStatus(() => AppLocalizer.Format('
        '"ClipboardClears"'
    )) {
    if (-not $dashboardContent.Contains($secretDisclosureGuard, [StringComparison]::Ordinal)) {
        $failures.Add("QR and credential disclosure guard is missing: $secretDisclosureGuard")
    }
}
if (-not $englishValues['ClipboardClears'].Contains(
        'credential',
        [StringComparison]::OrdinalIgnoreCase) -or
    -not $japaneseValues['ClipboardClears'].Contains(
        '資格情報',
        [StringComparison]::Ordinal)) {
    $failures.Add('Clipboard copy feedback must warn in both languages that the value is a credential.')
}
foreach ($dynamicLocalizationGuard in @(
        'private Func<string>? _settingsStatusFactory;'
        'private Func<string>? _connectionStatusFactory;'
        'private Func<string>? _logStatusFactory;'
        'UpdateHeaderNode(updated.DisplayName);'
        'if (_settingsStatusFactory is not null)'
        'if (_connectionStatusFactory is not null)'
        'if (_logStatusFactory is not null)'
    )) {
    if (-not $dashboardContent.Contains($dynamicLocalizationGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Dynamic application localization guard is missing: $dynamicLocalizationGuard")
    }
}
foreach ($metadataGuard in @(
        'Copyright \u00A9 2026 Daichi Matsumoto'
        'GNU GPL v3.0 only'
        'GPL-3.0-only'
        'https://github.com/DaichiMatsumoto'
        'AssemblyInformationalVersionAttribute'
    )) {
    if (-not $metadataContent.Contains($metadataGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Application metadata guard is missing: $metadataGuard")
    }
}
if ([regex]::Matches($dashboardContent, [regex]::Escape('_systemConfigurationGate.Wait(0)')).Count -ne 2) {
    $failures.Add('Both system-configuration UI actions must use the shared non-reentrant gate.')
}
if ([regex]::Matches($dashboardContent, [regex]::Escape('GetLastAppliedSystemSettings()')).Count -ne 2) {
    $failures.Add('Both system-configuration UI paths must use the last applied system settings for rollback.')
}
$reconciliationApplyIndex = $dashboardContent.IndexOf(
    'previousMappingOwned: true',
    [StringComparison]::Ordinal)
$reconciliationCommitIndex = $dashboardContent.IndexOf(
    'MarkSystemConfigurationApplied(current)',
    [StringComparison]::Ordinal)
$reconciliationTargetOwnershipIndex = if ($reconciliationApplyIndex -ge 0) {
    $dashboardContent.IndexOf(
        'lastAppliedSystemSettings.PublicPort == current.PublicPort',
        $reconciliationApplyIndex,
        [StringComparison]::Ordinal)
} else { -1 }
$updatedSettingsSaveIndex = $dashboardContent.IndexOf(
    '_settingsStore.Save(updated)',
    [StringComparison]::Ordinal)
if ($reconciliationApplyIndex -lt 0 -or
    $reconciliationTargetOwnershipIndex -lt $reconciliationApplyIndex -or
    $reconciliationTargetOwnershipIndex -gt $reconciliationCommitIndex -or
    $reconciliationCommitIndex -lt $reconciliationApplyIndex -or
    $updatedSettingsSaveIndex -lt $reconciliationCommitIndex) {
    $failures.Add('Pending system configuration must be reconciled and committed before saving another port change.')
}
if ($dashboardContent.Contains(
        'existingTargetMappingOwned: true',
        [StringComparison]::Ordinal)) {
    $failures.Add('Target ownership must be derived from the durable previous mapping, never asserted unconditionally.')
}
$saveCoreIndex = $dashboardContent.IndexOf('private async Task SaveSettingsCoreAsync()', [StringComparison]::Ordinal)
$applyCoreIndex = $dashboardContent.IndexOf('private async Task ApplySystemConfigurationCoreAsync()', [StringComparison]::Ordinal)
$saveMarkerIndex = $dashboardContent.IndexOf('_settingsStore.MarkSystemConfigurationRequired()', $saveCoreIndex, [StringComparison]::Ordinal)
$saveStopIndex = $dashboardContent.IndexOf('await _supervisor.StopAsync()', $saveCoreIndex, [StringComparison]::Ordinal)
$applyMarkerIndex = $dashboardContent.IndexOf('_settingsStore.MarkSystemConfigurationRequired()', $applyCoreIndex, [StringComparison]::Ordinal)
$applyStopIndex = $dashboardContent.IndexOf('await _supervisor.StopAsync()', $applyCoreIndex, [StringComparison]::Ordinal)
if ($saveMarkerIndex -lt 0 -or $saveStopIndex -lt 0 -or $saveMarkerIndex -gt $saveStopIndex -or
    $applyMarkerIndex -lt 0 -or $applyStopIndex -lt 0 -or $applyMarkerIndex -gt $applyStopIndex) {
    $failures.Add('System configuration UI paths must block new starts before awaiting supervisor shutdown.')
}
foreach ($deferredConfigurationGuard in @(
        'var installerCompletionRequired = systemConfigurationWasRequired &&'
        'var deferSystemUpdateToInstaller = requiresSystemUpdate && installerCompletionRequired;'
        'if (requiresSystemUpdate && !deferSystemUpdateToInstaller)'
        'if (installerCompletionRequired)'
        'SetSettingsStatus("SettingsSavedInstaller")'
    )) {
    if (-not $dashboardContent.Contains($deferredConfigurationGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Pending first-time settings must remain savable before installer-owned migration: $deferredConfigurationGuard")
    }
}
$tokenRegenerationIndex = $dashboardContent.IndexOf('private async Task RegenerateTokenAsync()', [StringComparison]::Ordinal)
$tokenWasRunningIndex = if ($tokenRegenerationIndex -ge 0) {
    $dashboardContent.IndexOf('var wasRunning = _supervisor.IsRunning;', $tokenRegenerationIndex, [StringComparison]::Ordinal)
} else { -1 }
$tokenRestartGuardIndex = if ($tokenWasRunningIndex -ge 0) {
    $dashboardContent.IndexOf('if (wasRunning)', $tokenWasRunningIndex, [StringComparison]::Ordinal)
} else { -1 }
$tokenRestartIndex = if ($tokenWasRunningIndex -ge 0) {
    $dashboardContent.IndexOf('await _supervisor.RestartAsync("Connection token regenerated.")', $tokenWasRunningIndex, [StringComparison]::Ordinal)
} else { -1 }
if ($tokenRegenerationIndex -lt 0 -or
    $tokenWasRunningIndex -lt $tokenRegenerationIndex -or
    $tokenRestartGuardIndex -lt $tokenWasRunningIndex -or
    $tokenRestartIndex -lt $tokenRestartGuardIndex) {
    $failures.Add('Token regeneration must preserve a stopped supervisor state.')
}

$supervisorContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\SupervisorEngine.cs') `
    -Raw
foreach ($requiredLifecycleGuard in @(
        'ReferenceEquals(_supervisorTask, supervisorTask)'
        'ReferenceEquals(_lifetimeCancellation, cancellation)'
        'requiredLifecycleVersion: lifecycleVersion'
        'Task.Run(() => RunAsync(cancellation.Token, lifecycleVersion))'
    )) {
    if (-not $supervisorContent.Contains($requiredLifecycleGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Supervisor lifecycle ownership guard is missing: $requiredLifecycleGuard")
    }
}

$uninstallContent = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Uninstall.ps1') -Raw
foreach ($uninstallTransactionGuard in @(
        '$installTransactionTemporaryPrefix ='
        '.new-'
    )) {
    if (-not $uninstallContent.Contains($uninstallTransactionGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Uninstall transaction prefix initialization is missing: $uninstallTransactionGuard")
    }
}
$installPathResolverPath = Join-Path $RepositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$installPathResolverContent = Get-Content -LiteralPath $installPathResolverPath -Raw
foreach ($installPathGuard in @(
        'function Resolve-SafeInstallRoot'
        'function Resolve-EverVigilMaintenanceInstallRoot'
        'function Get-EverVigilRegisteredInstallRoot'
        'function Get-EverVigilProcessLocations'
        'function Assert-CompatibleInstallRoot'
        'function Assert-OwnedInstallRoot'
        'function Assert-OwnedInstallBackup'
        'function Write-EverVigilInstallOwnership'
        'function Test-EverVigilKnownLayout'
        '[string]$InstallRoot = $Path'
        '[IO.FileOptions]::WriteThrough'
        '$stream.Flush($true)'
        'Get-EverVigilRequiredLegacyPaths'
        '$script:EverVigilOwnershipFileName'
        'ownerSid = Get-EverVigilOwnerSid'
        'function Test-EverVigilPathFullyQualified'
        'function Set-EverVigilAtomicJournalFileAcl'
        'function Test-EverVigilAtomicJournalFileAcl'
        'function Complete-EverVigilProtectedBrokerRetirementFromReceipt'
        '[IO.Path]::IsPathRooted($Path)'
        "`$resolvedPath.StartsWith('\\'"
        '[IO.FileAttributes]::ReparsePoint'
        'GetFinalPathNameByHandleW'
        'Resolve-EverVigilFinalFileSystemPath'
        '[EverVigil.NativeFileSystem]::GetFinalPath'
        '$env:SystemRoot'
        '${env:ProgramFiles(x86)}'
        '$env:TEMP'
        '$dataRoot'
        "'EverVigil'"
    )) {
    if (-not $installPathResolverContent.Contains($installPathGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Install-path safety guard is missing: $installPathGuard")
    }
}
. $installPathResolverPath
$safeInstallCandidate = Join-Path $env:USERPROFILE 'Applications\EverVigil-Test'
try {
    $safeInstallResult = Resolve-SafeInstallRoot -Path $safeInstallCandidate
    if (-not [string]::Equals(
            $safeInstallResult,
            [IO.Path]::GetFullPath($safeInstallCandidate).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add('Install-path validation changed a safe custom destination unexpectedly.')
    }
} catch {
    $failures.Add("Install-path validation rejected a safe custom destination: $($_.Exception.Message)")
}
foreach ($unsafeInstallCandidate in @(
        'relative\EverVigil'
        '\\server\share\EverVigil'
        ([IO.Path]::GetPathRoot($safeInstallCandidate))
        (Join-Path $env:TEMP 'EverVigil')
        (Join-Path $env:LOCALAPPDATA 'EverVigil\Program')
        (Join-Path $env:SystemRoot 'EverVigil')
    )) {
    $unsafeInstallCandidateRejected = $false
    try {
        Resolve-SafeInstallRoot -Path $unsafeInstallCandidate | Out-Null
    } catch {
        $unsafeInstallCandidateRejected = $true
    }
    if (-not $unsafeInstallCandidateRejected) {
        $failures.Add("Install-path validation accepted an unsafe destination: $unsafeInstallCandidate")
    }
}
$compatibilityTestRoot = Join-Path $RepositoryRoot 'artifacts\install-root-compatibility-test'
try {
    Remove-Item -LiteralPath $compatibilityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $compatibilityTestRoot -Force | Out-Null
    try {
        Assert-CompatibleInstallRoot -Path $compatibilityTestRoot
    } catch {
        $failures.Add("Install-path validation rejected an empty destination: $($_.Exception.Message)")
    }

    [IO.File]::WriteAllText(
        (Join-Path $compatibilityTestRoot 'unrelated.txt'),
        'unrelated content',
        [Text.UTF8Encoding]::new($false))
    $nonEmptyDestinationRejected = $false
    try {
        Assert-CompatibleInstallRoot -Path $compatibilityTestRoot
    } catch {
        $nonEmptyDestinationRejected = $true
    }
    if (-not $nonEmptyDestinationRejected) {
        $failures.Add('Install-path validation accepted a non-empty unrelated destination.')
    }

    $reservedUninstallRootRejected = $false
    try {
        [void](Resolve-SafeInstallRoot -Path (
                Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall'))
    } catch {
        $reservedUninstallRootRejected = $true
    }
    if (-not $reservedUninstallRootRejected) {
        $failures.Add('Install-path validation accepted the reserved Inno uninstall-support directory.')
    }

    $aliasDriveLetter = $null
    foreach ($codePoint in 90..68) {
        $candidateLetter = [char]$codePoint
        if (-not (Get-PSDrive -Name $candidateLetter -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $aliasDriveLetter = [string]$candidateLetter
            break
        }
    }
    if (-not $aliasDriveLetter) {
        $failures.Add('No free drive letter was available for the filesystem-alias safety test.')
    } else {
        $substPath = Join-Path $env:SystemRoot 'System32\subst.exe'
        try {
            & $substPath "$aliasDriveLetter`:" $env:LOCALAPPDATA
            if ($LASTEXITCODE -ne 0) {
                throw "subst failed with exit code $LASTEXITCODE."
            }
            $aliasedProtectedRootRejected = $false
            try {
                [void](Resolve-SafeInstallRoot -Path (
                        "$aliasDriveLetter`:\EverVigil.Uninstall"))
            } catch {
                $aliasedProtectedRootRejected = $true
            }
            if (-not $aliasedProtectedRootRejected) {
                $failures.Add('Install-path validation accepted a drive alias into protected uninstall state.')
            }
        } catch {
            $failures.Add("Filesystem-alias safety test failed: $($_.Exception.Message)")
        } finally {
            & $substPath "$aliasDriveLetter`:" /D 2>$null
        }
    }

    Remove-Item -LiteralPath $compatibilityTestRoot -Recurse -Force
    New-Item -ItemType Directory -Path $compatibilityTestRoot -Force | Out-Null
    foreach ($relativePath in @(Get-EverVigilRequiredLegacyPaths)) {
        $fixturePath = Join-Path $compatibilityTestRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePath) -Force | Out-Null
        [IO.File]::WriteAllText($fixturePath, 'fixture', [Text.UTF8Encoding]::new($false))
    }
    $acceptLegacyFixtureExecutable = {
        param([string]$Path)
        return [string]::Equals(
            [IO.Path]::GetFileName($Path),
            $script:LegacyCompatibilityApplicationExecutableFileName,
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not (Test-EverVigilLegacyKnownLayout `
                -Path $compatibilityTestRoot `
                -ExecutableIdentityTest $acceptLegacyFixtureExecutable)) {
        $failures.Add('The exact legacy install-layout fixture was not recognized.')
    }

    [IO.File]::WriteAllText(
        (Join-Path $compatibilityTestRoot 'unrelated-user-file.txt'),
        'must never be deleted',
        [Text.UTF8Encoding]::new($false))
    if (Test-EverVigilLegacyKnownLayout `
            -Path $compatibilityTestRoot `
            -ExecutableIdentityTest $acceptLegacyFixtureExecutable) {
        $failures.Add('An install layout containing an unrelated file was accepted.')
    }
    Remove-Item -LiteralPath (Join-Path $compatibilityTestRoot 'unrelated-user-file.txt') -Force

    New-Item -ItemType Directory -Path (Join-Path $compatibilityTestRoot 'unrelated-directory') | Out-Null
    if (Test-EverVigilLegacyKnownLayout `
            -Path $compatibilityTestRoot `
            -ExecutableIdentityTest $acceptLegacyFixtureExecutable) {
        $failures.Add('An install layout containing an unrelated directory was accepted.')
    }
    Remove-Item -LiteralPath (Join-Path $compatibilityTestRoot 'unrelated-directory') -Recurse -Force

    Remove-Item -LiteralPath $compatibilityTestRoot -Recurse -Force
    New-Item -ItemType Directory -Path $compatibilityTestRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path `
            $compatibilityTestRoot `
            $script:LegacyCompatibilityApplicationExecutableFileName),
        'copied executable',
        [Text.UTF8Encoding]::new($false))
    if (Test-EverVigilLegacyKnownLayout `
            -Path $compatibilityTestRoot `
            -ExecutableIdentityTest $acceptLegacyFixtureExecutable) {
        $failures.Add('A copied executable without the exact legacy layout was accepted.')
    }

    Remove-Item -LiteralPath $compatibilityTestRoot -Recurse -Force
    New-Item -ItemType Directory -Path $compatibilityTestRoot -Force | Out-Null
    foreach ($relativePath in @(Get-EverVigilRequiredCurrentPaths)) {
        $fixturePath = Join-Path $compatibilityTestRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePath) -Force | Out-Null
        [IO.File]::WriteAllText($fixturePath, 'fixture', [Text.UTF8Encoding]::new($false))
    }
    $acceptCurrentFixtureExecutable = {
        param([string]$Path)
        return $Path.EndsWith('EverVigil.exe', [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not (Test-EverVigilKnownLayout `
                -Path $compatibilityTestRoot `
                -ExecutableIdentityTest $acceptCurrentFixtureExecutable)) {
        $failures.Add('The exact current EverVigil install-layout fixture was not recognized.')
    }
} finally {
    Remove-Item -LiteralPath $compatibilityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$systemMaintenanceContentForUninstall = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Invoke-SystemMaintenance.ps1') `
    -Raw
foreach ($forbiddenAdapterMutation in @(
        'Get-NetFirewallRule'
        'New-NetFirewallRule'
        'Remove-NetFirewallRule'
        'Get-ScheduledTask'
        'Unregister-ScheduledTask'
        'tailscale serve'
        'Start-Process'
    )) {
    if ($systemMaintenanceContentForUninstall.Contains(
            $forbiddenAdapterMutation,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add(
            "The medium system adapter contains privileged mutation logic: $forbiddenAdapterMutation")
    }
}
foreach ($uninstallBrokerGuard in @(
        'function Invoke-UninstallSystemBrokerOperation'
        "[ValidateSet('Recover', 'UninstallCleanup')]"
        'Invoke-EverVigilSystemBroker'
        '-Operation Recover'
        '-Operation UninstallCleanup'
        'Assert-NoInstallTransactionAfterElevation'
        '$transactionMutex.ReleaseMutex()'
        '$transactionMutex.WaitOne([TimeSpan]::FromMinutes(10))'
        'Recovery can restore a different previously applied identity.'
        '$appliedConfiguration = Get-ValidatedAppliedSystemConfiguration'
        'New-UninstallPendingSystemJournal -Target $uninstallTarget'
        'The pending system journal remained after authenticated uninstall cleanup.'
        'Get-ValidatedEverVigilProtectedBrokerRetirementState'
        '$InstallTransactionDataHelper'
        'Get-EverVigilInstallTransactionTemporaryFiles'
        "'NeedsBrokerResume'"
        '-ExpectedTransactionId $pendingRecoveryTransactionId'
        "'RetirementRequired'"
        'Complete-EverVigilProtectedBrokerRetirement'
        'if ($primaryConfigurationOwned -and -not $protectedBrokerRetirementRequired) {'
        'A local pending system journal exists without matching active or protected retirement evidence.'
    )) {
    if (-not $uninstallContent.Contains(
            $uninstallBrokerGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Uninstall protected-broker guard is missing: $uninstallBrokerGuard")
    }
}
if ($uninstallContent.IndexOf(
        '-Operation UninstallCleanup',
        [StringComparison]::Ordinal) -lt 0 -or
    $uninstallContent.IndexOf(
        '$preCleanupBrokerState.Status -eq ''Active''',
        [StringComparison]::Ordinal) -lt 0 -or
    $uninstallContent.IndexOf(
        '$preCleanupBrokerState.Status -eq ''NeedsBrokerResume''',
        [StringComparison]::Ordinal) -lt 0 -or
    $uninstallContent.IndexOf(
        '$preCleanupBrokerState.Status -eq ''Absent''',
        [StringComparison]::Ordinal) -lt 0 -or
    $systemMaintenanceContentForUninstall.Contains(
        'ExistingTargetMappingOwned',
        [StringComparison]::Ordinal) -or
    $systemMaintenanceContentForUninstall.Contains(
        'PendingTargetMappingOwned',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Uninstall must use protected-ledger UninstallCleanup for active/resumable state and accept absence only after fixed retirement validation.')
}
foreach ($startupShortcutRemovalGuard in @(
        'Remove-EverVigilOwnedShortcut'
        '-Path $StartupShortcutPath'
        '-ExpectedTargetPath $CurrentStartupTargets'
        '-Path $LegacyStartupShortcutPath'
        '-ExpectedTargetPath $LegacyStartupTargets'
        "-ExpectedArguments '--background'"
    )) {
    if (-not $uninstallContent.Contains(
            $startupShortcutRemovalGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Uninstall startup-shortcut cleanup guard is missing: $startupShortcutRemovalGuard")
    }
}
$ownershipRetirementIndex = $uninstallContent.IndexOf('$ownershipStatePaths = @(', [StringComparison]::Ordinal)
$keepDataRemovalIndex = $uninstallContent.LastIndexOf('if (-not $KeepData', [StringComparison]::Ordinal)
foreach ($ownershipRetirementGuard in @(
        '$AppliedSystemConfigurationPath'
        '$SystemConfigurationRequiredPath'
        'Remove-Item -LiteralPath $ownershipStatePath -Force -ErrorAction SilentlyContinue'
        'System configuration ownership state could not be removed'
    )) {
    if (-not $uninstallContent.Contains($ownershipRetirementGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Uninstall ownership-state retirement guard is missing: $ownershipRetirementGuard")
    }
}
if ($ownershipRetirementIndex -lt 0 -or
    $keepDataRemovalIndex -lt 0 -or
    $ownershipRetirementIndex -gt $keepDataRemovalIndex) {
    $failures.Add('Uninstall must retire ownership state even when user data is kept.')
}
if (-not $uninstallContent.Contains('Resolve-AvailableTailscalePath', [StringComparison]::Ordinal)) {
    $failures.Add('Uninstall must resolve an available Tailscale CLI independently of persisted paths.')
}
if ($uninstallContent.Contains('$SettingsPath', [StringComparison]::Ordinal) -or
    $uninstallContent.Contains("'pending settings'", [StringComparison]::Ordinal)) {
    $failures.Add('Uninstall must not require settings or Tailscale inspection without an applied ownership record.')
}
foreach ($customUninstallGuard in @(
        '[string]$InstallRoot'
        'Get-Variable -Name PSStyle -ErrorAction SilentlyContinue'
        "`$PSStyle.OutputRendering = 'PlainText'"
        "[Console]::Error.WriteLine('ERROR: {0}', `$_.Exception.Message)"
        'Resolve-EverVigilMaintenanceInstallRoot'
        '-AllowCurrentTempTree:$allowInstallRootInCurrentTemp'
        'Assert-NoSupervisorOutsideInstallRoot'
        'Get-EverVigilProcessLocations -Root $InstallRoot'
        '$script:LegacyCompatibilitySynchronizationInstanceMutexTemplate.Replace('
        "'{ownerSid}'"
        '$instanceLockTaken'
        '$InstallTransactionPath'
        '$transactionRecoveryRoots'
        '-Action Recover'
        'An install recovery transaction could not be resolved before uninstalling'
        'Required uninstall support helper is missing or unsafe'
        '$installRootEntryExists = Test-Path -LiteralPath $InstallRoot'
        'The registered install path is not a directory'
        '$expected = [IO.Path]::GetFullPath($InstallRoot)'
        'system cleanup was not started'
    )) {
    if (-not $uninstallContent.Contains($customUninstallGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Custom uninstall destination guard is missing: $customUninstallGuard")
    }
}
$uninstallTokens = $null
$uninstallParseErrors = $null
$uninstallAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'Uninstall.ps1'),
    [ref]$uninstallTokens,
    [ref]$uninstallParseErrors)
$processLocationGuardAst = @($uninstallAst.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-NoSupervisorOutsideInstallRoot'
        },
        $true))
if ($processLocationGuardAst.Count -ne 1 -or
    -not $processLocationGuardAst[0].Extent.Text.Contains(
        '[AllowEmptyCollection()]',
        [StringComparison]::Ordinal)) {
    $failures.Add('Uninstall must accept an empty supervisor process-location collection.')
} else {
    $processLocationGuardError = & {
        param([Parameter(Mandatory)][string]$Definition)

        . ([scriptblock]::Create($Definition))
        try {
            Assert-NoSupervisorOutsideInstallRoot -Location @()
        } catch {
            return "The empty process-location collection was rejected: $($_.Exception.Message)"
        }

        try {
            Assert-NoSupervisorOutsideInstallRoot -Location @(
                [pscustomobject]@{
                    AtInstallRoot = $false
                    Id = 4242
                })
            return 'A relocated supervisor process was accepted.'
        } catch {
            if (-not $_.Exception.Message.Contains(
                    'process is running outside the registered installation directory',
                    [StringComparison]::Ordinal)) {
                return "The relocated-process guard failed unexpectedly: $($_.Exception.Message)"
            }
        }

        return $null
    } $processLocationGuardAst[0].Extent.Text
    if (-not [string]::IsNullOrWhiteSpace($processLocationGuardError)) {
        $failures.Add("Uninstall process-location regression: $processLocationGuardError")
    }

    $windowsPowerShellPath = Join-Path `
        $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
        $failures.Add("Windows PowerShell 5.1 was not found: $windowsPowerShellPath")
    } else {
        $windowsPowerShellProbe = $processLocationGuardAst[0].Extent.Text + @'

try {
    Assert-NoSupervisorOutsideInstallRoot -Location @()
} catch {
    [Console]::Error.WriteLine(
        'The empty process-location collection was rejected: {0}',
        $_.Exception.Message)
    exit 1
}

try {
    Assert-NoSupervisorOutsideInstallRoot -Location @(
        [pscustomobject]@{
            AtInstallRoot = $false
            Id = 4242
        })
    [Console]::Error.WriteLine('A relocated supervisor process was accepted.')
    exit 1
} catch {
    if ($_.Exception.Message.IndexOf(
            'process is running outside the registered installation directory',
            [StringComparison]::Ordinal) -lt 0) {
        [Console]::Error.WriteLine(
            'The relocated-process guard failed unexpectedly: {0}',
            $_.Exception.Message)
        exit 1
    }
}
exit 0
'@
        $encodedProbe = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($windowsPowerShellProbe))
        $probeStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $probeStartInfo.FileName = $windowsPowerShellPath
        $probeStartInfo.UseShellExecute = $false
        $probeStartInfo.CreateNoWindow = $true
        $probeStartInfo.RedirectStandardOutput = $true
        $probeStartInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoLogo'
                '-NoProfile'
                '-NonInteractive'
                '-EncodedCommand'
                $encodedProbe
            )) {
            [void]$probeStartInfo.ArgumentList.Add($argument)
        }
        $probeProcess = [Diagnostics.Process]::new()
        $probeProcess.StartInfo = $probeStartInfo
        try {
            if (-not $probeProcess.Start()) {
                $failures.Add('Windows PowerShell 5.1 uninstall regression did not start.')
            } else {
                $probeOutput = $probeProcess.StandardOutput.ReadToEndAsync()
                $probeError = $probeProcess.StandardError.ReadToEndAsync()
                if (-not $probeProcess.WaitForExit(30000)) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                    $failures.Add('Windows PowerShell 5.1 uninstall regression timed out.')
                } elseif ($probeProcess.ExitCode -ne 0) {
                    $probeDetail = @(
                        $probeOutput.GetAwaiter().GetResult().Trim()
                        $probeError.GetAwaiter().GetResult().Trim()
                    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    $failures.Add(
                        "Windows PowerShell 5.1 uninstall regression failed: $($probeDetail -join ' ')")
                }
            }
        } finally {
            $probeProcess.Dispose()
        }
    }
}
$ownershipAssertionAst = @($uninstallAst.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Assert-OwnedInstallRoot'
        },
        $true))
$guardedOwnershipAssertions = @($ownershipAssertionAst | Where-Object {
        $ownershipAssertionParent = $_.Parent
        while ($ownershipAssertionParent -and
            $ownershipAssertionParent -isnot [Management.Automation.Language.IfStatementAst] -and
            $ownershipAssertionParent -ne $uninstallAst) {
            $ownershipAssertionParent = $ownershipAssertionParent.Parent
        }
        $ownershipAssertionParent -is [Management.Automation.Language.IfStatementAst] -and
            $ownershipAssertionParent.Extent.Text.Contains(
                'if ($installRootEntryExists)',
                [StringComparison]::Ordinal)
    })
if ($uninstallParseErrors.Count -gt 0 -or
    $guardedOwnershipAssertions.Count -ne 1) {
    $failures.Add('Uninstall must require program-directory ownership only when that directory still exists.')
}

$installContent = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Install.ps1') -Raw
$installTransactionContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Complete-InstallTransaction.ps1') `
    -Raw
$installTransactionDataContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\InstallTransactionData.ps1') `
    -Raw
$installTransactionTestContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'tests\Test-InstallTransaction.ps1') `
    -Raw
if (-not $installTransactionTestContent.Contains(
        "'Test-ExternalInstallTransaction.ps1'",
        [StringComparison]::Ordinal) -or
    -not $installTransactionTestContent.Contains(
        '& $externalTransactionTest',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Install-transaction regression must execute the external file, shortcut, and typed-registry recovery fixture.')
}
$commitFunctionIndex = $installTransactionContent.IndexOf(
    'function Commit-EverVigilInstallTransaction',
    [StringComparison]::Ordinal)
$snapshotCommitIndex = $installTransactionContent.IndexOf(
    '$phase = [string]$State.externalCommitPhase',
    $commitFunctionIndex,
    [StringComparison]::Ordinal)
$reversibleStagingCleanupIndex = $installTransactionContent.IndexOf(
    '-Role stagingRoot',
    $snapshotCommitIndex,
    [StringComparison]::Ordinal)
$reversibleLegacyCleanupIndex = $installTransactionContent.IndexOf(
    'Remove-EverVigilLegacyUninstallSupport -State $State',
    $snapshotCommitIndex,
    [StringComparison]::Ordinal)
$systemCommitPreparedIndex = $installTransactionContent.IndexOf(
    "`$State.externalCommitPhase = 'SystemCommitPrepared'",
    $snapshotCommitIndex,
    [StringComparison]::Ordinal)
$protectedBrokerCommitIndex = $installTransactionContent.IndexOf(
    'Invoke-SystemBrokerTransaction -State $State -Mode Commit',
    $systemCommitPreparedIndex,
    [StringComparison]::Ordinal)
$systemCommittedIndex = $installTransactionContent.IndexOf(
    "`$State.externalCommitPhase = 'SystemCommitted'",
    $protectedBrokerCommitIndex,
    [StringComparison]::Ordinal)
$cleanupCompleteIndex = $installTransactionContent.IndexOf(
    "`$State.externalCommitPhase = 'CleanupComplete'",
    $systemCommittedIndex,
    [StringComparison]::Ordinal)
if ($commitFunctionIndex -lt 0 -or
    $snapshotCommitIndex -le $commitFunctionIndex -or
    $reversibleStagingCleanupIndex -le $snapshotCommitIndex -or
    $reversibleLegacyCleanupIndex -le $reversibleStagingCleanupIndex -or
    $systemCommitPreparedIndex -le $reversibleLegacyCleanupIndex -or
    $protectedBrokerCommitIndex -le $systemCommitPreparedIndex -or
    $systemCommittedIndex -le $protectedBrokerCommitIndex -or
    $cleanupCompleteIndex -le $systemCommittedIndex) {
    $failures.Add(
        'All fallible external retirement must remain rollback-capable before SystemCommitPrepared; only forward evidence cleanup may follow the protected broker commit.')
}
foreach ($postCommitAclRewrite in @(
        'Set-EverVigilAtomicJournalFileAcl -Path $TransactionPath'
        'Set-EverVigilAtomicJournalFileAcl -Path $PendingSystemJournalPath'
        'Set-EverVigilAtomicJournalFileAcl -Path $resolvedPath')) {
    if ($installContent.Contains($postCommitAclRewrite, [StringComparison]::Ordinal) -or
        $installTransactionContent.Contains(
            $postCommitAclRewrite,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "An atomic journal writer performs a fallible ACL rewrite after its durable Move: $postCommitAclRewrite")
    }
}
$atomicCommitGuardCorpus = [regex]::Replace(
    [regex]::Replace(
        $installContent + $installTransactionContent,
        '(?m)^\s*#\s?',
        ' '),
    '\s+',
    ' ')
foreach ($atomicMoveFinalGuard in @(
        'new phase is already durable.'
        'Atomic replacement is the final fallible operation'
        'Moving it is the commit point and must be the last fallible operation.')) {
    if (-not $atomicCommitGuardCorpus.Contains(
            $atomicMoveFinalGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("An atomic journal commit-point guard is missing: $atomicMoveFinalGuard")
    }
}
foreach ($customInstallGuard in @(
        '[string]$InstallRoot = (Join-Path $env:LOCALAPPDATA'
        'Get-Variable -Name PSStyle -ErrorAction SilentlyContinue'
        "`$PSStyle.OutputRendering = 'PlainText'"
        "[Console]::Error.WriteLine('ERROR: {0}', `$_.Exception.Message)"
        'Resolve-EverVigilMaintenanceInstallRoot'
        'Assert-CompatibleInstallRoot'
        '$allowInstallRootInCurrentTemp'
        '[string]$PreviousInstallRoot'
        '[string]$TargetVersion'
        '[switch]$DeferCommit'
        '$TransactionPath'
        'Write-InstallTransactionState'
        'Get-EverVigilInstallTransactionTemporaryFiles -DataRoot $DataRoot'
        "deletionIntent = 'none'"
        '[IO.FileOptions]::WriteThrough'
        '$stream.Flush($true)'
        'destinationBackupPlanned = $destinationBackupPlanned'
        'previousBackupPlanned = $previousBackupPlanned'
        'settingsWasPresent = $settingsWasPresent'
        'tokenWasPresent = $tokenWasPresent'
        'applicationDataSnapshotReady = $false'
        'applicationDataSnapshots = @()'
        'settingsQuarantineFiles = @()'
        'tokenQuarantineFiles = @()'
        'New-EverVigilApplicationDataSnapshots'
        'Restore-EverVigilApplicationDataSnapshots'
        'Remove-EverVigilNewQuarantineFiles'
        '$script:LegacyCompatibilityDataInstallerPublishDirectoryPrefix'
        'systemConfigurationRequiredWasPresent = $systemConfigurationRequiredWasPresent'
        'Assert-EverVigilProtectedBrokerVersionLayout `'
        '$protectedBrokerPathsBeforeBootstrap.CanonicalPath'
        '$PreviousBackupRoot'
        '-AllowCurrentTempTree:$allowPreviousInstallRootInCurrentTemp'
        '-Path $StagingRoot'
        '-InstallRoot $InstallRoot'
        'Invoke-EverVigilInteractiveCommand'
        'Start-EverVigilRestoredSupervisor'
        'Assert-OwnedInstallRoot'
        'Move-Item -LiteralPath $PreviousInstallRoot -Destination $PreviousBackupRoot'
        'Move-Item -LiteralPath $PreviousBackupRoot -Destination $PreviousInstallRoot'
        'foreach ($supportScript in @('
        '$SystemScript'
        '$InstallPathResolver'
        '$InstallTransactionScript'
        '$InstallTransactionDataHelper'
        '$InteractiveTaskHelper'
        '$LegacyCompatibilityHelper'
        'protectedBrokerReady = $protectedBrokerWasPresentBefore'
        'protectedBrokerWasPresentBefore = $protectedBrokerWasPresentBefore'
        'protectedBrokerCleanupAuthorized = -not $protectedBrokerWasPresentBefore'
        '$transactionState.protectedBrokerReady = $true'
        'cleanupTransactionId = $CleanupTransactionId'
        "transactionId = ([guid]`$TransactionId).ToString('D')"
        "([guid][string]`$pending.transactionId).ToString('N')"
        "([guid][string]`$State.transactionId).ToString('N')"
        '$pending.observedTargetRouteOwnership = if ('
        '[bool]$pending.existingTargetMappingOwned)'
        '$pending.observedPreviousRouteOwnership = if ('
        '[bool]$pending.previousMappingOwned)'
        '$pending.firewallSnapshotCaptured = $true'
        '$pending.targetRouteMutationAuthorized = $true'
        '$pending.firewallMutationAuthorized = $true'
        '$pending.phase = ''MutationsCompleted'''
        'targetVersion = $TargetVersion'
        'Assert-TargetExecutableVersion -Path $publishedExecutable'
        'Assert-TargetExecutableVersion -Path $InstalledExecutable'
        '-TransactionId $cleanupTransactionId'
        'function Commit-InstallerSystemConfigurationLocally'
        "'--commit-installer-system-config'"
        "'--system-transaction-id'"
        '$transactionMutex.ReleaseMutex()'
        '$script:transactionLockTaken = $transactionMutex.WaitOne('
        "[string]`$pending.phase -cne 'MutationsCompleted'"
        'function Read-ExactAppliedSystemConfiguration'
        'Test-SameSystemConfiguration `'
        'Invoke-InitialInstallProtectedBrokerCleanup -State $transactionState'
        'Remove-InstallTransactionTree'
    )) {
    if (-not $installContent.Contains($customInstallGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Custom install destination guard is missing: $customInstallGuard")
    }
}
$protectedVersionLayoutIndex = $installContent.IndexOf(
    'Assert-EverVigilProtectedBrokerVersionLayout `',
    [StringComparison]::Ordinal)
$protectedPresenceSnapshotIndex = $installContent.IndexOf(
    '$protectedBrokerWasPresentBefore = $false',
    [StringComparison]::Ordinal)
if ($protectedVersionLayoutIndex -lt 0 -or
    $protectedPresenceSnapshotIndex -le $protectedVersionLayoutIndex) {
    $failures.Add(
        'Install must reject obsolete protected broker versions before authorizing rollback cleanup.')
}
if (-not $uninstallContent.Contains(
        'A configuration-required install can intentionally have only its local',
        [StringComparison]::Ordinal) -or
    [regex]::IsMatch(
        $uninstallContent,
        '(?s)\$primaryConfigurationOwned\s*-or\s*\(Test-Path\s+-LiteralPath\s+\$SystemConfigurationRequiredPath\)')) {
    $failures.Add(
        'A marker-only configuration-required install must remain uninstallable without a protected broker.')
}
if ($installContent.Contains(
        "Invoke-AppCommand -Arguments @('--mark-system-configured')",
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Installer Apply must use the exact transaction-bound local commit command instead of the interactive mark command.')
}
foreach ($transactionGuard in @(
        '[IO.FileOptions]::WriteThrough'
        '$stream.Flush($true)'
        "'destinationBackupPlanned'"
        "'previousBackupPlanned'"
        "'publishRoot'"
        "'settingsWasPresent'"
        "'tokenWasPresent'"
        "'applicationDataSnapshotReady'"
        "'applicationDataSnapshots'"
        "'settingsQuarantineFiles'"
        "'tokenQuarantineFiles'"
        "'systemConfigurationRequiredWasPresent'"
        "'diagnosticLoggingWasPresent'"
        "'logsRootWasPresent'"
        "'transactionsRootWasPresent'"
        "'deletionIntent'"
        "'StagedInstall'"
        "'IncompleteStaging'"
        "'TemporaryPublish'"
        "'staging'"
        "'rolledBack'"
        'function Complete-RolledBackInstallTransaction'
        'function Resolve-EverVigilInstallTransactionAtomicState'
        'Multiple atomic install transactions exist without a stable journal'
        'function Invoke-InitialInstallProtectedBrokerCleanup'
        "'cleanupTransactionId'"
        "'protectedBrokerCleanupAuthorized'"
        "'targetVersion'"
        "'SystemCommitPrepared'"
        "'SystemCommitted'"
        "'CleanupComplete'"
        'The initial broker cleanup transaction identity is missing, malformed, or reused.'
        '-TransactionId $cleanupTransactionId'
        '-Operation UninstallCleanup'
        'Complete-EverVigilProtectedBrokerRetirementFromReceipt'
        '$legacyV121AllowedFiles = @('
        "'Support\scripts\Invoke-SystemMaintenance.ps1'"
        "'Support\scripts\Resolve-SafeInstallRoot.ps1'"
        'function Remove-VerifiedTransactionTree'
        'Resume-EverVigilTransactionTreeRemoval'
        'Resolve-EverVigilFinalFileSystemPath -Path $resolved'
        'Resolve-EverVigilFinalFileSystemPath -Path $expectedFull'
        'function Stop-TransactionSupervisors'
        'Remove-EverVigilInteractiveTasksForTransaction'
        'function Remove-TransactionInteractiveTasks'
        'Temporary interactive-task cleanup failed after 3 attempts'
        'Start-EverVigilRestoredSupervisor'
        '[string]$State.previousInstallRoot'
        'function Write-SystemConfigurationRequirement'
        'System rollback failed; backend must remain stopped'
        'Restore-EverVigilApplicationDataSnapshots'
        'Remove-EverVigilNewQuarantineFiles'
        '$script:LegacyCompatibilityDataInstallerPublishDirectoryPrefix'
        'Only remaining transaction evidence is resumable from this state.'
    )) {
    if (-not $installTransactionContent.Contains($transactionGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Install transaction recovery guard is missing: $transactionGuard")
    }
}
$legacySupportCleanupMatch = [regex]::Match(
    $installTransactionContent,
    '(?s)function Remove-EverVigilLegacyUninstallSupport \{(?<body>.*?)\r?\n\}(?=\r?\n\r?\nfunction )')
$expectedLegacyV121SupportFiles = @(
    'unins000.dat'
    'unins000.exe'
    'Support\Uninstall.ps1'
    'Support\scripts\Invoke-SystemMaintenance.ps1'
    'Support\scripts\Resolve-SafeInstallRoot.ps1')
$currentOnlySupportFiles = @(
    'Support\scripts\Complete-InstallTransaction.ps1'
    'Support\scripts\InstallTransactionData.ps1'
    'Support\scripts\Invoke-InteractiveUserTask.ps1'
    'Support\scripts\LegacyCompatibility.generated.ps1')
if (-not $legacySupportCleanupMatch.Success -or
    @($expectedLegacyV121SupportFiles | Where-Object {
            -not $legacySupportCleanupMatch.Groups['body'].Value.Contains(
                "'$_'",
                [StringComparison]::Ordinal)
        }).Count -gt 0 -or
    @($currentOnlySupportFiles | Where-Object {
            $legacySupportCleanupMatch.Groups['body'].Value.Contains(
                "'$_'",
                [StringComparison]::Ordinal)
        }).Count -gt 0) {
    $failures.Add(
        'Legacy cleanup must accept the frozen v1.2.1 three-script support tree independently from the current seven-script support manifest.')
}
$interactiveTaskContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Invoke-InteractiveUserTask.ps1') `
    -Raw
foreach ($recoveryLaunchGuard in @(
        'function Start-EverVigilRestoredSupervisor'
        '$attempt -le 3'
        'Get-EverVigilProcessesAtRoot'
        "`$processPath = try { [string]`$_.Path } catch { '' }"
        'The restored supervisor exited during the post-launch stability check.'
        'Restored supervisor launch failed after 3 attempts'
    )) {
    if (-not $interactiveTaskContent.Contains(
            $recoveryLaunchGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Restored supervisor retry guard is missing: $recoveryLaunchGuard")
    }
}
$installRecoveryLaunchCount = ([regex]::Matches(
        $installContent,
        '(?m)^\s*Start-EverVigilRestoredSupervisor\s*`?\s*$')).Count
if ($installRecoveryLaunchCount -ne 4) {
    $failures.Add(
        "Every immediate rollback launch must use bounded recovery retries; found $installRecoveryLaunchCount of 4 calls.")
}
foreach ($transactionDataGuard in @(
        'function Get-EverVigilInstallTransactionTemporaryFiles'
        'function Remove-EverVigilNewApplicationDataFiles'
        'function Remove-EverVigilEmptyApplicationDataContainers'
        'function Copy-EverVigilFileDurably'
        '[IO.FileOptions]::WriteThrough'
        '$destinationStream.Flush($true)'
        'function New-EverVigilApplicationDataSnapshots'
        'function Assert-EverVigilApplicationDataSnapshotState'
        'function Restore-EverVigilApplicationDataSnapshots'
        'function Remove-EverVigilNewQuarantineFiles'
        'function Assert-EverVigilTransactionDeletionIntent'
        'function Assert-EverVigilAuthorizedPartialTree'
        'function Resume-EverVigilTransactionTreeRemoval'
        'function Invoke-EverVigilTransactionTreeRemoval'
        '[IO.FileAttributes]::ReparsePoint'
        'Get-EverVigilFileSha256 -Path $target'
        '[IO.File]::Move($temporary, $target, $true)'
        'A generated application-data artifact remained after rollback'
    )) {
    if (-not $installTransactionDataContent.Contains(
            $transactionDataGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Install transaction data guard is missing: $transactionDataGuard")
    }
}
$rolledBackRecoveryMatch = [regex]::Match(
    $installTransactionContent,
    "(?s)if \(\[string\]\`$State\.status -eq 'rolledBack'\) \{(?<body>.*?)\r?\n\s*\}")
if (-not $rolledBackRecoveryMatch.Success -or
    $rolledBackRecoveryMatch.Groups['body'].Value.Contains(
        'Remove-NewApplicationData',
        [StringComparison]::Ordinal) -or
    $rolledBackRecoveryMatch.Groups['body'].Value.Contains(
        'Restore-TransactionExternalArtifacts',
        [StringComparison]::Ordinal) -or
    $rolledBackRecoveryMatch.Groups['body'].Value.Contains(
        'Invoke-InitialInstallProtectedBrokerCleanup',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'A durable rolled-back transaction must retire evidence without repeating rollback mutations.')
}
foreach ($rollbackCleanupCaller in @($installContent, $installTransactionContent)) {
    if (-not $rollbackCleanupCaller.Contains(
            'Remove-EverVigilNewApplicationDataFiles',
            [StringComparison]::Ordinal)) {
        $failures.Add(
            'Every install rollback entrypoint must use fail-closed application-data cleanup.')
    }
    if (-not $rollbackCleanupCaller.Contains(
            'Remove-EverVigilEmptyApplicationDataContainers',
            [StringComparison]::Ordinal)) {
        $failures.Add(
            'Every install rollback entrypoint must retire newly created empty data containers.')
    }
}
$immediateJournalRemoval =
    'Remove-Item -LiteralPath $TransactionPath -Force -ErrorAction Stop'
$immediateJournalRemovalIndex = $installContent.IndexOf(
    $immediateJournalRemoval,
    [StringComparison]::Ordinal)
$immediateContainerCleanupIndex = if ($immediateJournalRemovalIndex -ge 0) {
    $installContent.IndexOf(
        'Remove-EverVigilEmptyApplicationDataContainers',
        $immediateJournalRemovalIndex + $immediateJournalRemoval.Length,
        [StringComparison]::Ordinal)
} else {
    -1
}
if ($immediateJournalRemovalIndex -lt 0 -or $immediateContainerCleanupIndex -lt 0) {
    $failures.Add(
        'Immediate rollback must recheck empty application-data containers after removing its journal.')
}
$recoveryFileCleanupMatch = [regex]::Match(
    $installTransactionContent,
    '(?ms)^function Remove-TransactionRecoveryFiles \{(?<body>.*?)^\}')
if (-not $recoveryFileCleanupMatch.Success -or
    -not $recoveryFileCleanupMatch.Groups['body'].Value.Contains(
        'Remove-EverVigilEmptyApplicationDataContainers',
        [StringComparison]::Ordinal) -or
    $recoveryFileCleanupMatch.Groups['body'].Value.Contains(
        'Remove-Item -LiteralPath $transactionsRoot',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Transaction recovery evidence cleanup must use the shared reparse-safe container helper.')
}
$transactionTokens = $null
$transactionParseErrors = $null
$transactionAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'scripts\Complete-InstallTransaction.ps1'),
    [ref]$transactionTokens,
    [ref]$transactionParseErrors)
$commitTransactionAst = $transactionAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Commit-EverVigilInstallTransaction'
    },
    $true)
$rollbackTransactionAst = $transactionAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Rollback-EverVigilInstallTransaction'
    },
    $true)
$rollbackTaskCleanupHelperAst = $transactionAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Remove-TransactionInteractiveTasks'
    },
    $true)
$rollbackTaskCleanupAst = if ($rollbackTransactionAst) {
    $rollbackTransactionAst.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Remove-TransactionInteractiveTasks'
        },
        $true)
}
$cleanupParent = if ($rollbackTaskCleanupAst) {
    $rollbackTaskCleanupAst.Parent
} else {
    $null
}
while ($cleanupParent -and
    $cleanupParent -isnot [Management.Automation.Language.TryStatementAst] -and
    $cleanupParent -ne $rollbackTransactionAst) {
    $cleanupParent = $cleanupParent.Parent
}
if (-not $commitTransactionAst -or
    $commitTransactionAst.Extent.Text.Contains('-StopInstances', [StringComparison]::Ordinal)) {
    $failures.Add('Commit recovery must delete a leftover launch task without stopping the launched tray process.')
}
if (-not $rollbackTransactionAst -or
    -not $rollbackTaskCleanupHelperAst -or
    -not $rollbackTaskCleanupHelperAst.Extent.Text.Contains('-StopInstances', [StringComparison]::Ordinal) -or
    -not $rollbackTaskCleanupHelperAst.Extent.Text.Contains('$attempt -le 3', [StringComparison]::Ordinal) -or
    $cleanupParent -isnot [Management.Automation.Language.TryStatementAst]) {
    $failures.Add('Rollback recovery must stop leftover task instances and continue recovery after cleanup errors.')
}
$firstPendingTransactionIndex = $uninstallContent.IndexOf(
    '$transactionRecoveryRoots =',
    [StringComparison]::Ordinal)
$uninstallMutexWaitIndex = $uninstallContent.IndexOf(
    '$transactionMutex.WaitOne',
    [StringComparison]::Ordinal)
$secondPendingTransactionIndex = if ($uninstallMutexWaitIndex -ge 0) {
    $uninstallContent.IndexOf(
        '$candidateInstallTransactionArtifacts =',
        $uninstallMutexWaitIndex,
        [StringComparison]::Ordinal)
} else {
    -1
}
$uninstallOwnershipIndex = if ($guardedOwnershipAssertions.Count -eq 1) {
    $guardedOwnershipAssertions[0].Extent.StartOffset
} else {
    -1
}
if ($firstPendingTransactionIndex -lt 0 -or
    $uninstallMutexWaitIndex -lt 0 -or
    $secondPendingTransactionIndex -lt 0 -or
    $uninstallOwnershipIndex -lt 0 -or
    $firstPendingTransactionIndex -gt $uninstallMutexWaitIndex -or
    $secondPendingTransactionIndex -lt $uninstallMutexWaitIndex -or
    $secondPendingTransactionIndex -gt $uninstallOwnershipIndex) {
    $failures.Add('Uninstall must recheck pending recovery and installation ownership while holding the transaction mutex.')
}
$relocatedProcessGuardIndex = $uninstallContent.LastIndexOf(
    'Assert-NoSupervisorOutsideInstallRoot -Location $processLocations',
    [StringComparison]::Ordinal)
$systemCleanupArgumentsIndex = $uninstallContent.IndexOf(
    '[void](Invoke-UninstallSystemBrokerOperation',
    [StringComparison]::Ordinal)
$instanceLockIndex = $uninstallContent.IndexOf(
    '$instanceMutex.WaitOne',
    [StringComparison]::Ordinal)
if ($relocatedProcessGuardIndex -lt 0 -or
    $systemCleanupArgumentsIndex -lt 0 -or
    $instanceLockIndex -lt 0 -or
    $relocatedProcessGuardIndex -gt $systemCleanupArgumentsIndex -or
    $instanceLockIndex -gt $relocatedProcessGuardIndex -or
    [regex]::Matches(
        $uninstallContent,
        'Assert-NoSupervisorOutsideInstallRoot -Location \$processLocations').Count -lt 2) {
    $failures.Add('Uninstall must hold the instance gate and reject relocated or unreadable supervisor processes before system cleanup.')
}
$journalIndex = $installContent.IndexOf(
    'Write-InstallTransactionState -State $transactionState',
    [StringComparison]::Ordinal)
$shutdownIndex = $installContent.IndexOf("-Arguments @('--shutdown')", [StringComparison]::Ordinal)
$destinationMoveIndex = $installContent.IndexOf(
    'Move-Item -LiteralPath $InstallRoot -Destination $BackupRoot',
    [StringComparison]::Ordinal)
$publishDirectoryIndex = $installContent.IndexOf(
    'New-Item -ItemType Directory -Path $PublishRoot -Force',
    [StringComparison]::Ordinal)
$publishOutputIndex = $installContent.IndexOf('-o $PublishRoot', [StringComparison]::Ordinal)
$stagingCopyIndex = $installContent.IndexOf(
    'Copy-Item -LiteralPath $PublishRoot -Destination $StagingRoot -Recurse',
    [StringComparison]::Ordinal)
$stagingStatusIndex = $installContent.IndexOf("status = 'staging'", [StringComparison]::Ordinal)
$pendingStatusIndex = $installContent.IndexOf(
    "`$transactionState.status = 'pending'",
    [StringComparison]::Ordinal)
$stagingOwnershipIndex = $installContent.IndexOf(
    'Write-EverVigilInstallOwnership',
    [StringComparison]::Ordinal)
$systemIntentIndex = $installContent.IndexOf(
    '$transactionState.migrationApplied = $true',
    [StringComparison]::Ordinal)
$systemPreparedJournalIndex = $installContent.LastIndexOf(
    'New-InstallPendingSystemJournal',
    [StringComparison]::Ordinal)
$systemMutationIndex = if ($systemPreparedJournalIndex -ge 0) {
    $installContent.IndexOf(
        'Invoke-SystemBrokerMaintenance',
        $systemPreparedJournalIndex,
        [StringComparison]::Ordinal)
} else {
    -1
}
$systemCompletionEvidenceIndex = $installContent.IndexOf(
    "[string]`$pendingSystemState.phase -cne 'MutationsCompleted'",
    [StringComparison]::Ordinal)
if ($journalIndex -lt 0 -or $shutdownIndex -lt 0 -or $destinationMoveIndex -lt 0 -or
    $journalIndex -gt $shutdownIndex -or $journalIndex -gt $destinationMoveIndex) {
    $failures.Add('The durable install journal must be written before runtime or program-file mutation.')
}
if ($publishDirectoryIndex -lt 0 -or
    $publishOutputIndex -lt 0 -or
    $stagingCopyIndex -lt 0 -or
    $stagingStatusIndex -lt 0 -or
    $pendingStatusIndex -lt 0 -or
    $stagingOwnershipIndex -lt 0 -or
    $journalIndex -gt $publishDirectoryIndex -or
    $journalIndex -gt $publishOutputIndex -or
    $journalIndex -gt $stagingCopyIndex -or
    $stagingStatusIndex -gt $journalIndex -or
    $pendingStatusIndex -lt $stagingOwnershipIndex) {
    $failures.Add('The staging journal must precede publish/copy work and remain staging until ownership verifies.')
}
if ($systemPreparedJournalIndex -lt 0 -or $systemMutationIndex -lt 0 -or
    $systemPreparedJournalIndex -gt $systemMutationIndex -or
    $systemIntentIndex -lt 0 -or
    $systemCompletionEvidenceIndex -lt 0 -or
    $systemIntentIndex -lt $systemMutationIndex -or
    $systemIntentIndex -lt $systemCompletionEvidenceIndex) {
    $failures.Add('Install must persist Prepared before elevation and mark migration applied only after durable MutationsCompleted evidence.')
}
if (-not $installContent.Contains(
        'Run Install.ps1 from a non-administrator PowerShell.',
        [StringComparison]::Ordinal) -or
    -not $installContent.Contains(
        '$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
        [StringComparison]::Ordinal)) {
    $failures.Add('Install must reject an elevated parent before launching the persistent tray application.')
}
foreach ($requiredGuard in @(
        '$startupWasRegistered -and -not $rollbackError'
        '$existingSupervisorWasRunning -and -not $rollbackError'
        'System rollback failed; backend must remain stopped'
        '-WorkingDirectory $InstallRoot'
    )) {
    if (-not $installContent.Contains($requiredGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Install rollback safety guard is missing: $requiredGuard")
    }
}
if ([regex]::Matches($installContent, '-WorkingDirectory \$InstallRoot').Count -ne 4 -or
    [regex]::Matches($installContent, '-WorkingDirectory \$PreviousInstallRoot').Count -ne 4) {
    $failures.Add('Installed-application launches must use the corresponding current or previous install directory.')
}
foreach ($legacyCredentialGuard in @(
        'function Get-LegacyTokenCredential'
        'function Get-ProfilePathForSid'
        'function Get-LegacyRootCandidatesForProfile'
        '$ownerProfilePath = Get-ProfilePathForSid -Sid $ownerSid'
        '$script:LegacyCompatibilityOlderEvenTerminalCodexDriveLauncherRelativeToProfileDirectory'
        '$portableSuffix = [IO.Path]::GetDirectoryName($portableLauncher)'
        'Get-PSDrive -PSProvider FileSystem'
        '$legacyCredential = Get-LegacyTokenCredential -CandidateRoots $LegacyRootCandidates'
        "'--initialize-legacy-settings'"
        "'--legacy-token-file', `$LegacyTokenPath"
        "'--legacy-root', `$LegacyRoot"
        'Multiple valid legacy credentials were found'
        'Remove-Item -LiteralPath $LegacyTokenPath -Force'
    )) {
    if (-not $installContent.Contains($legacyCredentialGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Legacy credential migration guard is missing: $legacyCredentialGuard")
    }
}
if ($installContent.Contains('Remove-ExactTree -Path $LegacyRoot', [StringComparison]::Ordinal) -or
    $installContent.Contains('Remove-Item -LiteralPath $LegacyRoot', [StringComparison]::Ordinal)) {
    $failures.Add('Legacy migration must retire only the validated plaintext token, not its directory.')
}
if ($installContent.Contains('$legacyImportArguments', [StringComparison]::Ordinal) -or
    -not $installContent.Contains(
        '-not (Test-Path -LiteralPath $TokenPath -PathType Leaf)',
        [StringComparison]::Ordinal) -or
    $installContent.IndexOf("'--initialize-legacy-settings'", [StringComparison]::Ordinal) -gt
        $installContent.IndexOf("@('--import-token-file', `$LegacyTokenPath)", [StringComparison]::Ordinal)) {
    $failures.Add('Legacy settings initialization must be separate from token import, and existing DPAPI tokens must be preserved.')
}
if (-not $installContent.Contains('Persisted settings are missing while applied system configuration exists.', [StringComparison]::Ordinal)) {
    $failures.Add('Install must fail closed when settings are missing but an applied system configuration remains.')
}
if (-not $installContent.Contains('Persisted settings do not match the last applied system configuration.', [StringComparison]::Ordinal) -or
    -not $installContent.Contains('Test-SameSystemConfiguration -Left $configuration -Right $appliedConfiguration', [StringComparison]::Ordinal)) {
    $failures.Add('Install must fail closed when persisted and applied system configurations disagree.')
}
foreach ($transactionContent in @($installContent, $uninstallContent)) {
    if (-not $transactionContent.Contains(
            'New-EverVigilSystemTransactionMutex',
            [StringComparison]::Ordinal) -or
        -not $transactionContent.Contains('WaitOne([TimeSpan]::FromMinutes(10))', [StringComparison]::Ordinal) -or
        -not $transactionContent.Contains('ReleaseMutex()', [StringComparison]::Ordinal)) {
        $failures.Add('Install and uninstall must share a bounded machine-wide transaction mutex.')
        break
    }
}
foreach ($mutexAclGuard in @(
        'function New-EverVigilSystemTransactionMutex'
        '$script:LegacyCompatibilitySynchronizationSystemTransactionMutex'
        '[Threading.MutexAcl]::Create('
        '[Security.Principal.WellKnownSidType]::AuthenticatedUserSid'
        "[Security.AccessControl.MutexRights]'Synchronize, Modify'"
        '[Security.AccessControl.MutexRights]::FullControl'
    )) {
    if (-not $installPathResolverContent.Contains(
            $mutexAclGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("The cross-account UAC mutex ACL guard is missing: $mutexAclGuard")
    }
}
foreach ($brokerApplyGuard in @(
        '$appliedSystemConfigurationWasPresent'
        'New-InstallPendingSystemJournal'
        'Invoke-SystemBrokerMaintenance'
        '-MigrateV121SystemState:$migrateV121SystemState'
        '$migrateV121SystemState = [bool]$legacyCleanupAuthorized -and'
        'if (-not $systemConfigurationCanBePreserved -or'
        "[string]`$pendingSystemState.phase -cne 'MutationsCompleted'"
    )) {
    if (-not $installContent.Contains($brokerApplyGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Installer protected-broker Apply guard is missing: $brokerApplyGuard")
    }
}
foreach ($forbiddenOwnershipForwarding in @(
        '-LegacyCredentialOwned:'
        '-MigrateV121SystemState:$legacyCredentialFound'
    )) {
    if ($installContent.Contains(
            $forbiddenOwnershipForwarding,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Install must not forward caller-invented system ownership: $forbiddenOwnershipForwarding")
    }
}
if (-not $installContent.Contains('-not $preserveRecoveryArtifacts', [StringComparison]::Ordinal)) {
    $failures.Add('Install must retain the data-root recovery state when system rollback fails.')
}
$missingBrokerRecoveryGuards = @(
    @(
        'function Invoke-SystemBrokerTransaction'
        '-Operation $Mode'
        "@('Completed', 'NoChange')"
        "@('RolledBack', 'NoChange')"
        '[string]$brokerResponse.disposition -cnotin $expectedDispositions'
    ) | Where-Object {
        -not $installTransactionContent.Contains($_, [StringComparison]::Ordinal)
    })
if ($installContent.Contains('function Test-SystemRollbackCompleted', [StringComparison]::Ordinal) -or
    -not $installContent.Contains(
        '(Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf)',
        [StringComparison]::Ordinal) -or
    $missingBrokerRecoveryGuards.Count -gt 0) {
    $failures.Add(
        'Install recovery must use the broker ledger plus durable local pending journal, never a mutable system.log marker.')
}
if (-not $installContent.Contains("-Arguments @('--installer-runtime-check')", [StringComparison]::Ordinal) -or
    -not $installContent.Contains('-TimeoutSeconds 240', [StringComparison]::Ordinal)) {
    $failures.Add('Install must run the bounded headless runtime check without launching the tray UI.')
}
if (-not $installContent.Contains(
        '($migrationApplied -or',
        [StringComparison]::Ordinal) -or
    $installContent.Contains(
        'migrationApplied is not ownership evidence',
        [StringComparison]::Ordinal)) {
    $failures.Add('Immediate rollback must defer ownership authority to the protected broker ledger after local commit.')
}
if (-not $installContent.Contains('return Invoke-EverVigilBoundedProcess', [StringComparison]::Ordinal) -or
    -not $installTransactionContent.Contains('$exitCode = Invoke-EverVigilBoundedProcess', [StringComparison]::Ordinal)) {
    $failures.Add('Install and rollback commands must retain the process handle acquired at launch.')
}
foreach ($configurationGuard in @(
        'function Resolve-InitialTailscalePath'
        '[EnvironmentVariableTarget]::User'
        '[EnvironmentVariableTarget]::Machine'
        'Invoke-EverVigilInteractiveCommand'
        'function Test-ExistingSupervisorHealth'
        '$tokenWasPresent -and'
        '$systemConfigurationCanBePreserved = $false'
        'if (-not $systemConfigurationCanBePreserved -or'
        'whose protected ledger is the sole ownership authority.'
        'if ($runtimeConfigurationReady) {'
        '$existingSupervisorWasHealthy -and -not $runtimeConfigurationReady'
        'The replacement supervisor configuration is invalid even though the previous version was healthy.'
        "-Arguments @('--installer-runtime-check')"
        'The installed runtime did not become healthy within three minutes.'
        '$runtimeConfigurationReady -and'
        'preserved until system migration completes'
        "'CONFIGURATION REQUIRED'"
    )) {
    if (-not $installContent.Contains($configurationGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Install must remain available when runtime dependencies need configuration: $configurationGuard")
    }
}
foreach ($obsoleteInstallLaunchGuard in @(
        'Invoke-SystemBrokerMaintenance -Mode Prepare'
        'function Wait-NewSupervisorHealthy'
        'function Wait-NewSupervisorStarted'
    )) {
    if ($installContent.Contains(
            $obsoleteInstallLaunchGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Install must not elevate or launch the visible tray during preparation: $obsoleteInstallLaunchGuard")
    }
}
$installTokens = $null
$installParseErrors = $null
$installAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'Install.ps1'),
    [ref]$installTokens,
    [ref]$installParseErrors)
$healthValidatorAst = $installAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-ExistingSupervisorHealth'
    },
    $true)
if (-not $healthValidatorAst) {
    $failures.Add('Install read-only health preservation validator is missing.')
} else {
    $healthValidatorContent = $healthValidatorAst.Extent.Text
    foreach ($healthGuard in @(
            'ProtectedData]::Unprotect'
            '$handler.AllowAutoRedirect = $false'
            '$handler.UseProxy = $false'
            '"http://127.0.0.1:$BackendPort/api/sessions?provider=codex&limit=1"'
            'JsonDocument]::Parse'
            "TryGetProperty('sessions'"
            "TryGetProperty('error'"
        )) {
        if (-not $healthValidatorContent.Contains($healthGuard, [StringComparison]::Ordinal)) {
            $failures.Add("Read-only health preservation guard is missing: $healthGuard")
        }
    }
    foreach ($forbiddenHealthMutation in @(
            'WriteAll'
            'Set-Content'
            'Move-Item'
            'Remove-Item'
            'ProtectedData]::Protect'
            'SettingsPath'
            'PublicPort'
            'publicHost'
            'UriBuilder'
            'Dns'
        )) {
        if ($healthValidatorContent.Contains($forbiddenHealthMutation, [StringComparison]::Ordinal)) {
            $failures.Add("Preflight health validation must remain read-only: $forbiddenHealthMutation")
        }
    }
    if ([regex]::Matches($healthValidatorContent, '(?i)https?://').Count -ne 1) {
        $failures.Add(
            'Installer token health must expose exactly one fixed loopback HTTP destination; redirects, host settings, and DNS destinations are forbidden.')
    }
}
$legacyRootResolverAst = $installAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-LegacyRootCandidatesForProfile'
    },
    $true)
if (-not $legacyRootResolverAst -or
    $installContent.Contains('[Environment]::UserName', [StringComparison]::Ordinal) -or
    -not $installContent.Contains('ProfileList\$Sid', [StringComparison]::Ordinal) -or
    -not $installContent.Contains(
        '$ownerProfilePath = Get-ProfilePathForSid -Sid $ownerSid',
        [StringComparison]::Ordinal)) {
    $failures.Add('Install must derive legacy roots from the invoking SID profile.')
} else {
    Invoke-Expression $legacyRootResolverAst.Extent.Text
    $syntheticProfileName = 'alice.DOMAIN'
    $syntheticProfile = Join-Path 'C:\' (Join-Path 'Users' $syntheticProfileName)
    $syntheticRoots = @('C:\', 'D:\')
    $legacyRootCandidates = @(Get-LegacyRootCandidatesForProfile `
            -ProfilePath $syntheticProfile `
            -FileSystemRoots $syntheticRoots)
    $expectedLocalRoot = [IO.Path]::Combine(
        $syntheticProfile,
        $script:LegacyCompatibilityOlderEvenTerminalCodexLocalAppDataRootRelativeToProfile)
    $portableLauncher =
        $script:LegacyCompatibilityOlderEvenTerminalCodexDriveLauncherRelativeToProfileDirectory.Replace(
            '{profileDirectory}',
            $syntheticProfileName,
            [StringComparison]::Ordinal)
    $portableSuffix = [IO.Path]::GetDirectoryName($portableLauncher)
    $expectedPortableRoots = @($syntheticRoots | ForEach-Object {
            [IO.Path]::Combine($_, $portableSuffix)
        })
    if ($legacyRootCandidates.Count -ne 3 -or
        $expectedLocalRoot -notin $legacyRootCandidates -or
        @($expectedPortableRoots | Where-Object { $_ -notin $legacyRootCandidates }).Count -gt 0) {
        $failures.Add('Install legacy roots did not preserve a suffixed profile-directory name.')
    }
}
$tailscaleResolverAst = $installAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-InitialTailscalePath'
    },
    $true)
if (-not $tailscaleResolverAst) {
    $failures.Add('Install Tailscale resolver could not be executed for PATH discovery testing.')
} else {
    Invoke-Expression $tailscaleResolverAst.Extent.Text
    $tailscaleFixtureRoot = Join-Path $env:TEMP "EverVigil.Tailscale-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $tailscaleFixtureRoot | Out-Null
        $fakeTailscalePath = Join-Path $tailscaleFixtureRoot 'tailscale.exe'
        $fixtureMarker = [Guid]::NewGuid().ToString('N')
        Set-Content `
            -LiteralPath $fakeTailscalePath `
            -Value $fixtureMarker `
            -Encoding ASCII `
            -NoNewline
        $missingPreferredPath = Join-Path $tailscaleFixtureRoot 'missing\tailscale.exe'
        $resolvedTailscalePath = Resolve-InitialTailscalePath `
            -PreferredPath $missingPreferredPath `
            -SearchPathValues @($tailscaleFixtureRoot)
        $fixtureExists = Test-Path -LiteralPath $fakeTailscalePath -PathType Leaf
        $resolvedExists = Test-Path -LiteralPath $resolvedTailscalePath -PathType Leaf
        $resolvedMarker = if ($resolvedExists) {
            Get-Content -LiteralPath $resolvedTailscalePath -Raw
        } else {
            $null
        }
        if (-not $fixtureExists -or
            -not $resolvedExists -or
            -not [string]::Equals(
                $resolvedMarker,
                $fixtureMarker,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "Install did not discover a nonstandard Tailscale executable from PATH. " +
                "Expected='$fakeTailscalePath'; Actual='$resolvedTailscalePath'; " +
                "FixtureExists=$fixtureExists; ResolvedExists=$resolvedExists")
        }
    } finally {
        Remove-Item -LiteralPath $tailscaleFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$configurationReadIndex = $installContent.IndexOf('$configuredPorts = Get-ConfiguredPorts', [StringComparison]::Ordinal)
$packageSelectionIndex = $installContent.LastIndexOf(
    'if (Test-Path -LiteralPath $BundledExecutable -PathType Leaf)',
    [StringComparison]::Ordinal)
if ($configurationReadIndex -lt 0 -or
    $packageSelectionIndex -lt 0 -or
    $configurationReadIndex -gt $packageSelectionIndex) {
    $failures.Add('Install must validate persisted configuration before publishing or replacing the application.')
}

$maintenanceContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'scripts\Invoke-SystemMaintenance.ps1') `
    -Raw
$brokerProtocolContent = @(Get-ChildItem `
        -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Broker.Protocol') `
        -Filter '*.cs' `
        -File `
        -Force | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw
        }) -join "`n"
$brokerSourceContent = @(Get-ChildItem `
        -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Broker') `
        -Filter '*.cs' `
        -File `
        -Force | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw
        }) -join "`n"
$brokerProjectContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Broker\EverVigil.Broker.csproj') `
    -Raw
$brokerProtocolProjectContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Broker.Protocol\EverVigil.Broker.Protocol.csproj') `
    -Raw
foreach ($mediumAdapterGuard in @(
        'This script is intentionally a medium-integrity protocol adapter.'
        'Invoke-EverVigilSystemBroker'
        "[ValidateSet('Interactive', 'Installer')]"
        '[switch]$MigrateV121SystemState'
    )) {
    if (-not $maintenanceContent.Contains(
            $mediumAdapterGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Medium system-adapter guard is missing: $mediumAdapterGuard")
    }
}
foreach ($brokerSecurityGuard in @(
        'GetNamedPipeClientProcessId'
        'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow'
        'PrivilegedBrokerDisposition.CanonicalReady'
        'ProtectedBrokerInstallation.LockLoadedImage()'
        'FileOptions.WriteThrough'
        'FileShare.Read'
        'InstallationReceiptFileName = "installation.json"'
        'PrivilegedBrokerErrorCode.FunnelDetected'
        'Run("serve", "status", "--json")'
        'PrivilegedBrokerOperation.UninstallCleanup'
        'WellKnownSidType.AuthenticatedUserSid'
        'JsonSourceGenerationOptions('
        'BrokerJsonContext.Default'
        'PrivilegedBrokerJsonContext.Default'
        'CoCreateInstance('
        'delegate* unmanaged[Stdcall]'
        'DefaultDllImportSearchPaths(DllImportSearchPath.System32)'
    )) {
    if (-not ($brokerProtocolContent + $brokerSourceContent).Contains(
            $brokerSecurityGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Compiled privileged-broker guard is missing: $brokerSecurityGuard")
    }
}
foreach ($forbiddenReusablePathDeletion in @(
        'MOVEFILE_DELAY_UNTIL_REBOOT'
        'MoveFileEx(')) {
    if ($brokerSourceContent.Contains(
            $forbiddenReusablePathDeletion,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add(
            "The protected broker must not schedule its reusable canonical path for reboot deletion: $forbiddenReusablePathDeletion")
    }
}
foreach ($aotProjectGuard in @(
        '<IsAotCompatible>true</IsAotCompatible>'
        '<JsonSerializerIsReflectionEnabledByDefault>false</JsonSerializerIsReflectionEnabledByDefault>'
        '<NuGetLockFilePath Condition="''$(PublishAot)'' == ''true''">$(MSBuildProjectDirectory)\packages.aot.lock.json</NuGetLockFilePath>'
    )) {
    if (-not $brokerProjectContent.Contains($aotProjectGuard, [StringComparison]::Ordinal) -or
        -not $brokerProtocolProjectContent.Contains($aotProjectGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Every privileged broker assembly must enforce its AOT contract: $aotProjectGuard")
    }
}
foreach ($nativeBrokerProjectGuard in @(
        '<PublishAot Condition="''$(Configuration)'' == ''Release'' and ''$(RuntimeIdentifier)'' == ''win-x64''">true</PublishAot>'
        '<LinkerArg Include="/DEPENDENTLOADFLAG:0x800" />'
        '<AllowUnsafeBlocks>true</AllowUnsafeBlocks>'
    )) {
    if (-not $brokerProjectContent.Contains(
            $nativeBrokerProjectGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Native privileged-broker project guard is missing: $nativeBrokerProjectGuard")
    }
}
foreach ($forbiddenManagedBrokerPrimitive in @(
        'Type.GetTypeFromProgID'
        'Activator.CreateInstance'
        'InvokeMember('
        'Marshal.IsComObject'
        'System.Reflection'
    )) {
    if (($brokerProtocolContent + $brokerSourceContent).Contains(
            $forbiddenManagedBrokerPrimitive,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Native broker retains an AOT-incompatible managed primitive: $forbiddenManagedBrokerPrimitive")
    }
}
$nativeBrokerPublishMatch = [regex]::Match(
    $buildReleaseContent,
    '(?s)& \$dotnetCommand\.Source publish `\r?\n\s+\$brokerProjectPath `(?<body>.*?)\r?\nif \(\$LASTEXITCODE -ne 0\)')
if (-not $nativeBrokerPublishMatch.Success) {
    $failures.Add('Formal release does not contain a uniquely identifiable broker publish block.')
} else {
    $nativeBrokerPublishBody = $nativeBrokerPublishMatch.Groups['body'].Value
    foreach ($nativePublishGuard in @(
            '-p:PublishAot=true'
            '-p:StripSymbols=true'
            '-p:IlcOptimizationPreference=Speed'
        )) {
        if (-not $nativeBrokerPublishBody.Contains(
                $nativePublishGuard,
                [StringComparison]::Ordinal)) {
            $failures.Add("Native broker publish guard is missing: $nativePublishGuard")
        }
    }
    foreach ($forbiddenManagedPublishOption in @(
            '-p:PublishSingleFile=true'
            '-p:IncludeNativeLibrariesForSelfExtract=true'
            '-p:EnableCompressionInSingleFile=true'
        )) {
        if ($nativeBrokerPublishBody.Contains(
                $forbiddenManagedPublishOption,
                [StringComparison]::Ordinal)) {
            $failures.Add(
                "Native broker publish retained a managed-bundle option: $forbiddenManagedPublishOption")
        }
    }
}
foreach ($nativePreMainGuard in @(
        'Assert-NativeAotRestoreGraph'
        'The reviewed NativeAOT lock file is missing:'
        'packages.aot.lock.json'
        '''Microsoft.DotNet.ILCompiler'''
        '''runtime.win-x64.Microsoft.DotNet.ILCompiler'''
        '$compilerVersion = ''8.0.30'''
        '[Text.Json.JsonDocument]::Parse('
        'NativeAOT lock must contain one exact win-x64 target:'
        'Unreviewed NativeAOT lock evidence:'
        'Test-NativePortableExecutable'
        '$reader.PEHeaders.CorHeader'
        'LoadConfigTableDirectory'
        '$dependentLoadFlags = [BitConverter]::ToUInt16($loadConfigBytes, 78)'
        '($dependentLoadFlags -band 0x0800) -ne 0x0800'
        'Test-NativeBrokerPreMainIsolation'
        'DOTNET_STARTUP_HOOKS'
        'DOTNET_ADDITIONAL_DEPS'
        'DOTNET_BUNDLE_EXTRACT_BASE_DIR'
        'CORECLR_ENABLE_PROFILING'
        'COMPlus_ReadyToRun'
        "'wintrust.dll'"
        "'ole32.dll'"
    )) {
    if (-not $buildReleaseContent.Contains($nativePreMainGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Native broker pre-Main negative guard is missing: $nativePreMainGuard")
    }
}
$nativeAotInitialPreflightIndex = $buildReleaseContent.IndexOf(
    'Assert-NativeAotRestoreGraph `',
    [StringComparison]::Ordinal)
$releaseCleanMutationIndex = $buildReleaseContent.IndexOf(
    '& $dotnetCommand.Source @releaseCleanArguments',
    [StringComparison]::Ordinal)
$nativeAotPreflightIndex = $buildReleaseContent.LastIndexOf(
    'Assert-NativeAotRestoreGraph `',
    [StringComparison]::Ordinal)
$brokerTestBuildMutationIndex = $buildReleaseContent.IndexOf(
    '& $dotnetCommand.Source @brokerTestBuildArguments',
    [StringComparison]::Ordinal)
$brokerTestRunMutationIndex = $buildReleaseContent.IndexOf(
    '& $dotnetCommand.Source @brokerTestArguments',
    [StringComparison]::Ordinal)
$releaseOutputMutationIndex = $buildReleaseContent.IndexOf(
    'Remove-ReleaseWorkingTreesWithRetry `',
    [StringComparison]::Ordinal)
if ($nativeAotInitialPreflightIndex -lt 0 -or
    $releaseCleanMutationIndex -lt 0 -or
    $nativeAotPreflightIndex -le $nativeAotInitialPreflightIndex -or
    $brokerTestBuildMutationIndex -lt 0 -or
    $brokerTestRunMutationIndex -lt 0 -or
    $releaseOutputMutationIndex -lt 0 -or
    $nativeAotInitialPreflightIndex -gt $releaseCleanMutationIndex -or
    $releaseCleanMutationIndex -gt $nativeAotPreflightIndex -or
    $nativeAotPreflightIndex -gt $brokerTestBuildMutationIndex -or
    $brokerTestBuildMutationIndex -gt $brokerTestRunMutationIndex -or
    $brokerTestRunMutationIndex -gt $releaseOutputMutationIndex) {
    $failures.Add(
        'NativeAOT preflight, clean rebuild, managed broker build, broker run, and release-output mutation are out of order.')
}
$privilegedPowerShellSurface = @(
    $installContent
    $uninstallContent
    $maintenanceContent
    $installPathResolverContent
    (Get-Content `
        -LiteralPath (Join-Path `
            $RepositoryRoot `
            'scripts\Complete-InstallTransaction.ps1') `
        -Raw)
) -join "`n"
if ([regex]::Matches($privilegedPowerShellSurface, '(?im)-Verb\s+RunAs\b').Count -ne 1 -or
    [regex]::Matches($installPathResolverContent, '(?im)-Verb\s+RunAs\b').Count -ne 1) {
    $failures.Add('PowerShell must contain exactly one RunAs call in the fixed broker client.')
}
foreach ($forbiddenPowerShellMutation in @(
        'Remove-NetFirewallRule'
        'New-NetFirewallRule'
        'Unregister-ScheduledTask'
        "@('serve', '--yes'"
        "@('serve', 'reset'"
        'ApplicationExecutablePath'
    )) {
    if ($privilegedPowerShellSurface.Contains(
            $forbiddenPowerShellMutation,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Privileged mutation/elevation remains in user-writable PowerShell: $forbiddenPowerShellMutation")
    }
}
foreach ($installedDocument in @("'README.md'", "'SECURITY.md'")) {
    if (-not $installContent.Contains($installedDocument, [StringComparison]::Ordinal)) {
        $failures.Add("Installed documentation support file is missing: $installedDocument")
    }
}

$programContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Program.cs') `
    -Raw
$settingsStoreContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\SettingsStore.cs') `
    -Raw
$pendingSystemContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\PendingSystemConfigurationStore.cs') `
    -Raw
$appSettingsContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil.Core\AppSettings.cs') `
    -Raw
foreach ($legacySettingsGuard in @(
        '--initialize-legacy-settings'
        '--legacy-token-file'
        '--legacy-root'
        'CreateLegacyMigrationDefaults'
        'TryReplaceNewlyCreatedDefaults'
        'AppSettings.CreateDefault(fullLegacyRoot)'
        'legacyLayout.Value.AppsDirectory'
        'legacyAppsDirectory'
    )) {
    if (-not ($programContent + $settingsStoreContent + $appSettingsContent).Contains(
            $legacySettingsGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Legacy dependency migration guard is missing: $legacySettingsGuard")
    }
}
foreach ($startupValidationGuard in @(
        '--validate-settings'
        'ShouldStartSupervisor('
        'AppSettingsValidator.Validate(settings).Count == 0'
        'forceStartRequested || AppSettingsValidator.Validate(settings).Count == 0'
        'Runtime dependencies are not configured. The tray application is waiting for settings.'
    )) {
    if (-not $programContent.Contains($startupValidationGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Dependency-aware startup guard is missing: $startupValidationGuard")
    }
}
$systemConfigurationContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\SystemConfigurationService.cs') `
    -Raw
$privilegedBrokerClientContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\PrivilegedBrokerClient.cs') `
    -Raw
foreach ($interactiveSafetyGuard in @(
        'ValidateFixedConfiguration(settings);'
        'existing.Initiator == PendingSystemConfigurationInitiator.Installer'
        'PrivilegedBrokerOperation.Recover'
        'ReconcileLocalRecovery(pendingStore, existing, response, settings)'
        'var pending = RunSystemTransaction(() => pendingStore.Begin('
        'PrivilegedBrokerOperation.Apply'
        'response.Disposition != PrivilegedBrokerDisposition.Completed'
        'pendingStore.MarkProtectedBrokerCompleted(pending.TransactionId)'
        'current.Phase == PendingSystemConfigurationPhase.Prepared'
        'pendingStore.CancelUnmutated(pending.TransactionId);'
        'internal const string SystemTransactionMutexName ='
        'LegacyCompatibility.Synchronization.SystemTransactionMutex;'
        'transactionMutex.WaitOne(SystemTransactionTimeout)'
        'MutexAcl.Create('
        'WellKnownSidType.AuthenticatedUserSid'
        'MutexRights.Synchronize | MutexRights.Modify'
        'Environment.SpecialFolder.ProgramFiles'
        '"Tailscale",'
        '"tailscale.exe"'
    )) {
    if (-not $systemConfigurationContent.Contains($interactiveSafetyGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Interactive system configuration safety guard is missing: $interactiveSafetyGuard")
    }
}
foreach ($brokerClientGuard in @(
        'PrivilegedBrokerPaths.GetProtectedExecutablePath('
        'ValidateCanonicalInstallation()'
        'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow'
        'ReadStrictReceipt(receiptPath)'
        'File.ReadAllBytes(path)'
        'FileOptions.SequentialScan'
        'CryptographicOperations.FixedTimeEquals('
        'ValidateProtectedPath(commonData, path);'
        'security.AreAccessRulesProtected'
        '(rule.FileSystemRights & DangerousRights) == 0'
        'UseShellExecute = true'
        'Verb = "runas"'
        'startInfo.ArgumentList.Add("--client-pid")'
        'startInfo.ArgumentList.Add("--pipe")'
        'startInfo.ArgumentList.Add("--nonce")'
        'startInfo.ArgumentList.Add("--transaction-id")'
        'new NamedPipeClientStream('
        'PipeOptions.Asynchronous | PipeOptions.WriteThrough'
        'PrivilegedBrokerProtocol.WriteFrameAsync('
        'ReadFrameAsync<PrivilegedBrokerResponse>'
        'PrivilegedBrokerInitiator.Interactive'
    )) {
    if (-not $privilegedBrokerClientContent.Contains(
            $brokerClientGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Interactive protected-broker client guard is missing: $brokerClientGuard")
    }
}
foreach ($forbiddenInteractivePrivilegeSurface in @(
        '--bootstrap'
        '--owner-sid'
        '--data-root'
        'tailscale serve'
        'New-NetFirewallRule'
        'Remove-NetFirewallRule'
        'ApplicationExecutablePath'
    )) {
    if (($systemConfigurationContent + $privilegedBrokerClientContent).Contains(
            $forbiddenInteractivePrivilegeSurface,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add(
            "Interactive application retains a caller-controlled or direct privilege surface: $forbiddenInteractivePrivilegeSurface")
    }
}
foreach ($pendingJournalGuard in @(
        'internal const string FileName = "pending-system-configuration.json";'
        'internal const int CurrentSchemaVersion = 1;'
        'internal enum PendingSystemConfigurationInitiator'
        'Installer'
        'MarkProtectedBrokerCompleted(Guid transactionId)'
        'Only an interactive coordination journal may mirror protected broker completion.'
        'FileOptions.WriteThrough'
        'stream.Flush(flushToDisk: true);'
        'var temporaryPath = $"{destinationPath}.{transactionId:N}.tmp";'
        'EnsureRegularFile(temporaryPath);'
        'EnsureNoReparsePoint('
        'ResolveLocalAppData(_ownerSid)'
        'using (var stream = AccessControlService.CreateRestrictedFile('
        'File.Move(temporaryPath, destinationPath, overwrite);'
    )) {
    if (-not $pendingSystemContent.Contains($pendingJournalGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Pending system configuration journal guard is missing: $pendingJournalGuard")
    }
}
if ($pendingSystemContent.Contains(
        'AccessControlService.RestrictFile(destinationPath, _ownerSid);',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Pending system configuration rewrites the ACL after its durable atomic Move.')
}
$pendingCreateIndex = $pendingSystemContent.IndexOf(
    'using (var stream = AccessControlService.CreateRestrictedFile(',
    [StringComparison]::Ordinal)
$pendingFlushIndex = $pendingSystemContent.IndexOf(
    'stream.Flush(flushToDisk: true);',
    $pendingCreateIndex + 1,
    [StringComparison]::Ordinal)
$pendingMoveIndex = $pendingSystemContent.IndexOf(
    'File.Move(temporaryPath, destinationPath, overwrite);',
    $pendingFlushIndex + 1,
    [StringComparison]::Ordinal)
if ($pendingCreateIndex -lt 0 -or
    $pendingFlushIndex -le $pendingCreateIndex -or
    $pendingMoveIndex -le $pendingFlushIndex) {
    $failures.Add(
        'Pending system configuration must create a protected temporary, flush it, then commit by Move.')
}
foreach ($pendingCommitGuard in @(
        'SystemConfigurationService.ExecuteUnderSystemTransaction(() =>'
        'pending.Initiator == PendingSystemConfigurationInitiator.Installer'
        'pendingStore.CommitApplied(pending.TransactionId, settings);'
    )) {
    if (-not $settingsStoreContent.Contains($pendingCommitGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Pending system configuration commit guard is missing: $pendingCommitGuard")
    }
}

$fatalRecoveryContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Infrastructure\FatalRecovery.cs') `
    -Raw
foreach ($fatalRecoveryGuard in @(
        'Func<bool> serviceIsRunning'
        'if (serviceWasRunning)'
        'startInfo.ArgumentList.Add("--force-start-service")'
        'process.WaitForExit();'
    )) {
    if (-not $fatalRecoveryContent.Contains($fatalRecoveryGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Fatal recovery running-intent guard is missing: $fatalRecoveryGuard")
    }
}
if ($fatalRecoveryContent.Contains('HasArgument(arguments, "--force-start-service")', [StringComparison]::Ordinal)) {
    $failures.Add('Fatal recovery must not preserve the installer-only force-start argument after a manual stop.')
}
if ($fatalRecoveryContent.Contains('process.WaitForExit(30_000);', [StringComparison]::Ordinal)) {
    $failures.Add('Post-setup startup must wait until Setup actually exits instead of using a timeout.')
}
if (-not $supervisorContent.Contains('ClearManualRestartStateLocked();', [StringComparison]::Ordinal) -or
    -not $supervisorContent.Contains('_restartSignal.TryConsume();', [StringComparison]::Ordinal)) {
    $failures.Add('Stopping a supervisor lifecycle must clear queued manual-restart state and its signal.')
}

$clipboardContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\UI\SensitiveClipboard.cs') `
    -Raw
foreach ($clipboardExitGuard in @(
        'DisposeClearTimeout = TimeSpan.FromSeconds(15)'
        'while (!TryClearIfUnchanged() && stopwatch.Elapsed < _disposeClearTimeout)'
        'retryDelayMilliseconds * 2'
    )) {
    if (-not $clipboardContent.Contains($clipboardExitGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Clipboard disposal retry guard is missing: $clipboardExitGuard")
    }
}

$healthProbeContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\Services\HealthProbe.cs') `
    -Raw
$protectedTailscaleIdentityContent = Get-Content `
    -LiteralPath (Join-Path `
        $RepositoryRoot `
        'src\EverVigil\Infrastructure\ProtectedTailscaleIdentityStore.cs') `
    -Raw
$dashboardConnectionContent = Get-Content `
    -LiteralPath (Join-Path $RepositoryRoot 'src\EverVigil\UI\DashboardForm.cs') `
    -Raw
if ($protectedTailscaleIdentityContent.Contains(
        'new[] { productRoot, brokerRoot, stateRoot, ownerRoot }',
        [StringComparison]::Ordinal) -or
    -not $protectedTailscaleIdentityContent.Contains(
        'foreach (var directory in new[] { productRoot, brokerRoot })',
        [StringComparison]::Ordinal) -or
    -not $protectedTailscaleIdentityContent.Contains(
        'EnsureNoReparsePoint(stateRoot);',
        [StringComparison]::Ordinal) -or
    -not $protectedTailscaleIdentityContent.Contains(
        'ValidateProtectedDirectory(new DirectoryInfo(ownerRoot), _ownerSid);',
        [StringComparison]::Ordinal)) {
    $failures.Add(
        'Medium-integrity Tailnet identity validation must traverse State without requiring its unreadable ACL.')
}
if ($appSettingsContent -match '(?m)^\s*public\s+string\s+PublicHost\b') {
    $failures.Add('AppSettings must not persist a user-controlled public host.')
}
foreach ($loopbackHealthGuard in @(
        'private readonly ProtectedTailscaleIdentityStore _tailscaleIdentityStore = new();'
        '_tailscaleIdentityStore.TryLoad(settings, out _)'
        'BuildLoopbackSessionUri(settings)'
        'http://127.0.0.1:{settings.BackendPort}/api/sessions?provider=codex&limit=1'
        'AllowAutoRedirect = false'
        'AuthenticationHeaderValue("Bearer", token)'
        'TryGetProperty("sessions"'
        'TryGetProperty("error"'
    )) {
    if (-not $healthProbeContent.Contains($loopbackHealthGuard, [StringComparison]::Ordinal)) {
        $failures.Add("Loopback-only health guard is missing: $loopbackHealthGuard")
    }
}
foreach ($forbiddenHealthDestination in @(
        'ConnectionUrlBuilder.BuildBaseUrl'
        'ConnectionUrlBuilder.BuildConnectionUrl'
        'settings.PublicHost'
        'endpoint.DnsName'
    )) {
    if ($healthProbeContent.Contains(
            $forbiddenHealthDestination,
            [StringComparison]::Ordinal)) {
        $failures.Add(
            "Health probing must not send credentials to a configurable or Tailnet hostname: $forbiddenHealthDestination")
    }
}
foreach ($dashboardIdentityGuard in @(
        'private readonly ProtectedTailscaleIdentityStore _tailscaleIdentityStore = new();'
        'var endpoint = RefreshTrustedTailnetEndpoint(_settingsStore.Current);'
        'if (endpoint is null)'
        '_tailscaleIdentityStore.TryLoad(settings, out var endpoint)'
        'BuildConnectionUrl(endpoint, _tokenStore.GetOrCreate())'
        'ConnectionUrlBuilder.BuildConnectionUrl('
        'endpoint.DnsName'
        'endpoint.PublicPort'
    )) {
    if (-not $dashboardConnectionContent.Contains(
            $dashboardIdentityGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Dashboard protected Tailnet endpoint guard is missing: $dashboardIdentityGuard")
    }
}
foreach ($dashboardCredentialAction in @(
        [pscustomobject]@{
            Name = 'Reveal'
            Pattern = '(?s)private\s+void\s+ToggleSecrets\(\).*?var\s+endpoint\s*=\s*RefreshTrustedTailnetEndpoint\(_settingsStore\.Current\);.*?if\s*\(endpoint\s+is\s+null\).*?BuildConnectionUrl\(endpoint,\s*_tokenStore\.GetOrCreate\(\)\)'
        }
        [pscustomobject]@{
            Name = 'Copy URL'
            Pattern = '(?s)private\s+void\s+CopyUrl\(\).*?var\s+endpoint\s*=\s*RefreshTrustedTailnetEndpoint\(_settingsStore\.Current\);.*?if\s*\(endpoint\s+is\s+null\).*?BuildConnectionUrl\(endpoint,\s*_tokenStore\.GetOrCreate\(\)\)'
        }
    )) {
    if (-not [regex]::IsMatch(
            $dashboardConnectionContent,
            [string]$dashboardCredentialAction.Pattern)) {
        $failures.Add(
            "Dashboard $($dashboardCredentialAction.Name) must freshly validate the protected Tailnet endpoint before reading the token.")
    }
}
if ($dashboardConnectionContent.Contains('settings.PublicHost', [StringComparison]::Ordinal) -or
    $dashboardConnectionContent.Contains(
        'ConnectionUrlBuilder.BuildBaseUrl(settings.',
        [StringComparison]::Ordinal) -or
    $dashboardConnectionContent.Contains(
        'ConnectionUrlBuilder.BuildConnectionUrl(settings.',
        [StringComparison]::Ordinal)) {
    $failures.Add('Dashboard Reveal/Copy must not derive a credential URL from mutable settings.')
}
foreach ($protectedIdentityGuard in @(
        'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow'
        'ValidateProtectedPath();'
        'FileOptions.SequentialScan'
        'EnsureNoReparsePoint(_ledgerPath);'
        'security.AreAccessRulesProtected'
        '!dnsName.EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase)'
        'bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40'
        'bytes[0] == 0xFD'
        'bytes[1] == 0x7A'
        'bytes[2] == 0x11'
        'bytes[3] == 0x5C'
        'bytes[4] == 0xA1'
        'bytes[5] == 0xE0'
        'NetworkInterface.GetAllNetworkInterfaces()'
        'Dns.GetHostAddressesAsync(endpoint.DnsName)'
        '.WaitAsync(TimeSpan.FromSeconds(3))'
        'return resolved.Length > 0 && resolved.All(address =>'
        'protectedAddresses.Contains(normalized) && local.Contains(normalized)'
        'ValidateLiveIdentity(endpoint);'
        'The medium-integrity UI must not query the'
    )) {
    if (-not $protectedTailscaleIdentityContent.Contains(
            $protectedIdentityGuard,
            [StringComparison]::Ordinal)) {
        $failures.Add("Protected Tailscale identity guard is missing: $protectedIdentityGuard")
    }
}
if ($protectedTailscaleIdentityContent.Contains(
        'ValidateLiveServeRoute(settings);',
        [StringComparison]::Ordinal)) {
    $failures.Add('The medium UI must not query the administrator-only tailscaled pipe.')
}
if ($protectedTailscaleIdentityContent.Contains('Verb = "runas"', [StringComparison]::Ordinal) -or
    $protectedTailscaleIdentityContent.Contains('UseShellExecute = true', [StringComparison]::Ordinal)) {
    $failures.Add('Live Tailscale identity and Serve validation must remain read-only and unelevated.')
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Repository validation failed with $($failures.Count) issue(s)."
}

"Validated $($powerShellFiles.Count) PowerShell files and $($scanFiles.Count) source/config files; repository contract is clean."
