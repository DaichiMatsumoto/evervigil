[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolverPath = Join-Path $repositoryRoot 'scripts\Resolve-InnoCompiler.ps1'
$resourceCompilerScript = Join-Path $repositoryRoot 'scripts\Compile-WindowsResource.ps1'
$installerPath = Join-Path $repositoryRoot 'installer\EverVigil.iss'
$installerContent = Get-Content -LiteralPath $installerPath -Raw
$installWorkerMatch = [regex]::Match(
    $installerContent,
    '(?ms)^function InstallEverVigil: String;\s*(?<body>.*?)^end;')
if (-not $installWorkerMatch.Success) {
    throw 'The production installer worker function could not be inspected.'
}
$installWorkerBody = $installWorkerMatch.Groups['body'].Value
$firstWorkerRunIndex = $installWorkerBody.IndexOf(
    'if not ExecuteInstallWorker(',
    [StringComparison]::Ordinal)
$runtimeFailureIndex = $installWorkerBody.IndexOf(
    'if IsPowerShellInternalRuntimeFailure(ResultCode) then',
    [StringComparison]::Ordinal)
$runtimeRecoveryIndex = $installWorkerBody.IndexOf(
    "if not RunInstallTransaction('Recover', Detail) then",
    $runtimeFailureIndex,
    [StringComparison]::Ordinal)
$runtimeResidueIndex = $installWorkerBody.IndexOf(
    'if HasUnresolvedInstallTransaction then',
    $runtimeRecoveryIndex,
    [StringComparison]::Ordinal)
$secondWorkerRunIndex = $installWorkerBody.IndexOf(
    'if not ExecuteInstallWorker(',
    $runtimeResidueIndex,
    [StringComparison]::Ordinal)
$secondRuntimeFailureIndex = $installWorkerBody.IndexOf(
    'if IsPowerShellInternalRuntimeFailure(ResultCode) then',
    $secondWorkerRunIndex,
    [StringComparison]::Ordinal)
$secondRuntimeRecoveryIndex = $installWorkerBody.IndexOf(
    "if not RunInstallTransaction('Recover', Detail) then",
    $secondRuntimeFailureIndex,
    [StringComparison]::Ordinal)
$secondRuntimeResidueIndex = $installWorkerBody.IndexOf(
    'if HasUnresolvedInstallTransaction then',
    $secondRuntimeRecoveryIndex,
    [StringComparison]::Ordinal)
$finalWorkerResultIndex = $installWorkerBody.IndexOf(
    'if (ResultCode <> 0) or',
    $secondRuntimeResidueIndex,
    [StringComparison]::Ordinal)
if (-not $installerContent.Contains(
        'Result := ResultCode = -2146233082;',
        [StringComparison]::Ordinal) -or
    $firstWorkerRunIndex -lt 0 -or
    $runtimeFailureIndex -le $firstWorkerRunIndex -or
    $runtimeRecoveryIndex -le $runtimeFailureIndex -or
    $runtimeResidueIndex -le $runtimeRecoveryIndex -or
    $secondWorkerRunIndex -le $runtimeResidueIndex -or
    $secondRuntimeFailureIndex -le $secondWorkerRunIndex -or
    $secondRuntimeRecoveryIndex -le $secondRuntimeFailureIndex -or
    $secondRuntimeResidueIndex -le $secondRuntimeRecoveryIndex -or
    $finalWorkerResultIndex -le $secondRuntimeResidueIndex -or
    ([regex]::Matches(
        $installWorkerBody,
        'if not ExecuteInstallWorker\(')).Count -ne 2 -or
    ([regex]::Matches(
        $installWorkerBody,
        'if IsPowerShellInternalRuntimeFailure\(ResultCode\) then')).Count -ne 2 -or
    -not $installWorkerBody.Contains(
        'No further retry will be attempted;',
        [StringComparison]::Ordinal)) {
    throw 'PowerShell 0x80131506 recovery must remain exact, transaction-gated, limited to one retry, and recover after a repeated runtime failure.'
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
    throw 'The Inno source does not install the exact seven-file uninstall-support manifest.'
}
if ([regex]::Matches(
        $installerContent,
        '(?m)^UsePreviousAppDir=no$').Count -ne 2 -or
    $installerContent.Contains(
        'UsePreviousAppDir=yes',
        [StringComparison]::Ordinal) -or
    -not $installerContent.Contains(
        'PreviousInstallRoot := PreviousInstallDirectory;',
        [StringComparison]::Ordinal) -or
    -not $installerContent.Contains(
        "' -PreviousInstallRoot '",
        [StringComparison]::Ordinal)) {
    throw 'The Inno source must keep {app} on the EverVigil path and pass the inherited registration only as PreviousInstallRoot.'
}
$outdatedCandidate = Join-Path `
    $repositoryRoot `
    'src\EverVigil\bin\Release\net8.0-windows\EverVigil.exe'
if (-not (Test-Path -LiteralPath $outdatedCandidate -PathType Leaf)) {
    throw "Build the Release configuration before this test: $outdatedCandidate"
}
$candidateVersionText = (Get-Item -LiteralPath $outdatedCandidate).VersionInfo.ProductVersion
$candidateVersionMatch = [regex]::Match([string]$candidateVersionText, '\d+\.\d+\.\d+')
if (-not $candidateVersionMatch.Success) {
    throw "The fallback fixture has no parseable product version: $candidateVersionText"
}
$candidateVersion = [Version]$candidateVersionMatch.Value
if ($candidateVersion -ge [Version]'6.7.1') {
    throw "The fallback fixture must be older than Inno Setup 6.7.1: $candidateVersion"
}

. $resolverPath
$compiler = Resolve-InnoCompiler -RequestedPath $outdatedCandidate
if ([string]::Equals(
        $compiler.Path,
        [IO.Path]::GetFullPath($outdatedCandidate),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The outdated first candidate was selected as the Inno compiler.'
}
if ($compiler.Version -lt [Version]'6.7.1') {
    throw "An unsupported Inno compiler was selected: $($compiler.Version)"
}

$trustedFallbackRejected = $false
try {
    Resolve-InnoCompiler `
        -RequestedPath $outdatedCandidate `
        -RequireRequestedPath |
        Out-Null
} catch {
    $trustedFallbackRejected = $_.Exception.Message.Contains(
        'fallback is disabled',
        [StringComparison]::Ordinal)
}
if (-not $trustedFallbackRejected) {
    throw 'Trusted release compilation must reject an invalid explicit compiler without fallback.'
}

$resourceOutput = Join-Path `
    $repositoryRoot `
    'src\EverVigil\obj\Release\net8.0-windows\invalid-resource-compiler-test.res'
$relativeResourceCompilerRejected = $false
try {
    & $resourceCompilerScript `
        -ProjectRoot (Join-Path $repositoryRoot 'src\EverVigil') `
        -OutputPath $resourceOutput `
        -CompilerPath 'rc.exe' |
        Out-Null
} catch {
    $relativeResourceCompilerRejected = $_.Exception.Message.Contains(
        'must be absolute',
        [StringComparison]::Ordinal)
}
if (-not $relativeResourceCompilerRejected) {
    throw 'An explicit Windows resource compiler must be an absolute reviewed path.'
}
$missingResourceCompilerRejected = $false
try {
    & $resourceCompilerScript `
        -ProjectRoot (Join-Path $repositoryRoot 'src\EverVigil') `
        -OutputPath $resourceOutput `
        -CompilerPath (Join-Path $repositoryRoot 'missing-resource-compiler.exe') |
        Out-Null
} catch {
    $missingResourceCompilerRejected = $_.Exception.Message.Contains(
        'was not found',
        [StringComparison]::Ordinal)
}
if (-not $missingResourceCompilerRejected) {
    throw 'A missing explicit Windows resource compiler was accepted.'
}

"Inno/compiler toolchain fallback, fixed EverVigil directory migration, and exact uninstall-support manifest passed: skipped $candidateVersion and selected $($compiler.Version)."
