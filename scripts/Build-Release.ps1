[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release'),

    [string]$InnoCompilerPath,

    [string]$PowerShellPath,

    [string]$ResourceCompilerPath,

    [string[]]$DenyValue = @(),

    [ValidateSet('RequireNone', 'Report')]
    [string]$BrokerTestSkipPolicy = 'RequireNone',

    [switch]$RequireTrustedToolchain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Resolve-InnoCompiler.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$dotnetCommand = Get-Command dotnet -ErrorAction Stop
$expectedDotnetPath = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$resolvedPowerShellPath = if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
    $null
} else {
    [IO.Path]::GetFullPath($PowerShellPath)
}
$resolvedResourceCompilerPath = if ([string]::IsNullOrWhiteSpace($ResourceCompilerPath)) {
    $null
} else {
    [IO.Path]::GetFullPath($ResourceCompilerPath)
}
if ($RequireTrustedToolchain) {
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($dotnetCommand.Source),
        [IO.Path]::GetFullPath($expectedDotnetPath),
        [StringComparison]::OrdinalIgnoreCase) -or
        ((& $dotnetCommand.Source --version).Trim() -cne '8.0.130')) {
        throw 'Trusted release compilation requires the reviewed Program Files .NET 8.0.130 SDK.'
    }
    if ($null -eq $resolvedPowerShellPath -or
        -not (Test-Path -LiteralPath $resolvedPowerShellPath -PathType Leaf) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([Environment]::ProcessPath),
            $resolvedPowerShellPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Trusted release compilation must run under the explicitly reviewed PowerShell executable.'
    }
    if ($null -eq $resolvedResourceCompilerPath -or
        -not (Test-Path -LiteralPath $resolvedResourceCompilerPath -PathType Leaf)) {
        throw 'Trusted release compilation requires the explicitly reviewed Windows resource compiler.'
    }
}
$toolchainBuildProperties = [Collections.Generic.List[string]]::new()
foreach ($buildProperty in @(
        '-p:ContinuousIntegrationBuild=true'
        "-p:DirectoryBuildPropsPath=$(Join-Path $repositoryRoot 'Directory.Build.props')"
        '-p:ImportDirectoryBuildTargets=false'
        "-p:RestoreConfigFile=$(Join-Path $repositoryRoot 'NuGet.config')"
        '-p:RestoreSources=https://api.nuget.org/v3/index.json'
        '-p:RestoreFallbackFolders='
        '-p:RestoreAdditionalProjectSources='
        '-p:RestoreAdditionalProjectFallbackFolders='
        '-p:RestorePackagesWithLockFile=true'
        '-p:RestoreLockedMode=true'
        '-p:ImportUserLocationsByWildcardBeforeMicrosoftCommonProps=false'
        '-p:ImportUserLocationsByWildcardAfterMicrosoftCommonProps=false'
        '-p:ImportUserLocationsByWildcardBeforeMicrosoftCommonTargets=false'
        '-p:ImportUserLocationsByWildcardAfterMicrosoftCommonTargets=false'
        '-p:ImportUserLocationsByWildcardBeforeMicrosoftCSharpTargets=false'
        '-p:ImportUserLocationsByWildcardAfterMicrosoftCSharpTargets=false'
    )) {
    $toolchainBuildProperties.Add($buildProperty)
}
if (-not [string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) {
    $toolchainBuildProperties.Add("-p:RestorePackagesPath=$env:NUGET_PACKAGES")
}
if ($null -ne $resolvedPowerShellPath) {
    $toolchainBuildProperties.Add("-p:EverVigilPowerShellPath=$resolvedPowerShellPath")
}
if ($null -ne $resolvedResourceCompilerPath) {
    $toolchainBuildProperties.Add(
        "-p:EverVigilResourceCompilerPath=$resolvedResourceCompilerPath")
}

function New-InstallerWizardImage {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.Drawing
    $source = $null
    $canvas = $null
    $graphics = $null
    try {
        $source = [Drawing.Image]::FromFile($SourcePath)
        $canvas = [Drawing.Bitmap]::new(328, 628)
        $graphics = [Drawing.Graphics]::FromImage($canvas)
        $graphics.Clear([Drawing.Color]::White)
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.DrawImage($source, [Drawing.Rectangle]::new(14, 164, 300, 300))
        $canvas.Save($DestinationPath, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($graphics) {
            $graphics.Dispose()
        }
        if ($canvas) {
            $canvas.Dispose()
        }
        if ($source) {
            $source.Dispose()
        }
    }
}

function Test-PublishedLocalization {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $startInfo = [Diagnostics.ProcessStartInfo]::new($ExecutablePath)
    $startInfo.ArgumentList.Add('--verify-localization')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The localization smoke-test process did not start.'
        }
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'The localization smoke test timed out.'
        }
        if ($process.ExitCode -ne 0) {
            throw "The published executable failed localization verification with exit code $($process.ExitCode)."
        }
    } finally {
        $process.Dispose()
    }
}

