[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [ValidateNotNullOrEmpty()]
    [string]$SolutionPath,

    [Parameter(Mandatory, ParameterSetName = 'Fixture')]
    [ValidateNotNullOrEmpty()]
    [string]$AuditJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Invoke-NuGetAudit {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
            'list'
            $resolvedPath
            'package'
            '--vulnerable'
            '--include-transitive'
            '--format'
            'json'
            '--output-version'
            '1'
        )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Could not start the dotnet package audit.'
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'The NuGet vulnerability audit timed out after five minutes.'
        }

        $output = $standardOutput.GetAwaiter().GetResult()
        $errorOutput = $standardError.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw "dotnet package audit failed with exit code $($process.ExitCode): $errorOutput"
        }
        if ([string]::IsNullOrWhiteSpace($output)) {
            throw 'dotnet package audit returned no JSON output.'
        }
        if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
            Write-Verbose $errorOutput
        }
        return $output
    } finally {
        $process.Dispose()
    }
}

$auditJson = if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
    [IO.File]::ReadAllText((Resolve-Path -LiteralPath $AuditJsonPath).Path)
} else {
    Invoke-NuGetAudit -Path $SolutionPath
}

try {
    $audit = $auditJson | ConvertFrom-Json -Depth 100
} catch {
    throw "NuGet vulnerability audit returned invalid JSON: $($_.Exception.Message)"
}

$outputVersion = Get-JsonPropertyValue -InputObject $audit -Name 'version'
if ($outputVersion -ne 1) {
    throw "Unsupported NuGet audit JSON version: $outputVersion"
}
$projectsValue = Get-JsonPropertyValue -InputObject $audit -Name 'projects'
if ($null -eq $projectsValue) {
    throw 'NuGet audit JSON does not contain a projects collection.'
}

$projects = @($projectsValue)
$findings = [Collections.Generic.List[string]]::new()
foreach ($project in $projects) {
    $projectPath = Get-JsonPropertyValue -InputObject $project -Name 'path'
    if ([string]::IsNullOrWhiteSpace([string]$projectPath)) {
        $projectPath = '<unknown project>'
    }
    foreach ($framework in @(Get-JsonPropertyValue -InputObject $project -Name 'frameworks')) {
        if ($null -eq $framework) {
            continue
        }
        foreach ($packageCollectionName in @('topLevelPackages', 'transitivePackages')) {
            foreach ($package in @(Get-JsonPropertyValue -InputObject $framework -Name $packageCollectionName)) {
                if ($null -eq $package) {
                    continue
                }
                $packageId = [string](Get-JsonPropertyValue -InputObject $package -Name 'id')
                $resolvedVersion = [string](Get-JsonPropertyValue -InputObject $package -Name 'resolvedVersion')
                foreach ($vulnerability in @(Get-JsonPropertyValue -InputObject $package -Name 'vulnerabilities')) {
                    if ($null -eq $vulnerability) {
                        continue
                    }
                    $severity = [string](Get-JsonPropertyValue -InputObject $vulnerability -Name 'severity')
                    $advisoryUrl = [string](Get-JsonPropertyValue -InputObject $vulnerability -Name 'advisoryUrl')
                    if ([string]::IsNullOrWhiteSpace($advisoryUrl)) {
                        $advisoryUrl = [string](Get-JsonPropertyValue -InputObject $vulnerability -Name 'advisoryurl')
                    }
                    $findings.Add(
                        "$packageId $resolvedVersion [$severity] $advisoryUrl ($projectPath)")
                }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    throw "NuGet vulnerability audit found $($findings.Count) known vulnerability finding(s):`n$($findings -join [Environment]::NewLine)"
}

"NuGet vulnerability audit passed: $($projects.Count) project(s), no known vulnerabilities."
