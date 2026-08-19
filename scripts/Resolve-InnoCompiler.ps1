Set-StrictMode -Version Latest

function Resolve-InnoCompiler {
    [CmdletBinding()]
    param(
        [string]$RequestedPath,
        [switch]$RequireRequestedPath
    )

    $candidates = [Collections.Generic.List[string]]::new()
    $rejectedCandidates = [Collections.Generic.List[string]]::new()
    if ($RequireRequestedPath -and [string]::IsNullOrWhiteSpace($RequestedPath)) {
        throw 'Trusted release compilation requires one explicit Inno compiler path.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }
    if (-not $RequireRequestedPath) {
        foreach ($candidate in @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
                (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
                (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
                (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
                (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
            )) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $candidates.Add($candidate)
            }
        }
        $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            $candidates.Add($command.Source)
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $resolvedPath = [IO.Path]::GetFullPath($candidate)
        $compilerDirectory = Split-Path -Parent $resolvedPath
        $versionSources = @(
            (Get-Item -LiteralPath $resolvedPath).VersionInfo.ProductVersion
            Get-ChildItem -LiteralPath $compilerDirectory -Filter 'unins*.exe' -File |
                ForEach-Object { $_.VersionInfo.ProductVersion }
        )
        $versionMatch = $versionSources | ForEach-Object {
            [regex]::Match([string]$_, '\d+\.\d+\.\d+')
        } | Where-Object { $_.Success -and $_.Value -ne '0.0.0' } | Select-Object -First 1
        if (-not $versionMatch -or -not $versionMatch.Success) {
            $rejectedCandidates.Add("$resolvedPath (version unknown)")
            continue
        }
        $compilerVersion = [Version]$versionMatch.Value
        if ($compilerVersion -lt [Version]'6.7.1') {
            $rejectedCandidates.Add("$resolvedPath ($compilerVersion)")
            continue
        }
        return [pscustomobject]@{
            Path = $resolvedPath
            Version = $compilerVersion
        }
    }

    $rejectedDetail = if ($rejectedCandidates.Count -gt 0) {
        " Rejected candidates: $($rejectedCandidates -join '; ')."
    } else {
        ''
    }
    $modeDetail = if ($RequireRequestedPath) {
        ' The explicit trusted compiler path was not accepted and fallback is disabled.'
    } else {
        ' Install it or pass -InnoCompilerPath.'
    }
    throw "Inno Setup 6.7.1 or later was not found.$modeDetail$rejectedDetail"
}