function Test-NativeBrokerPreMainIsolation {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ProbeRoot
    )

    if (Test-Path -LiteralPath $ProbeRoot) {
        Remove-Item -LiteralPath $ProbeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ProbeRoot | Out-Null
    $probeExecutable = Join-Path $ProbeRoot 'EverVigil.Broker.exe'
    Copy-Item -LiteralPath $ExecutablePath -Destination $probeExecutable
    foreach ($nativeLibraryName in @(
            'advapi32.dll'
            'crypt32.dll'
            'kernel32.dll'
            'ntdll.dll'
            'ole32.dll'
            'oleaut32.dll'
            'shell32.dll'
            'wintrust.dll'
        )) {
        [IO.File]::WriteAllText(
            (Join-Path $ProbeRoot $nativeLibraryName),
            'EverVigil local DLL load canary - must never be loaded.',
            [Text.UTF8Encoding]::new($false))
    }
    $missingHook = Join-Path $ProbeRoot 'must-not-load-startup-hook.dll'
    $missingProfiler = Join-Path $ProbeRoot 'must-not-load-profiler.dll'
    $hostTrace = Join-Path $ProbeRoot 'managed-host-trace.txt'
    $bundleExtractRoot = Join-Path $ProbeRoot 'managed-bundle-extract'
    $startInfo = [Diagnostics.ProcessStartInfo]::new($probeExecutable)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $ProbeRoot
    foreach ($entry in ([ordered]@{
            DOTNET_STARTUP_HOOKS = $missingHook
            DOTNET_ADDITIONAL_DEPS = $missingHook
            DOTNET_SHARED_STORE = $ProbeRoot
            DOTNET_BUNDLE_EXTRACT_BASE_DIR = $bundleExtractRoot
            COREHOST_TRACE = '1'
            COREHOST_TRACEFILE = $hostTrace
            CORECLR_ENABLE_PROFILING = '1'
            CORECLR_PROFILER = '{11111111-1111-1111-1111-111111111111}'
            CORECLR_PROFILER_PATH = $missingProfiler
            COMPlus_ReadyToRun = '0'
        }).GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = $entry.Value
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Native broker pre-Main isolation probe did not start.'
        }
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Native broker pre-Main isolation probe timed out.'
        }
        # Missing launch arguments deterministically return authentication code
        # 3, proving that the native entry point ran despite every CLR poison.
        if ($process.ExitCode -ne 3) {
            throw "Native broker did not reach its entry point under poisoned managed-runtime and local-DLL environment; exit=$($process.ExitCode)."
        }
        if ((Test-Path -LiteralPath $hostTrace) -or
            (Test-Path -LiteralPath $bundleExtractRoot)) {
            throw 'Native broker started a managed host or extracted a managed bundle before Main.'
        }
    } finally {
        $process.Dispose()
        if (Test-Path -LiteralPath $ProbeRoot) {
            Remove-Item -LiteralPath $ProbeRoot -Recurse -Force
        }
    }
}

