[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ResourceScriptName = 'EverVigil.rc',
    [string]$IconRelativePath = 'Assets\evervigil-placeholder.ico',
    [string]$CompilerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
$allowedOutputRoot = [IO.Path]::GetFullPath(
    (Join-Path $resolvedProjectRoot 'obj')).TrimEnd('\')
if (-not $resolvedOutputPath.StartsWith(
        "$allowedOutputRoot\",
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Win32 resource output must be inside '$allowedOutputRoot'."
}
$resourceScriptPath = Join-Path $resolvedProjectRoot $ResourceScriptName
foreach ($requiredInput in @(
        $resourceScriptPath,
        (Join-Path $resolvedProjectRoot 'app.manifest'),
        (Join-Path $resolvedProjectRoot $IconRelativePath)
    )) {
    if (-not (Test-Path -LiteralPath $requiredInput -PathType Leaf)) {
        throw "Win32 resource input was not found: $requiredInput"
    }
}

$resolvedCompilerPath = $null
if (-not [string]::IsNullOrWhiteSpace($CompilerPath)) {
    if (-not [IO.Path]::IsPathFullyQualified($CompilerPath)) {
        throw 'An explicitly selected Windows resource compiler path must be absolute.'
    }
    $resolvedCompilerPath = [IO.Path]::GetFullPath($CompilerPath)
    if (-not (Test-Path -LiteralPath $resolvedCompilerPath -PathType Leaf)) {
        throw "The explicitly selected Windows resource compiler was not found: $resolvedCompilerPath"
    }
} else {
    $candidates = [Collections.Generic.List[string]]::new()
    $sdkRoots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:WindowsSdkDir)) {
        $sdkRoots.Add([IO.Path]::GetFullPath($env:WindowsSdkDir))
    }
    $programFilesX86 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFilesX86)
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $sdkRoots.Add((Join-Path $programFilesX86 'Windows Kits\10'))
    }
    foreach ($sdkRoot in @($sdkRoots | Sort-Object -Unique)) {
        $binRoot = Join-Path $sdkRoot 'bin'
        if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
            continue
        }
        $versionDirectories = @(Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction Stop |
                Where-Object { $_.Name -match '\A\d+\.\d+\.\d+\.\d+\z' } |
                Sort-Object { [Version]$_.Name } -Descending)
        foreach ($versionDirectory in $versionDirectories) {
            foreach ($architecture in @('x64', 'x86')) {
                $candidates.Add((Join-Path $versionDirectory.FullName "$architecture\rc.exe"))
            }
        }
    }
    $command = Get-Command rc.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        $candidates.Add($command.Source)
    }
    $resolvedCandidates = @($candidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } |
            Select-Object -Unique |
            Select-Object -First 1)
    if ($resolvedCandidates.Count -ne 1) {
        throw 'Windows SDK rc.exe was not found. Install the Windows 10/11 SDK before building EverVigil.'
    }
    $resolvedCompilerPath = $resolvedCandidates[0]
}
$compilerVersionInfo = (Get-Item -LiteralPath $resolvedCompilerPath -Force -ErrorAction Stop).VersionInfo
$compilerSignature = Get-AuthenticodeSignature -LiteralPath $resolvedCompilerPath -ErrorAction Stop
if (-not [string]::Equals(
        ([string]$compilerVersionInfo.CompanyName).Trim(),
        'Microsoft Corporation',
        [StringComparison]::Ordinal) -or
    -not [string]::Equals(
        ([string]$compilerVersionInfo.OriginalFilename).Trim(),
        'rc.exe',
        [StringComparison]::OrdinalIgnoreCase) -or
    $compilerSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    -not $compilerSignature.SignerCertificate.Subject.StartsWith(
        'CN=Microsoft Corporation,',
        [StringComparison]::Ordinal)) {
    throw "Windows resource compiler identity validation failed: $resolvedCompilerPath"
}

$outputParent = Split-Path -Parent $resolvedOutputPath
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
$startInfo = [Diagnostics.ProcessStartInfo]::new($resolvedCompilerPath)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.WorkingDirectory = $resolvedProjectRoot
foreach ($argument in @('/nologo', '/fo', $resolvedOutputPath, $resourceScriptPath)) {
    $startInfo.ArgumentList.Add($argument)
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) {
        throw "Windows resource compiler did not start: $resolvedCompilerPath"
    }
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Windows resource compilation timed out after 30 seconds.'
    }
    $output = $standardOutput.GetAwaiter().GetResult().Trim()
    $errorOutput = $standardError.GetAwaiter().GetResult().Trim()
    if ($process.ExitCode -ne 0) {
        throw "Windows resource compilation failed with exit code $($process.ExitCode): $output $errorOutput"
    }
    if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
        throw "Windows resource compiler did not create: $resolvedOutputPath"
    }
} finally {
    $process.Dispose()
}

"Win32 resource: $resolvedOutputPath"
