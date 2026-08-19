[CmdletBinding()]
param(
    [switch]$PostSetupLaunch,
    [string]$PostSetupExecutablePath,
    [string]$PostSetupWorkingDirectory,
    [ValidateRange(0, 2147483647)][int]$SetupProcessId = 0,
    [switch]$ForceStartService
)

Set-StrictMode -Version Latest

$legacyCompatibilityPath = Join-Path $PSScriptRoot 'LegacyCompatibility.generated.ps1'
if (-not (Test-Path -LiteralPath $legacyCompatibilityPath -PathType Leaf)) {
    throw "Required legacy-compatibility constants not found: $legacyCompatibilityPath"
}
. $legacyCompatibilityPath

$script:EverVigilInteractiveTaskPrefix = 'EverVigil Installer'
$script:TaskCreate = 2
$script:TaskLogonInteractiveToken = 3
$script:TaskRunLevelLeastPrivilege = 0
$script:TaskActionExecute = 0
$script:TaskStateQueued = 2
$script:TaskStateReady = 3
$script:TaskStateRunning = 4
$script:InteractiveLaunchStabilitySeconds = 2

function Invoke-EverVigilBoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($FilePath)
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start process: $FilePath"
        }
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            } catch {
                # Preserve the timeout as the primary failure.
            }
            throw [TimeoutException]::new(
                "$(Split-Path -Leaf $FilePath) did not exit within $TimeoutSeconds seconds.")
        }
        $exitCode = $process.ExitCode
        $standardError = $standardErrorTask.GetAwaiter().GetResult().Trim()
        if ($exitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($standardError)) {
            throw "$(Split-Path -Leaf $FilePath) failed with exit code ${exitCode}: $standardError"
        }
        return $exitCode
    } finally {
        $process.Dispose()
    }
}

function Assert-EverVigilInteractiveTaskIdentity {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    if ($TransactionId -cnotmatch '\A[0-9a-f]{32}\z') {
        throw "The interactive task transaction identifier is invalid: $TransactionId"
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = if ($null -eq $identity.User) {
        $null
    } else {
        $identity.User.Value
    }
    if ([string]::IsNullOrWhiteSpace($currentSid) -or
        -not [string]::Equals($OwnerSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The interactive task owner does not match the invoking user.'
    }
}

function Get-EverVigilInteractiveTaskName {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Launch', 'RecoveryLaunch')]
        [string]$Purpose,
        [switch]$Legacy
    )

    if ($TransactionId -cnotmatch '\A[0-9a-f]{32}\z') {
        throw "The interactive task transaction identifier is invalid: $TransactionId"
    }
    $prefix = if ($Legacy) {
        $script:LegacyCompatibilityInstallerTaskPrefix
    } else {
        $script:EverVigilInteractiveTaskPrefix
    }
    return "$prefix $TransactionId $Purpose"
}

function Get-EverVigilAllowedTaskArgumentLines {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Launch', 'RecoveryLaunch')]
        [string]$Purpose
    )

    switch ($Purpose) {
        'Command' { return @('--validate-settings', '--installer-runtime-check') }
        'Launch' { return @('--background', '--background --force-start-service') }
        'RecoveryLaunch' { return @('--background') }
    }
}

function Test-EverVigilAllowedTaskArgumentLine {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Launch', 'RecoveryLaunch')]
        [string]$Purpose,
        [Parameter(Mandatory)][string]$ArgumentLine
    )

    if ($ArgumentLine -in @(Get-EverVigilAllowedTaskArgumentLines -Purpose $Purpose)) {
        return $true
    }
    if ($Purpose -cne 'Launch') {
        return $false
    }

    $match = [regex]::Match(
        $ArgumentLine,
        '\A--background(?: --force-start-service)? --wait-for-pid (?<pid>[1-9][0-9]{0,9})\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        return $false
    }

    $processId = 0
    return [int]::TryParse($match.Groups['pid'].Value, [ref]$processId) -and
        $processId -gt 0
}