function Test-NativePortableExecutable {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $stream = [IO.File]::Open(
        $ExecutablePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $reader = $null
    try {
        $reader = [Reflection.PortableExecutable.PEReader]::new($stream)
        if ($null -eq $reader.PEHeaders.PEHeader) {
            throw 'Privileged broker output is not a valid PE image.'
        }
        if ($null -ne $reader.PEHeaders.CorHeader) {
            throw 'Privileged broker output still contains a managed CLR header.'
        }
        if ($reader.PEHeaders.PEHeader.Magic -ne
            [Reflection.PortableExecutable.PEMagic]::PE32Plus) {
            throw 'Privileged broker output is not a reviewed x64 PE32+ image.'
        }
        $loadConfig = $reader.PEHeaders.PEHeader.LoadConfigTableDirectory
        if ($loadConfig.RelativeVirtualAddress -eq 0 -or $loadConfig.Size -lt 80) {
            throw 'Privileged broker PE has no complete x64 load-configuration directory.'
        }
        $loadConfigSections = @($reader.PEHeaders.SectionHeaders | Where-Object {
                $loadConfig.RelativeVirtualAddress -ge $_.VirtualAddress -and
                $loadConfig.RelativeVirtualAddress -lt
                    ($_.VirtualAddress + [Math]::Max($_.VirtualSize, $_.SizeOfRawData))
            })
        if ($loadConfigSections.Count -ne 1) {
            throw 'Privileged broker load-configuration RVA is ambiguous or unmapped.'
        }
        $loadConfigSection = $loadConfigSections[0]
        $loadConfigOffsetInSection =
            $loadConfig.RelativeVirtualAddress - $loadConfigSection.VirtualAddress
        if ($loadConfigOffsetInSection -lt 0 -or
            $loadConfigOffsetInSection + 80 -gt $loadConfigSection.SizeOfRawData) {
            throw 'Privileged broker load-configuration directory escapes raw PE data.'
        }
        $stream.Position =
            $loadConfigSection.PointerToRawData + $loadConfigOffsetInSection
        $loadConfigBytes = [byte[]]::new(80)
        if ($stream.Read($loadConfigBytes, 0, $loadConfigBytes.Length) -ne
            $loadConfigBytes.Length -or
            [BitConverter]::ToUInt32($loadConfigBytes, 0) -lt 80) {
            throw 'Privileged broker x64 load-configuration directory is truncated.'
        }
        # IMAGE_LOAD_CONFIG_DIRECTORY64.DependentLoadFlags is the WORD at
        # offset 78. LOAD_LIBRARY_SEARCH_SYSTEM32 (0x800) must survive link.
        $dependentLoadFlags = [BitConverter]::ToUInt16($loadConfigBytes, 78)
        if (($dependentLoadFlags -band 0x0800) -ne 0x0800) {
            throw 'Privileged broker PE does not enforce System32 dependency loading.'
        }
    } finally {
        if ($reader) {
            $reader.Dispose()
        }
        $stream.Dispose()
    }
}

function Assert-NativeAotRestoreGraph {
    param(
        [Parameter(Mandatory)][string]$ProjectAssetsPath,
        [Parameter(Mandatory)][string[]]$AotLockFilePath
    )

    foreach ($lockFilePath in $AotLockFilePath) {
        if (-not (Test-Path -LiteralPath $lockFilePath -PathType Leaf)) {
            throw "The reviewed NativeAOT lock file is missing: $lockFilePath"
        }
    }
    if (-not (Test-Path -LiteralPath $ProjectAssetsPath -PathType Leaf)) {
        throw "NativeAOT restore graph is missing: $ProjectAssetsPath"
    }
    $assetsContent = Get-Content -LiteralPath $ProjectAssetsPath -Raw
    $compilerVersion = '8.0.30'
    $requiredPackages = @(
        'Microsoft.DotNet.ILCompiler'
        'runtime.win-x64.Microsoft.DotNet.ILCompiler'
    )
    $lockedPackages = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($lockFilePath in $AotLockFilePath) {
        $document = $null
        try {
            $lockJson = [IO.File]::ReadAllText(
                $lockFilePath,
                [Text.UTF8Encoding]::new($false, $true))
            $document = [Text.Json.JsonDocument]::Parse(
                [string]$lockJson)
            $rootProperties = @($document.RootElement.EnumerateObject())
            $versionProperties = @($rootProperties | Where-Object Name -CEQ 'version')
            $dependencyProperties = @($rootProperties | Where-Object Name -CEQ 'dependencies')
            if ($versionProperties.Count -ne 1 -or
                $versionProperties[0].Value.GetInt32() -ne 1 -or
                $dependencyProperties.Count -ne 1 -or
                $dependencyProperties[0].Value.ValueKind -ne
                    [Text.Json.JsonValueKind]::Object) {
                throw "Invalid NativeAOT lock schema: $lockFilePath"
            }
            $runtimeTargets = @(
                $dependencyProperties[0].Value.EnumerateObject() |
                    Where-Object {
                        $_.Name.EndsWith('/win-x64', [StringComparison]::Ordinal)
                    })
            if ($runtimeTargets.Count -ne 1 -or
                $runtimeTargets[0].Value.ValueKind -ne
                    [Text.Json.JsonValueKind]::Object) {
                throw "NativeAOT lock must contain one exact win-x64 target: $lockFilePath"
            }
            foreach ($requiredPackage in $requiredPackages) {
                $packageProperties = @(
                    $runtimeTargets[0].Value.EnumerateObject() |
                        Where-Object Name -CEQ $requiredPackage)
                if ($packageProperties.Count -eq 0) {
                    continue
                }
                if ($packageProperties.Count -ne 1 -or
                    $packageProperties[0].Value.ValueKind -ne
                        [Text.Json.JsonValueKind]::Object) {
                    throw "Duplicate or invalid NativeAOT lock entry: $requiredPackage"
                }
                $packageFields = @($packageProperties[0].Value.EnumerateObject())
                $resolvedFields = @($packageFields | Where-Object Name -CEQ 'resolved')
                $hashFields = @($packageFields | Where-Object Name -CEQ 'contentHash')
                if ($resolvedFields.Count -ne 1 -or
                    $resolvedFields[0].Value.GetString() -cne $compilerVersion -or
                    $hashFields.Count -ne 1 -or
                    [string]::IsNullOrWhiteSpace($hashFields[0].Value.GetString())) {
                    throw "Unreviewed NativeAOT lock evidence: $requiredPackage"
                }
                [void]$lockedPackages.Add($requiredPackage)
            }
        } finally {
            if ($document) {
                $document.Dispose()
            }
        }
    }
    foreach ($requiredPackage in $requiredPackages) {
        if (-not $lockedPackages.Contains($requiredPackage) -or
            -not $assetsContent.Contains(
                "$requiredPackage/$compilerVersion",
                [StringComparison]::Ordinal)) {
            throw (
                'The reviewed win-x64 NativeAOT lock/restore graph is incomplete; ' +
                "missing $requiredPackage")
        }
    }
}

function Test-InstallerAuditExtraction {
    param(
        [Parameter(Mandatory)][string]$ExpectedRoot,
        [Parameter(Mandatory)][string]$ActualRoot
    )

    if (-not (Test-Path -LiteralPath $ActualRoot -PathType Container)) {
        return $false
    }
    $expectedFiles = @(Get-ChildItem -LiteralPath $ExpectedRoot -File -Recurse -Force)
    $actualFiles = @(Get-ChildItem -LiteralPath $ActualRoot -File -Recurse -Force)
    if ($expectedFiles.Count -eq 0 -or $actualFiles.Count -ne $expectedFiles.Count) {
        return $false
    }

    foreach ($expectedFile in $expectedFiles) {
        $relativePath = [IO.Path]::GetRelativePath($ExpectedRoot, $expectedFile.FullName)
        $actualPath = Join-Path $ActualRoot $relativePath
        if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf)) {
            return $false
        }
        $actualFile = Get-Item -LiteralPath $actualPath -Force -ErrorAction Stop
        if ($actualFile.Length -ne $expectedFile.Length) {
            return $false
        }
        $expectedHash = (Get-FileHash `
                -LiteralPath $expectedFile.FullName `
                -Algorithm SHA256).Hash
        $actualHash = (Get-FileHash `
                -LiteralPath $actualFile.FullName `
                -Algorithm SHA256).Hash
        if (-not [string]::Equals(
                $actualHash,
                $expectedHash,
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Invoke-InstallerAuditExtraction {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$ExpectedRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $attemptErrors = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (Test-Path -LiteralPath $DestinationRoot) {
                Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
            }
            $auditProcess = Start-Process `
                -FilePath $InstallerPath `
                -ArgumentList @(
                    '/VERYSILENT'
                    '/SUPPRESSMSGBOXES'
                    '/NORESTART'
                    ("/AUDITEXTRACT=`"{0}`"" -f $DestinationRoot)
                ) `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            $layoutMatches = Test-InstallerAuditExtraction `
                -ExpectedRoot $ExpectedRoot `
                -ActualRoot $DestinationRoot
            if ($auditProcess.ExitCode -eq 1 -and $layoutMatches) {
                return
            }
            $attemptErrors.Add(
                "attempt ${attempt}: exit=$($auditProcess.ExitCode), exactPayload=$layoutMatches")
        } catch {
            $attemptErrors.Add("attempt ${attempt}: $($_.Exception.Message)")
        }
        if ($attempt -lt 3) {
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    throw "Compiled installer audit extraction failed after 3 attempts: $($attemptErrors -join ' | ')"
}

function Remove-ReleaseWorkingTreesWithRetry {
    param([Parameter(Mandatory)][string[]]$Path)

    $attemptErrors = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            foreach ($target in $Path) {
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                }
            }
            $remaining = @($Path | Where-Object { Test-Path -LiteralPath $_ })
            if ($remaining.Count -eq 0) {
                return
            }
            throw "Working trees remain after cleanup: $($remaining.Count)"
        } catch {
            $attemptErrors.Add("attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (500 * $attempt)
            }
        }
    }
    throw "Release working-tree cleanup failed after 3 attempts: $($attemptErrors -join ' | ')"
}

$versionValidatorPath = Join-Path $PSScriptRoot 'Test-ReleaseVersion.ps1'
$validatedVersion = & $versionValidatorPath -Version $Version
if (-not [string]::Equals($validatedVersion, $Version, [StringComparison]::Ordinal)) {
    throw "Release version validation changed '$Version' unexpectedly."
}
$projectPath = Join-Path $repositoryRoot 'src\EverVigil\EverVigil.csproj'
$brokerProjectPath = Join-Path `
    $repositoryRoot `
    'src\EverVigil.Broker\EverVigil.Broker.csproj'
$brokerProjectAssetsPath = Join-Path `
    $repositoryRoot `
    'src\EverVigil.Broker\obj\project.assets.json'
$brokerAotLockPath = Join-Path `
    $repositoryRoot `
    'src\EverVigil.Broker\packages.aot.lock.json'
$brokerProtocolAotLockPath = Join-Path `
    $repositoryRoot `
    'src\EverVigil.Broker.Protocol\packages.aot.lock.json'
$brokerTestProjectPath = Join-Path `
    $repositoryRoot `
    'tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj'
$brandSourcePath = Join-Path $repositoryRoot 'src\EverVigil\Assets\evervigil-placeholder-source.png'
$installerScriptPath = Join-Path $repositoryRoot 'installer\EverVigil.iss'
$scannerPath = Join-Path $PSScriptRoot 'Test-PublicRelease.ps1'
$project = [xml](Get-Content -LiteralPath $projectPath -Raw)
$declaredVersion = [string]$project.Project.PropertyGroup.Version
if (-not [string]::Equals($declaredVersion, $Version, [StringComparison]::Ordinal)) {
    throw "Requested version '$Version' does not match project version '$declaredVersion'."
}
$brokerProject = [xml](Get-Content -LiteralPath $brokerProjectPath -Raw)
$declaredBrokerVersion = [string]$brokerProject.Project.PropertyGroup.Version
if (-not [string]::Equals(
        $declaredBrokerVersion,
        $Version,
        [StringComparison]::Ordinal)) {
    throw "Requested version '$Version' does not match broker version '$declaredBrokerVersion'."
}
Assert-NativeAotRestoreGraph `
    -ProjectAssetsPath $brokerProjectAssetsPath `
    -AotLockFilePath @($brokerAotLockPath, $brokerProtocolAotLockPath)
$brokerTestBuildArguments = @(
    'build'
    $brokerTestProjectPath
    '-c'
    'Release'
    '--no-restore'
    '-m:1'
    '-p:PublishAot=false'
)
$brokerTestBuildArguments += @($toolchainBuildProperties)
& $dotnetCommand.Source @brokerTestBuildArguments
if ($LASTEXITCODE -ne 0) {
    throw "Privileged broker release-gate build failed with exit code $LASTEXITCODE."
}
$brokerTestArguments = @(
    'run'
    '--project'
    $brokerTestProjectPath
    '-c'
    'Release'
    '--no-build'
)
if ($BrokerTestSkipPolicy -eq 'RequireNone') {
    $brokerTestArguments += @('--', '--fail-on-skip')
}
& $dotnetCommand.Source @brokerTestArguments
if ($LASTEXITCODE -ne 0) {
    throw "Privileged broker release-gate tests failed with exit code $LASTEXITCODE."
}
$allowedOutputParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts')).TrimEnd('\')
$resolvedOutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
if (-not $resolvedOutputRoot.StartsWith(
        "$allowedOutputParent\",
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputRoot must be inside '$allowedOutputParent'."
}

$publishRoot = Join-Path $resolvedOutputRoot 'publish'
$brokerPublishRoot = Join-Path $resolvedOutputRoot 'broker-publish'
$auditPublishRoot = Join-Path $resolvedOutputRoot 'audit-publish'
$auditExtractRoot = Join-Path $resolvedOutputRoot 'audit-extracted-setup'
$localizationSmokeRoot = Join-Path $resolvedOutputRoot 'localization-smoke'
$brokerEnvironmentProbeRoot = Join-Path $resolvedOutputRoot 'broker-environment-probe'
$packageRoot = Join-Path $resolvedOutputRoot 'installer-package'
$installerPath = Join-Path $resolvedOutputRoot "EverVigil-$Version-Setup.exe"
$auditInstallerPath = Join-Path $resolvedOutputRoot "EverVigil-$Version-ResourceAudit.exe"
$resourceAuditInstallRoot = Join-Path $resolvedOutputRoot 'resource-audit-install'
$resourceAuditReportPath = Join-Path $resolvedOutputRoot 'resource-audit-report.json'
$installerNoticePreviewPath = Join-Path $resolvedOutputRoot 'installer-notice-preview.txt'
$checksumPath = Join-Path $resolvedOutputRoot 'SHA256SUMS.txt'
$wizardBrandImage = Join-Path $publishRoot 'evervigil-placeholder-wizard.png'
$versionInfoVersion = "$($Version.Split('-')[0]).0"
$brandDenySha256 = @(
    ('520F30AD208EE7F88F10E2CBC08A0169' + 'D2B3C0BBF8D57C34A6E9207E4FD8DAA6')
    ('5450B5B0300267199207DE95CE795A3' + '52C174BBB37661471C96D24D6FA7007D8')
)

if (Test-Path -LiteralPath $resolvedOutputRoot) {
    Remove-ReleaseWorkingTreesWithRetry `
        -Path $resolvedOutputRoot
}
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
New-Item -ItemType Directory -Path $auditPublishRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot 'payload') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot 'broker') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot 'scripts') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot 'licenses') -Force | Out-Null

& $dotnetCommand.Source publish `
    $projectPath `
    --no-restore `
    -c Release `
    -r win-x64 `
    -m:1 `
    -nr:false `
    --self-contained true `
    -p:PublishSingleFile=false `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:UseSharedCompilation=false `
    -p:Version=$Version `
    @toolchainBuildProperties `
    -o $auditPublishRoot
if ($LASTEXITCODE -ne 0) {
    throw "Uncompressed audit publish failed with exit code $LASTEXITCODE."
}
& $scannerPath `
    -PublishRoot $auditPublishRoot `
    -DenyValue $DenyValue `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Uncompressed publish contamination scan failed.'
}

& $dotnetCommand.Source publish `
    $projectPath `
    --no-restore `
    -c Release `
    -r win-x64 `
    -m:1 `
    -nr:false `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:UseSharedCompilation=false `
    -p:Version=$Version `
    @toolchainBuildProperties `
    -o $publishRoot
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

& $dotnetCommand.Source publish `
    $brokerProjectPath `
    --no-restore `
    -c Release `
    -r win-x64 `
    -m:1 `
    -nr:false `
    --self-contained true `
    -p:PublishAot=true `
    -p:StripSymbols=true `
    -p:IlcOptimizationPreference=Speed `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:UseSharedCompilation=false `
    -p:Version=$Version `
    @toolchainBuildProperties `
    -o $brokerPublishRoot
if ($LASTEXITCODE -ne 0) {
    throw "Privileged broker publish failed with exit code $LASTEXITCODE."
}
$publishedBrokerFiles = @(Get-ChildItem `
        -LiteralPath $brokerPublishRoot `
        -File `
        -Force `
        -ErrorAction Stop)
$publishedBroker = Join-Path $brokerPublishRoot 'EverVigil.Broker.exe'
if ($publishedBrokerFiles.Count -ne 1 -or
    -not (Test-Path -LiteralPath $publishedBroker -PathType Leaf)) {
    throw "Privileged broker publish must contain only EverVigil.Broker.exe; found $($publishedBrokerFiles.Count) files."
}
Test-NativePortableExecutable -ExecutablePath $publishedBroker
Test-NativeBrokerPreMainIsolation `
    -ExecutablePath $publishedBroker `
    -ProbeRoot $brokerEnvironmentProbeRoot
& $scannerPath `
    -PublishRoot $brokerPublishRoot `
    -DenyValue $DenyValue `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Privileged broker publish contamination scan failed.'
}

$publishedExecutable = Join-Path $publishRoot 'EverVigil.exe'
if (-not (Test-Path -LiteralPath $publishedExecutable -PathType Leaf)) {
    throw "Published executable not found: $publishedExecutable"
}
New-Item -ItemType Directory -Path $localizationSmokeRoot | Out-Null
$isolatedExecutable = Join-Path $localizationSmokeRoot 'EverVigil.exe'
Copy-Item -LiteralPath $publishedExecutable -Destination $isolatedExecutable
$isolatedFiles = @(Get-ChildItem -LiteralPath $localizationSmokeRoot -File -Recurse -Force)
if ($isolatedFiles.Count -ne 1) {
    throw "Localization smoke-test directory must contain exactly one file; found $($isolatedFiles.Count)."
}
Test-PublishedLocalization -ExecutablePath $isolatedExecutable
New-InstallerWizardImage -SourcePath $brandSourcePath -DestinationPath $wizardBrandImage
Copy-Item -LiteralPath $publishedExecutable -Destination (Join-Path $packageRoot 'payload')
Copy-Item -LiteralPath $publishedBroker -Destination (Join-Path $packageRoot 'broker')

foreach ($relativePath in @(
        'Install.ps1'
        'Uninstall.ps1'
        'README.md'
        'SECURITY.md'
        'LICENSE'
        'NOTICE.md'
        'THIRD-PARTY-NOTICES.md'
        'RELEASE_NOTES.md'
    )) {
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot $relativePath) `
        -Destination $packageRoot
}
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot 'docs') `
    -Destination $packageRoot `
    -Recurse
foreach ($supportScript in @(
        'scripts\Complete-InstallTransaction.ps1'
        'scripts\Export-InstallerPayload.ps1'
        'scripts\InstallTransactionData.ps1'
        'scripts\Invoke-InteractiveUserTask.ps1'
        'scripts\Invoke-SystemMaintenance.ps1'
        'scripts\LegacyCompatibility.generated.ps1'
        'scripts\Resolve-SafeInstallRoot.ps1'
    )) {
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot $supportScript) `
        -Destination (Join-Path $packageRoot 'scripts')
}

$dotnetRoot = Split-Path $dotnetCommand.Source -Parent
$thirdPartyLicenses = [ordered]@{
    (Join-Path $dotnetRoot 'LICENSE.txt') = 'DOTNET-LICENSE.txt'
    (Join-Path $dotnetRoot 'ThirdPartyNotices.txt') = 'DOTNET-THIRD-PARTY-NOTICES.txt'
    (Join-Path $repositoryRoot 'licenses\INNO-SETUP-LICENSE.txt') = 'INNO-SETUP-LICENSE.txt'
    (Join-Path $repositoryRoot 'licenses\QRCODER-LICENSE.txt') = 'QRCODER-LICENSE.txt'
}
foreach ($license in $thirdPartyLicenses.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $license.Key -PathType Leaf)) {
        throw "Required third-party license was not found: $($license.Key)"
    }
    Copy-Item `
        -LiteralPath $license.Key `
        -Destination (Join-Path (Join-Path $packageRoot 'licenses') $license.Value)
}

& $scannerPath `
    -RepositoryRoot $repositoryRoot `
    -PackageRoot $packageRoot `
    -DenyValue $DenyValue `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Public release contamination scan failed.'
}

$compiler = Resolve-InnoCompiler `
    -RequestedPath $InnoCompilerPath `
    -RequireRequestedPath:$RequireTrustedToolchain
$compilerArguments = @(
    "/DMyAppVersion=$Version"
    "/DMyVersionInfoVersion=$versionInfoVersion"
    "/DPackageRoot=$packageRoot"
    "/DRepositoryRoot=$repositoryRoot"
    "/DInstallerOutputRoot=$resolvedOutputRoot"
    "/DWizardBrandImage=$wizardBrandImage"
    $installerScriptPath
)
& $compiler.Path @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Compiled installer not found: $installerPath"
}

$auditCompilerArguments = @(
    "/DMyAppVersion=$Version"
    "/DMyVersionInfoVersion=$versionInfoVersion"
    "/DPackageRoot=$packageRoot"
    "/DRepositoryRoot=$repositoryRoot"
    "/DInstallerOutputRoot=$resolvedOutputRoot"
    "/DWizardBrandImage=$wizardBrandImage"
    '/DResourceAuditBuild=1'
    '/DResourceAuditAppId=A17D6AC4-2F11-45CF-A0BE-42C2F607F7B8'
    $installerScriptPath
)
& $compiler.Path @auditCompilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup resource-audit compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $auditInstallerPath -PathType Leaf)) {
    throw "Compiled resource-audit installer not found: $auditInstallerPath"
}

Invoke-InstallerAuditExtraction `
    -InstallerPath $installerPath `
    -ExpectedRoot $packageRoot `
    -DestinationRoot $auditExtractRoot
& $scannerPath `
    -PackageRoot $auditExtractRoot `
    -DenyValue $DenyValue `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Extracted installer contamination scan failed.'
}

& $scannerPath `
    -BinaryPath $installerPath `
    -DenyValue $DenyValue `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Compiled installer contamination scan failed.'
}