function New-EverVigilInteractiveTask {
    param(
        [Parameter(Mandatory)]$Service,
        [Parameter(Mandatory)]$Folder,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Launch', 'RecoveryLaunch')]
        [string]$Purpose,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
        throw "The interactive task executable was not found: $resolvedExecutable"
    }
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        throw "The interactive task working directory was not found: $resolvedWorkingDirectory"
    }
    $argumentLine = $Arguments -join ' '
    if (-not (Test-EverVigilAllowedTaskArgumentLine `
                -Purpose $Purpose `
                -ArgumentLine $argumentLine)) {
        throw "The interactive task arguments are not allowed: $($Arguments -join ' ')"
    }

    $definition = $Service.NewTask(0)
    $definition.RegistrationInfo.Description =
        'Temporary per-user launch used only while setup is running.'
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Principal.UserId = $OwnerSid
    $definition.Principal.LogonType = $script:TaskLogonInteractiveToken
    $definition.Principal.RunLevel = $script:TaskRunLevelLeastPrivilege
    $action = $definition.Actions.Create($script:TaskActionExecute)
    $action.Path = $resolvedExecutable
    $action.Arguments = $argumentLine
    $action.WorkingDirectory = $resolvedWorkingDirectory

    return $Folder.RegisterTaskDefinition(
        $TaskName,
        $definition,
        $script:TaskCreate,
        $null,
        $null,
        $script:TaskLogonInteractiveToken,
        $null)
}