& (Join-Path $PSScriptRoot 'Invoke-ReleaseResourceAudit.ps1') `
    -ApplicationPath $publishedExecutable `
    -BrokerExecutablePath $publishedBroker `
    -InstallerPath $installerPath `
    -AuditInstallerPath $auditInstallerPath `
    -AuditRoot $resourceAuditInstallRoot `
    -ReportPath $resourceAuditReportPath `
    -InstallerScriptPath $installerScriptPath `
    -NoticePreviewPath $installerNoticePreviewPath `
    -ExpectedIconPath (Join-Path $repositoryRoot 'src\EverVigil\Assets\evervigil-placeholder.ico') `
    -Version $Version `
    -DenySha256 $brandDenySha256
if ($LASTEXITCODE -ne 0) {
    throw 'Compiled executable resource audit failed.'
}

$checksum = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    $checksumPath,
    "$checksum  $([IO.Path]::GetFileName($installerPath))`n",
    [Text.UTF8Encoding]::new($false))

Remove-ReleaseWorkingTreesWithRetry `
    -Path @(
        $publishRoot,
        $brokerPublishRoot,
        $auditPublishRoot,
        $auditExtractRoot,
        $localizationSmokeRoot,
        $brokerEnvironmentProbeRoot,
        $packageRoot,
        $auditInstallerPath,
        $resourceAuditInstallRoot)
"Installer: $installerPath"
"SHA-256: $checksum"
"Resource audit: $resourceAuditReportPath"
"Installer notice preview: $installerNoticePreviewPath"
"Inno Setup: $($compiler.Version)"