function Remove-EverVigilInteractiveTaskFromFolder {
    param(
        [Parameter(Mandatory)]$Folder,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Launch', 'RecoveryLaunch')]
        [string]$Purpose,
        [Parameter(Mandatory)][string[]]$AllowedExecutablePath,
        [switch]$StopInstances
    )

    try {
        $task = $Folder.GetTask($TaskName)
    } catch {
        if ($_.Exception -is [IO.FileNotFoundException] -and
            $_.Exception.HResult -eq [int]0x80070002) {
            return
        }
        throw
    }
    $definition = $task.Definition
    $principalIdentity = [string]$definition.Principal.UserId
    try {
        $principalSid = if ($principalIdentity -match '\AS-1-') {
            [Security.Principal.SecurityIdentifier]::new($principalIdentity)
        } else {
            ([Security.Principal.NTAccount]::new($principalIdentity)).Translate(
                [Security.Principal.SecurityIdentifier])
        }
    } catch {
        throw "Refusing to remove an interactive task with an invalid principal: $TaskName"
    }
    $actions = $definition.Actions
    if (-not [string]::Equals(
            $principalSid.Value,
            $OwnerSid,
            [StringComparison]::OrdinalIgnoreCase) -or
        [int]$definition.Principal.LogonType -ne $script:TaskLogonInteractiveToken -or
        [int]$definition.Principal.RunLevel -ne $script:TaskRunLevelLeastPrivilege -or
        [int]$actions.Count -ne 1) {
        throw "Refusing to remove an interactive task that is not owned by this transaction: $TaskName"
    }
    $action = $actions.Item(1)
    $actionPath = [IO.Path]::GetFullPath([string]$action.Path)
    $allowedPaths = @($AllowedExecutablePath | ForEach-Object {
            [IO.Path]::GetFullPath($_)
        } | Select-Object -Unique)
    $pathMatches = @($allowedPaths | Where-Object {
            [string]::Equals($_, $actionPath, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
    $expectedWorkingDirectory = [IO.Path]::GetDirectoryName($actionPath)
    $workingDirectoryMatches = [string]::Equals(
        [IO.Path]::GetFullPath([string]$action.WorkingDirectory),
        $expectedWorkingDirectory,
        [StringComparison]::OrdinalIgnoreCase)
    if ([int]$action.Type -ne $script:TaskActionExecute -or
        -not $pathMatches -or
        -not $workingDirectoryMatches -or
        -not (Test-EverVigilAllowedTaskArgumentLine `
                -Purpose $Purpose `
                -ArgumentLine ([string]$action.Arguments))) {
        throw "Refusing to remove an interactive task with an unexpected action: $TaskName"
    }
    if ($StopInstances) {
        try { $task.Stop(0) } catch {}
    }
    $Folder.DeleteTask($TaskName, 0)
}

function Invoke-EverVigilInteractiveCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    Assert-EverVigilInteractiveTaskIdentity `
        -TransactionId $TransactionId `
        -OwnerSid $OwnerSid
    $taskName = Get-EverVigilInteractiveTaskName `
        -TransactionId $TransactionId `
        -Purpose Command
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder = $service.GetFolder('\')
    $task = $null
    $instance = $null
    $instanceActive = $false
    try {
        $task = New-EverVigilInteractiveTask `
            -Service $service `
            -Folder $folder `
            -TaskName $taskName `
            -OwnerSid $OwnerSid `
            -Purpose Command `
            -ExecutablePath $ExecutablePath `
            -Arguments $Arguments `
            -WorkingDirectory $WorkingDirectory
        $instance = $task.Run($null)
        $instanceActive = $true
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 100
            try {
                $instance.Refresh()
                $state = [int]$instance.State
            } catch {
                $task = $folder.GetTask($taskName)
                $state = [int]$task.State
                if ($state -ne $script:TaskStateReady) {
                    throw
                }
            }
        } while ($state -in @($script:TaskStateQueued, $script:TaskStateRunning) -and
            (Get-Date) -lt $deadline)
        if ($state -in @($script:TaskStateQueued, $script:TaskStateRunning)) {
            try { $instance.Stop() } catch {}
            throw "The interactive task command timed out: $($Arguments[0])"
        }
        $instanceActive = $false
        $task = $folder.GetTask($taskName)
        return [int]$task.LastTaskResult
    } finally {
        Remove-EverVigilInteractiveTaskFromFolder `
            -Folder $folder `
            -TaskName $taskName `
            -OwnerSid $OwnerSid `
            -Purpose Command `
            -AllowedExecutablePath $ExecutablePath `
            -StopInstances:$instanceActive
    }
}

function Start-EverVigilInteractiveProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateSet('Launch', 'RecoveryLaunch')][string]$Purpose = 'Launch'
    )

    Assert-EverVigilInteractiveTaskIdentity `
        -TransactionId $TransactionId `
        -OwnerSid $OwnerSid
    $taskName = Get-EverVigilInteractiveTaskName `
        -TransactionId $TransactionId `
        -Purpose $Purpose
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder = $service.GetFolder('\')
    $instance = $null
    $instanceActive = $false
    try {
        $task = New-EverVigilInteractiveTask `
            -Service $service `
            -Folder $folder `
            -TaskName $taskName `
            -OwnerSid $OwnerSid `
            -Purpose $Purpose `
            -ExecutablePath $ExecutablePath `
            -Arguments $Arguments `
            -WorkingDirectory $WorkingDirectory
        $instance = $task.Run($null)
        $instanceActive = $true
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 50
            try {
                $instance.Refresh()
                $state = [int]$instance.State
            } catch {
                $task = $folder.GetTask($taskName)
                $state = [int]$task.State
            }
        } while ($state -eq $script:TaskStateQueued -and (Get-Date) -lt $deadline)
        if ($state -eq $script:TaskStateQueued) {
            throw 'The interactive launch task remained queued for 10 seconds.'
        }
        if ($state -ne $script:TaskStateRunning) {
            $lastTaskResult = try {
                $task = $folder.GetTask($taskName)
                [int]$task.LastTaskResult
            } catch {
                'unavailable'
            }
            throw "The interactive launch task did not remain running (state=$state, LastTaskResult=$lastTaskResult)."
        }
        $stabilityDeadline = (Get-Date).AddSeconds(
            $script:InteractiveLaunchStabilitySeconds)
        do {
            Start-Sleep -Milliseconds 100
            try {
                $instance.Refresh()
                $state = [int]$instance.State
            } catch {
                $task = $folder.GetTask($taskName)
                $state = [int]$task.State
            }
            if ($state -ne $script:TaskStateRunning) {
                $lastTaskResult = try {
                    $task = $folder.GetTask($taskName)
                    [int]$task.LastTaskResult
                } catch {
                    'unavailable'
                }
                throw "The interactive launch task exited during its stability check (state=$state, LastTaskResult=$lastTaskResult)."
            }
        } while ((Get-Date) -lt $stabilityDeadline)
        $instanceActive = $true
        Remove-EverVigilInteractiveTaskFromFolder `
            -Folder $folder `
            -TaskName $taskName `
            -OwnerSid $OwnerSid `
            -Purpose $Purpose `
            -AllowedExecutablePath $ExecutablePath
    } catch {
        try {
            Remove-EverVigilInteractiveTaskFromFolder `
                -Folder $folder `
                -TaskName $taskName `
                -OwnerSid $OwnerSid `
                -Purpose $Purpose `
                -AllowedExecutablePath $ExecutablePath `
                -StopInstances:$instanceActive
        } catch {}
        throw
    }
}

function Get-EverVigilProcessesAtRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $prefix = "{0}\" -f ([IO.Path]::GetFullPath($Root).TrimEnd('\'))
    $processNames = @(
        'EverVigil'
        [IO.Path]::GetFileNameWithoutExtension(
            $script:LegacyCompatibilityApplicationExecutableFileName)
    ) | Select-Object -Unique
    return @(Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Where-Object {
            $processPath = try { [string]$_.Path } catch { '' }
            -not [string]::IsNullOrWhiteSpace($processPath) -and
                $processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Start-EverVigilRestoredSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $attemptErrors = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Start-EverVigilInteractiveProcess `
                -TransactionId $TransactionId `
                -OwnerSid $OwnerSid `
                -ExecutablePath $ExecutablePath `
                -Arguments @('--background') `
                -WorkingDirectory $WorkingDirectory `
                -Purpose RecoveryLaunch
            $survivalDeadline = (Get-Date).AddSeconds(2)
            do {
                Start-Sleep -Milliseconds 250
                if (@(Get-EverVigilProcessesAtRoot `
                            -Root $WorkingDirectory).Count -eq 0) {
                    throw 'The restored supervisor exited during the post-launch stability check.'
                }
            } while ((Get-Date) -lt $survivalDeadline)
            return
        } catch {
            $attemptErrors.Add("attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }
    throw "Restored supervisor launch failed after 3 attempts: $($attemptErrors -join ' | ')"
}

function Remove-EverVigilInteractiveTasksForTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)][string[]]$AllowedExecutablePath,
        [switch]$StopInstances
    )

    Assert-EverVigilInteractiveTaskIdentity `
        -TransactionId $TransactionId `
        -OwnerSid $OwnerSid
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder = $service.GetFolder('\')
    foreach ($legacy in @($false, $true)) {
        foreach ($purpose in @('Command', 'Launch', 'RecoveryLaunch')) {
            Remove-EverVigilInteractiveTaskFromFolder `
                -Folder $folder `
                -TaskName (Get-EverVigilInteractiveTaskName `
                    -TransactionId $TransactionId `
                    -Purpose $purpose `
                    -Legacy:$legacy) `
                -OwnerSid $OwnerSid `
                -Purpose $purpose `
                -AllowedExecutablePath $AllowedExecutablePath `
                -StopInstances:$StopInstances
        }
    }
}

if ($PostSetupLaunch) {
    if ([string]::IsNullOrWhiteSpace($PostSetupExecutablePath) -or
        [string]::IsNullOrWhiteSpace($PostSetupWorkingDirectory) -or
        $SetupProcessId -le 0) {
        throw 'Post-setup launch requires an executable, working directory, and positive Setup process identifier.'
    }

    $setupProcess = Get-Process -Id $SetupProcessId -ErrorAction Stop
    $setupProcess.Dispose()
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('--background')
    if ($ForceStartService) {
        $arguments.Add('--force-start-service')
    }
    $arguments.Add('--wait-for-pid')
    $arguments.Add($SetupProcessId.ToString([Globalization.CultureInfo]::InvariantCulture))

    Start-EverVigilInteractiveProcess `
        -TransactionId ([guid]::NewGuid().ToString('N')) `
        -OwnerSid $ownerSid `
        -ExecutablePath $PostSetupExecutablePath `
        -Arguments $arguments.ToArray() `
        -WorkingDirectory $PostSetupWorkingDirectory `
        -Purpose Launch
} elseif ($PSBoundParameters.Count -gt 0) {
    throw 'Script parameters are valid only for a post-setup launch.'
}
