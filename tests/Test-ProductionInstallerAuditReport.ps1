[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CandidateRoot,

    [Parameter(Mandatory)]
    [string]$ReportRoot,

    [Parameter(Mandatory)]
    [ValidateSet('AMD', 'Intel')]
    [string]$ExpectedCpuVendor,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9a-f]{40}\z')]
    [string]$ExpectedSourceSha,

    [Parameter(Mandatory)]
    [ValidatePattern('\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z')]
    [string]$ExpectedVersion,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[1-9]\d*\z')]
    [string]$ExpectedWorkflowRunId,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[1-9]\d*\z')]
    [string]$ExpectedWorkflowRunAttempt,

    [Parameter(Mandatory)]
    [ValidateSet('production-installer-audit-amd', 'production-installer-audit-intel')]
    [string]$ExpectedAuditJob
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [Text.UTF8Encoding]::new($false, $true)
$script:MaximumManifestBytes = 1MB
$script:MaximumReportBytes = 1MB
$script:MaximumEvidenceFileBytes = 64MB
$script:MaximumEvidenceTotalBytes = 256MB

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($InputObject -isnot [pscustomobject]) {
        throw "$Context must be a JSON object."
    }

    $actualNames = @($InputObject.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $expectedNames = @($Expected | Sort-Object -CaseSensitive)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw "$Context does not contain the exact required property set."
    }
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)]
        [Text.Json.JsonElement]$Element,

        [Parameter(Mandatory)]
        [string]$Context
    )

    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $names = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) {
                    throw "$Context contains a duplicate JSON property: $($property.Name)"
                }
                Assert-NoDuplicateJsonProperties `
                    -Element $property.Value `
                    -Context "$Context.$($property.Name)"
            }
            break
        }
        ([Text.Json.JsonValueKind]::Array) {
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                Assert-NoDuplicateJsonProperties `
                    -Element $item `
                    -Context "$Context[$index]"
                $index++
            }
            break
        }
    }
}

function Read-StrictJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [long]$MaximumBytes,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 0 -or
        $item.Length -gt $MaximumBytes) {
        throw "$Context is not a bounded regular file."
    }

    $text = [IO.File]::ReadAllText($item.FullName, $script:Utf8NoBom)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 64
    $document = [Text.Json.JsonDocument]::Parse($text, $options)
    try {
        Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context
    } finally {
        $document.Dispose()
    }

    try {
        return $text | ConvertFrom-Json -Depth 64
    } catch {
        throw "$Context is not valid strict JSON: $($_.Exception.Message)"
    }
}

function Resolve-RegularRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a non-reparse directory."
    }
    return $resolved
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Path.Length -gt 240 -or
        $Path -cnotmatch '\A[A-Za-z0-9._/-]+\z' -or
        $Path.Contains('\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('/', [StringComparison]::Ordinal) -or
        $Path.EndsWith('/', [StringComparison]::Ordinal)) {
        throw "$Context is not a bounded portable relative path."
    }
    foreach ($segment in @($Path.Split('/'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..')) {
            throw "$Context contains an unsafe path segment."
        }
    }
}

function Resolve-ManifestFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string]$Context
    )

    Assert-SafeRelativePath -Path $RelativePath -Context $Context
    $current = $Root
    foreach ($segment in @($RelativePath.Split('/'))) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context traverses a reparse point."
        }
    }
    $fullPath = [IO.Path]::GetFullPath($current)
    if (-not $fullPath.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escapes its validated root."
    }
    $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($file.PSIsContainer) {
        throw "$Context does not identify a regular file."
    }
    return $file
}

function Assert-LowerSha256 {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '\A[0-9a-f]{64}\z') {
        throw "$Context must be one lowercase SHA-256 value."
    }
}

function Assert-TrueBoolean {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Value -isnot [bool] -or -not [bool]$Value) {
        throw "$Context must be the JSON boolean true."
    }
}

function Assert-FalseBoolean {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Value -isnot [bool] -or [bool]$Value) {
        throw "$Context must be the JSON boolean false."
    }
}

function Assert-ZeroInteger {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Value -isnot [long] -or [long]$Value -ne 0) {
        throw "$Context must be the JSON integer zero."
    }
}

function Assert-CleanInstallContract {
    param(
        [Parameter(Mandatory)]
        [object]$CleanInstall,

        [Parameter(Mandatory)]
        [string]$ExpectedInstallerName,

        [Parameter(Mandatory)]
        [string]$ExpectedInstallerSha256,

        [Parameter(Mandatory)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory)]
        [string]$Context
    )

    Assert-ExactProperties `
        -InputObject $CleanInstall `
        -Expected @('broker', 'postState', 'preState', 'runtime', 'setup') `
        -Context $Context

    Assert-ExactProperties `
        -InputObject $CleanInstall.preState `
        -Expected @(
            'currentDataRootAbsent',
            'installRootAbsent',
            'installTransactionJournalAbsent',
            'installTransactionTemporaryCount',
            'legacyDataRootAbsent',
            'protectedBrokerExecutableAbsent',
            'protectedBrokerInstallationReceiptAbsent',
            'protectedBrokerRootAbsent',
            'protectedBrokerRetirementReceiptAbsent',
            'startMenuGroupAbsent',
            'uninstallRegistrationAbsent',
            'uninstallSupportRootAbsent') `
        -Context "$Context preState"
    foreach ($propertyName in @(
            'currentDataRootAbsent',
            'installRootAbsent',
            'installTransactionJournalAbsent',
            'legacyDataRootAbsent',
            'protectedBrokerExecutableAbsent',
            'protectedBrokerInstallationReceiptAbsent',
            'protectedBrokerRootAbsent',
            'protectedBrokerRetirementReceiptAbsent',
            'startMenuGroupAbsent',
            'uninstallRegistrationAbsent',
            'uninstallSupportRootAbsent')) {
        Assert-TrueBoolean `
            -Value $CleanInstall.preState.$propertyName `
            -Context "$Context preState $propertyName"
    }
    Assert-ZeroInteger `
        -Value $CleanInstall.preState.installTransactionTemporaryCount `
        -Context "$Context preState installTransactionTemporaryCount"

    Assert-ExactProperties `
        -InputObject $CleanInstall.setup `
        -Expected @(
            'administrativeInstallMode',
            'auditExtractRequested',
            'compatibilityModeDetected',
            'exitCode',
            'installModeRootKey',
            'installerSha256After',
            'installerSha256Before',
            'kind',
            'path',
            'prepareToInstallSucceeded',
            'resourceAuditBuild',
            'standardUser') `
        -Context "$Context setup"
    if ($CleanInstall.setup.path -isnot [string] -or
        [string]$CleanInstall.setup.path -cnotmatch '\A[A-Za-z]:\\' -or
        [IO.Path]::GetFileName([string]$CleanInstall.setup.path) -cne $ExpectedInstallerName -or
        $CleanInstall.setup.kind -isnot [string] -or
        [string]$CleanInstall.setup.kind -cne 'production' -or
        $CleanInstall.setup.installModeRootKey -isnot [string] -or
        [string]$CleanInstall.setup.installModeRootKey -cne 'HKEY_CURRENT_USER' -or
        $CleanInstall.setup.installerSha256Before -isnot [string] -or
        [string]$CleanInstall.setup.installerSha256Before -cne $ExpectedInstallerSha256 -or
        $CleanInstall.setup.installerSha256After -isnot [string] -or
        [string]$CleanInstall.setup.installerSha256After -cne $ExpectedInstallerSha256) {
        throw "$Context setup is not the exact candidate production Setup invocation."
    }
    foreach ($propertyName in @('standardUser', 'prepareToInstallSucceeded')) {
        Assert-TrueBoolean `
            -Value $CleanInstall.setup.$propertyName `
            -Context "$Context setup $propertyName"
    }
    foreach ($propertyName in @(
            'administrativeInstallMode',
            'auditExtractRequested',
            'compatibilityModeDetected',
            'resourceAuditBuild')) {
        Assert-FalseBoolean `
            -Value $CleanInstall.setup.$propertyName `
            -Context "$Context setup $propertyName"
    }
    Assert-ZeroInteger -Value $CleanInstall.setup.exitCode -Context "$Context setup exitCode"

    Assert-ExactProperties `
        -InputObject $CleanInstall.broker `
        -Expected @(
            'authenticationExitCode3Count',
            'bootstrapDisposition',
            'bootstrapExitCode',
            'bootstrapPipeConnected',
            'brokerIntegrityLevel',
            'canonicalExitCode',
            'canonicalPipeConnected',
            'canonicalStatusDisposition',
            'clientIntegrityLevel',
            'installationReceiptPresent',
            'protectedExecutablePresent',
            'protectedExecutableSha256',
            'receiptExecutableSha256') `
        -Context "$Context broker"
    if ($CleanInstall.broker.clientIntegrityLevel -isnot [string] -or
        [string]$CleanInstall.broker.clientIntegrityLevel -cne 'Medium' -or
        $CleanInstall.broker.brokerIntegrityLevel -isnot [string] -or
        [string]$CleanInstall.broker.brokerIntegrityLevel -cne 'High' -or
        $CleanInstall.broker.bootstrapDisposition -isnot [string] -or
        [string]$CleanInstall.broker.bootstrapDisposition -cne 'CanonicalReady' -or
        $CleanInstall.broker.canonicalStatusDisposition -isnot [string] -or
        [string]$CleanInstall.broker.canonicalStatusDisposition -cne 'NoChange') {
        throw "$Context broker did not complete the exact elevated two-stage Status round trip."
    }
    foreach ($propertyName in @(
            'bootstrapPipeConnected',
            'canonicalPipeConnected',
            'installationReceiptPresent',
            'protectedExecutablePresent')) {
        Assert-TrueBoolean `
            -Value $CleanInstall.broker.$propertyName `
            -Context "$Context broker $propertyName"
    }
    foreach ($propertyName in @(
            'authenticationExitCode3Count',
            'bootstrapExitCode',
            'canonicalExitCode')) {
        Assert-ZeroInteger `
            -Value $CleanInstall.broker.$propertyName `
            -Context "$Context broker $propertyName"
    }
    Assert-LowerSha256 `
        -Value $CleanInstall.broker.protectedExecutableSha256 `
        -Context "$Context broker protectedExecutableSha256"
    Assert-LowerSha256 `
        -Value $CleanInstall.broker.receiptExecutableSha256 `
        -Context "$Context broker receiptExecutableSha256"
    if ([string]$CleanInstall.broker.protectedExecutableSha256 -cne
        [string]$CleanInstall.broker.receiptExecutableSha256) {
        throw "$Context protected broker bytes do not match the installation receipt."
    }

    Assert-ExactProperties `
        -InputObject $CleanInstall.runtime `
        -Expected @(
            'applicationErrorEvent1000Count',
            'coreClrPath',
            'coreClrSha256',
            'coreClrVersion',
            'dotNetRuntimeEvent1023Count',
            'eventWindowCoversSetupLifecycle',
            'internalClrError80131506Count',
            'powerShellPath',
            'powerShellSha256',
            'powerShellVersion',
            'windowsErrorReportingEvent1001Count') `
        -Context "$Context runtime"
    if ($CleanInstall.runtime.powerShellPath -isnot [string] -or
        [string]$CleanInstall.runtime.powerShellPath -cne
            'C:\Program Files\PowerShell\7\pwsh.exe' -or
        $CleanInstall.runtime.coreClrPath -isnot [string] -or
        [string]$CleanInstall.runtime.coreClrPath -cne
            'C:\Program Files\PowerShell\7\coreclr.dll' -or
        $CleanInstall.runtime.powerShellVersion -isnot [string] -or
        [string]$CleanInstall.runtime.powerShellVersion -cnotmatch
            '\A[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z' -or
        $CleanInstall.runtime.coreClrVersion -isnot [string] -or
        [string]$CleanInstall.runtime.coreClrVersion -cnotmatch
            '\A[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z') {
        throw "$Context runtime does not identify the fixed production PowerShell/CoreCLR."
    }
    Assert-LowerSha256 `
        -Value $CleanInstall.runtime.powerShellSha256 `
        -Context "$Context runtime powerShellSha256"
    Assert-LowerSha256 `
        -Value $CleanInstall.runtime.coreClrSha256 `
        -Context "$Context runtime coreClrSha256"
    Assert-TrueBoolean `
        -Value $CleanInstall.runtime.eventWindowCoversSetupLifecycle `
        -Context "$Context runtime eventWindowCoversSetupLifecycle"
    foreach ($propertyName in @(
            'applicationErrorEvent1000Count',
            'dotNetRuntimeEvent1023Count',
            'internalClrError80131506Count',
            'windowsErrorReportingEvent1001Count')) {
        Assert-ZeroInteger `
            -Value $CleanInstall.runtime.$propertyName `
            -Context "$Context runtime $propertyName"
    }

    Assert-ExactProperties `
        -InputObject $CleanInstall.postState `
        -Expected @(
            'configurationRequiredExact',
            'currentDataRootPresent',
            'installedExecutablePresent',
            'installedVersion',
            'installerErrorLineCount',
            'installRootPresent',
            'installTransactionJournalAbsent',
            'installTransactionTemporaryCount',
            'legacyDataRootAbsent',
            'prepareFailureLineCount',
            'startMenuGroupPresent',
            'transactionCompleted',
            'uninstallRegistrationPresent',
            'uninstallSupportRootPresent') `
        -Context "$Context postState"
    foreach ($propertyName in @(
            'configurationRequiredExact',
            'currentDataRootPresent',
            'installedExecutablePresent',
            'installRootPresent',
            'installTransactionJournalAbsent',
            'legacyDataRootAbsent',
            'startMenuGroupPresent',
            'transactionCompleted',
            'uninstallRegistrationPresent',
            'uninstallSupportRootPresent')) {
        Assert-TrueBoolean `
            -Value $CleanInstall.postState.$propertyName `
            -Context "$Context postState $propertyName"
    }
    if ($CleanInstall.postState.installedVersion -isnot [string] -or
        [string]$CleanInstall.postState.installedVersion -cne $ExpectedVersion) {
        throw "$Context postState installedVersion does not match the candidate."
    }
    foreach ($propertyName in @(
            'installerErrorLineCount',
            'installTransactionTemporaryCount',
            'prepareFailureLineCount')) {
        Assert-ZeroInteger `
            -Value $CleanInstall.postState.$propertyName `
            -Context "$Context postState $propertyName"
    }
}

function ConvertTo-CanonicalCleanInstallJson {
    param([Parameter(Mandatory)][object]$CleanInstall)

    return ([ordered]@{
            preState = [ordered]@{
                currentDataRootAbsent = $CleanInstall.preState.currentDataRootAbsent
                installRootAbsent = $CleanInstall.preState.installRootAbsent
                installTransactionJournalAbsent = $CleanInstall.preState.installTransactionJournalAbsent
                installTransactionTemporaryCount = $CleanInstall.preState.installTransactionTemporaryCount
                legacyDataRootAbsent = $CleanInstall.preState.legacyDataRootAbsent
                protectedBrokerExecutableAbsent = $CleanInstall.preState.protectedBrokerExecutableAbsent
                protectedBrokerInstallationReceiptAbsent = $CleanInstall.preState.protectedBrokerInstallationReceiptAbsent
                protectedBrokerRootAbsent = $CleanInstall.preState.protectedBrokerRootAbsent
                protectedBrokerRetirementReceiptAbsent = $CleanInstall.preState.protectedBrokerRetirementReceiptAbsent
                startMenuGroupAbsent = $CleanInstall.preState.startMenuGroupAbsent
                uninstallRegistrationAbsent = $CleanInstall.preState.uninstallRegistrationAbsent
                uninstallSupportRootAbsent = $CleanInstall.preState.uninstallSupportRootAbsent
            }
            setup = [ordered]@{
                administrativeInstallMode = $CleanInstall.setup.administrativeInstallMode
                auditExtractRequested = $CleanInstall.setup.auditExtractRequested
                compatibilityModeDetected = $CleanInstall.setup.compatibilityModeDetected
                exitCode = $CleanInstall.setup.exitCode
                installModeRootKey = $CleanInstall.setup.installModeRootKey
                installerSha256After = $CleanInstall.setup.installerSha256After
                installerSha256Before = $CleanInstall.setup.installerSha256Before
                kind = $CleanInstall.setup.kind
                path = $CleanInstall.setup.path
                prepareToInstallSucceeded = $CleanInstall.setup.prepareToInstallSucceeded
                resourceAuditBuild = $CleanInstall.setup.resourceAuditBuild
                standardUser = $CleanInstall.setup.standardUser
            }
            broker = [ordered]@{
                authenticationExitCode3Count = $CleanInstall.broker.authenticationExitCode3Count
                bootstrapDisposition = $CleanInstall.broker.bootstrapDisposition
                bootstrapExitCode = $CleanInstall.broker.bootstrapExitCode
                bootstrapPipeConnected = $CleanInstall.broker.bootstrapPipeConnected
                brokerIntegrityLevel = $CleanInstall.broker.brokerIntegrityLevel
                canonicalExitCode = $CleanInstall.broker.canonicalExitCode
                canonicalPipeConnected = $CleanInstall.broker.canonicalPipeConnected
                canonicalStatusDisposition = $CleanInstall.broker.canonicalStatusDisposition
                clientIntegrityLevel = $CleanInstall.broker.clientIntegrityLevel
                installationReceiptPresent = $CleanInstall.broker.installationReceiptPresent
                protectedExecutablePresent = $CleanInstall.broker.protectedExecutablePresent
                protectedExecutableSha256 = $CleanInstall.broker.protectedExecutableSha256
                receiptExecutableSha256 = $CleanInstall.broker.receiptExecutableSha256
            }
            runtime = [ordered]@{
                applicationErrorEvent1000Count = $CleanInstall.runtime.applicationErrorEvent1000Count
                coreClrPath = $CleanInstall.runtime.coreClrPath
                coreClrSha256 = $CleanInstall.runtime.coreClrSha256
                coreClrVersion = $CleanInstall.runtime.coreClrVersion
                dotNetRuntimeEvent1023Count = $CleanInstall.runtime.dotNetRuntimeEvent1023Count
                eventWindowCoversSetupLifecycle = $CleanInstall.runtime.eventWindowCoversSetupLifecycle
                internalClrError80131506Count = $CleanInstall.runtime.internalClrError80131506Count
                powerShellPath = $CleanInstall.runtime.powerShellPath
                powerShellSha256 = $CleanInstall.runtime.powerShellSha256
                powerShellVersion = $CleanInstall.runtime.powerShellVersion
                windowsErrorReportingEvent1001Count = $CleanInstall.runtime.windowsErrorReportingEvent1001Count
            }
            postState = [ordered]@{
                configurationRequiredExact = $CleanInstall.postState.configurationRequiredExact
                currentDataRootPresent = $CleanInstall.postState.currentDataRootPresent
                installedExecutablePresent = $CleanInstall.postState.installedExecutablePresent
                installedVersion = $CleanInstall.postState.installedVersion
                installerErrorLineCount = $CleanInstall.postState.installerErrorLineCount
                installRootPresent = $CleanInstall.postState.installRootPresent
                installTransactionJournalAbsent = $CleanInstall.postState.installTransactionJournalAbsent
                installTransactionTemporaryCount = $CleanInstall.postState.installTransactionTemporaryCount
                legacyDataRootAbsent = $CleanInstall.postState.legacyDataRootAbsent
                prepareFailureLineCount = $CleanInstall.postState.prepareFailureLineCount
                startMenuGroupPresent = $CleanInstall.postState.startMenuGroupPresent
                transactionCompleted = $CleanInstall.postState.transactionCompleted
                uninstallRegistrationPresent = $CleanInstall.postState.uninstallRegistrationPresent
                uninstallSupportRootPresent = $CleanInstall.postState.uninstallSupportRootPresent
            }
        } | ConvertTo-Json -Compress -Depth 8)
}

function Assert-ProductionSetupLog {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedSetupPath,
        [Parameter(Mandatory)][string]$Context
    )

    $originalSetupMatches = [regex]::Matches(
        $Text,
        '(?m)^[^\r\n]*Original Setup EXE:\s*(?<path>[^\r\n]+)$')
    if ($originalSetupMatches.Count -ne 1 -or
        $originalSetupMatches[0].Groups['path'].Value.Trim() -cne $ExpectedSetupPath) {
        throw "$Context is not bound to the exact executed production Setup path."
    }
    foreach ($requiredLine in @(
            'User privileges: None',
            'Administrative install mode: No',
            'Install mode root key: HKEY_CURRENT_USER',
            'EverVigil.Package\Install.ps1',
            '[evervigil] Health: CONFIGURATION REQUIRED',
            '[evervigil] Transaction: pending setup completion',
            'EverVigil install worker exit code: 0',
            '[evervigil] Install transaction sealed for commit.',
            '[evervigil] Install transaction committed.',
            'Need to restart Windows? No',
            'Log closed.')) {
        if (-not $Text.Contains($requiredLine, [StringComparison]::Ordinal)) {
            throw "$Context is missing a required successful production Setup marker: $requiredLine"
        }
    }
    if ($Text -match '(?i)/AUDITEXTRACT(?:=|\s|\")' -or
        $Text -match '(?i)Compatibility mode:\s*Yes' -or
        $Text -match '(?i)\[evervigil-error\]' -or
        $Text -match '(?i)PrepareToInstall failed' -or
        $Text -match '(?i)EverVigil install worker exit code:\s*(?!0\b)\d+' -or
        $Text -match '(?i)exited before opening its authenticated pipe' -or
        $Text -match '(?i)\bexit\s+3\b' -or
        $Text -match '(?i)Internal CLR error' -or
        $Text -match '(?i)0x80131506' -or
        $Text -match '(?i)Fatal error' -or
        $Text -match '(?i)Cannot find path' -or
        $Text -match '(?i)Install transaction (?:commit |finalization )?(?:failed|incomplete)') {
        throw "$Context contains a production Setup failure marker."
    }
}

function Assert-ExactStringArray {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $actual = @($Value)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Context does not contain the exact required entries."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($actual[$index] -isnot [string] -or
            [string]$actual[$index] -cne $Expected[$index]) {
            throw "$Context is not in the exact required order."
        }
    }
}

function Assert-CredentialFreeEvidenceText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Text.Contains([char]0) -or
        $Text -match '(?i)authorization\s*:\s*bearer' -or
        $Text -match '(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}' -or
        $Text -match '(?i)[?&](?:token|bridge_token|access_token)=' -or
        $Text -match '(?i)\\u003[fF](?:token|bridge_token|access_token)\\u003[dD]' -or
        $Text -match '(?i)\bBRIDGE_TOKEN\s*=' -or
        $Text -match '(?i)"(?:token|bridgeToken|accessToken|authorization|connectionUrl|qrPayload)"\s*:' -or
        $Text -match '(?i)(?:github_pat_|gh[pousr]_|tskey-(?:auth|client|api|webhook)-)' -or
        $Text -match '(?<![A-Za-z0-9_-])sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-])' -or
        $Text -match '(?i)\b(?:ACTIONS_RUNTIME_TOKEN|ACTIONS_ID_TOKEN_REQUEST_TOKEN|GITHUB_TOKEN|GH_TOKEN|TS_AUTHKEY|TAILSCALE_AUTHKEY|OPENAI_API_KEY|CODEX_API_KEY|ANTHROPIC_API_KEY|AZURE_OPENAI_API_KEY)\b["'']?\s*[:=]' -or
        $Text -match '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])' -or
        $Text -match '(?i)EVERVIGIL[_-]?AUDIT[_-]?(?:TOKEN|CANARY)' -or
        $Text -match '(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])') {
        throw "$Context contains credential-bearing or token-shaped content."
    }
}

$credentialLeakFixtures = @(
    'https://fixture.invalid/?token=redacted-is-not-allowed'
    ('gh' + 'p_fixturecredentialvalue')
    ('tskey-' + 'auth-fixturecredentialvalue')
    ('s' + 'k-proj-' + ('a' * 20))
    'GITHUB_TOKEN=fake-value'
    ('ACTIONS_RUNTIME_TOKEN=' + 'ey' + 'Jabcdefghijk.abcdefghijk.abcdefghijk')
    'OPENAI_API_KEY=fake-value'
    ('a' * 32)
)
foreach ($fixture in $credentialLeakFixtures) {
    $fixtureRejected = $false
    try {
        Assert-CredentialFreeEvidenceText -Text $fixture -Context 'negative credential fixture'
    } catch {
        $fixtureRejected = $true
    }
    if (-not $fixtureRejected) {
        throw 'A credential-evidence negative fixture was not rejected.'
    }
}

$productionSetupFixturePath =
    'C:\EverVigilAudit\candidate\EverVigil-2.1.0-Setup.exe'
$productionSetupSuccessFixture = @"
2026-08-18 10:00:00.000   Original Setup EXE: $productionSetupFixturePath
2026-08-18 10:00:00.001   Setup command line: /VERYSILENT /NORESTART
2026-08-18 10:00:00.002   User privileges: None
2026-08-18 10:00:00.003   Administrative install mode: No
2026-08-18 10:00:00.004   Install mode root key: HKEY_CURRENT_USER
2026-08-18 10:00:00.005   Extracting temporary file: C:\Audit\EverVigil.Package\Install.ps1
2026-08-18 10:00:00.006   [evervigil] Health: CONFIGURATION REQUIRED
2026-08-18 10:00:00.007   [evervigil] Transaction: pending setup completion
2026-08-18 10:00:00.008   EverVigil install worker exit code: 0
2026-08-18 10:00:00.009   [evervigil] Install transaction sealed for commit.
2026-08-18 10:00:00.010   [evervigil] Install transaction committed.
2026-08-18 10:00:00.011   Need to restart Windows? No
2026-08-18 10:00:00.012   Log closed.
"@
Assert-ProductionSetupLog `
    -Text $productionSetupSuccessFixture `
    -ExpectedSetupPath $productionSetupFixturePath `
    -Context 'positive production Setup fixture'
$productionSetupFailureFixtures = @(
    '2026-08-18 10:47:48.483   [evervigil-error] ERROR: The system broker exited before opening its authenticated pipe (exit 3).'
    '2026-08-18 10:47:48.483   EverVigil install worker exit code: 1'
    '2026-08-18 10:47:48.508   PrepareToInstall failed: installation could not be completed.'
    '2026-08-18 10:47:07.308   Setup command line: /AUDITEXTRACT="C:\Audit"'
    '2026-08-18 10:47:07.308   Compatibility mode: Yes (DetectorsAppHealth)'
    '2026-08-18 10:47:48.483   [evervigil-error] Internal CLR error. (0x80131506)'
)
foreach ($fixture in $productionSetupFailureFixtures) {
    $fixtureRejected = $false
    try {
        Assert-ProductionSetupLog `
            -Text ($productionSetupSuccessFixture + "`r`n" + $fixture) `
            -ExpectedSetupPath $productionSetupFixturePath `
            -Context 'negative production Setup fixture'
    } catch {
        $fixtureRejected = $true
    }
    if (-not $fixtureRejected) {
        throw 'A #015 production Setup semantic negative fixture was not rejected.'
    }
}

$candidateRootPath = Resolve-RegularRoot -Path $CandidateRoot -Context 'candidate root'
$reportRootPath = Resolve-RegularRoot -Path $ReportRoot -Context 'audit report root'
$candidateManifestPath = Join-Path $candidateRootPath 'candidate-manifest.json'
$candidateManifest = Read-StrictJsonFile `
    -Path $candidateManifestPath `
    -MaximumBytes $script:MaximumManifestBytes `
    -Context 'candidate manifest'

Assert-ExactProperties `
    -InputObject $candidateManifest `
    -Expected @(
        'files',
        'installerName',
        'installerSha256',
        'schemaVersion',
        'sourceSha',
        'version') `
    -Context 'candidate manifest'
if ($candidateManifest.schemaVersion -isnot [long] -or
    [long]$candidateManifest.schemaVersion -ne 1 -or
    $candidateManifest.sourceSha -isnot [string] -or
    [string]$candidateManifest.sourceSha -cne $ExpectedSourceSha -or
    $candidateManifest.version -isnot [string] -or
    [string]$candidateManifest.version -cne $ExpectedVersion -or
    $candidateManifest.installerName -isnot [string] -or
    [string]$candidateManifest.installerName -cne "EverVigil-$ExpectedVersion-Setup.exe") {
    throw 'The candidate manifest identity does not match the requested source and version.'
}
Assert-LowerSha256 `
    -Value $candidateManifest.installerSha256 `
    -Context 'candidate installerSha256'

$candidateEntries = @($candidateManifest.files)
if ($candidateEntries.Count -lt 5) {
    throw 'The candidate manifest is unexpectedly incomplete.'
}
$candidateFiles = @{}
foreach ($entry in $candidateEntries) {
    Assert-ExactProperties `
        -InputObject $entry `
        -Expected @('length', 'path', 'sha256') `
        -Context 'candidate manifest file entry'
    if ($entry.path -isnot [string] -or
        $entry.length -isnot [long] -or
        [long]$entry.length -lt 0) {
        throw 'A candidate manifest file entry has an invalid path or length type.'
    }
    Assert-SafeRelativePath -Path ([string]$entry.path) -Context 'candidate file path'
    Assert-LowerSha256 -Value $entry.sha256 -Context 'candidate file sha256'
    if ($candidateFiles.ContainsKey([string]$entry.path)) {
        throw 'The candidate manifest contains a duplicate file path.'
    }
    $candidateFiles.Add([string]$entry.path, $entry)
}

$actualCandidateFiles = @(Get-ChildItem -LiteralPath $candidateRootPath -File -Recurse -Force |
    Where-Object { $_.FullName -cne $candidateManifestPath })
if ($actualCandidateFiles.Count -ne $candidateFiles.Count) {
    throw 'The candidate directory does not contain the exact manifested file set.'
}
foreach ($entry in $candidateFiles.GetEnumerator()) {
    $file = Resolve-ManifestFile `
        -Root $candidateRootPath `
        -RelativePath $entry.Key `
        -Context 'candidate file'
    if ($file.Length -ne [long]$entry.Value.length -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        [string]$entry.Value.sha256) {
        throw "Candidate file does not match its manifest: $($entry.Key)"
    }
}
$candidateInstaller = Resolve-ManifestFile `
    -Root $candidateRootPath `
    -RelativePath ([string]$candidateManifest.installerName) `
    -Context 'candidate installer'
if ((Get-FileHash -LiteralPath $candidateInstaller.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne
    [string]$candidateManifest.installerSha256) {
    throw 'The candidate installer does not match candidate installerSha256.'
}
$candidateManifestSha256 =
    (Get-FileHash -LiteralPath $candidateManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

$requiredEvidenceKinds = @(
    'clean-install-execution-attestation'
    'clean-install-log'
    'configuration-required-state'
    'target-isolation-attestation'
    'runtime-startup-tray-log'
    'runtime-child-restart-log'
    'tailscale-serve-ownership-snapshot'
    'qr-connection-redacted-log'
    'token-persistence-redacted-log'
    'normal-update-log'
    'v121-default-migration-log'
    'v121-custom-migration-log'
    'pre-boundary-rollback-log'
    'post-boundary-recovery-log'
    'shell-state-snapshot'
    'preserve-uninstall-log'
    'complete-uninstall-log'
    'ots-separate-administrator-log'
    'residue-before-snapshot'
    'residue-after-snapshot'
    'system-before-snapshot'
    'system-after-snapshot'
)
$scenarioContract = [ordered]@{
    'clean-install' = [ordered]@{
        Checks = @(
            'candidate-production-setup-executed',
            'clean-product-state-absent',
            'standard-user-hkcu-install',
            'prepare-to-install-succeeded',
            'setup-exit-zero',
            'broker-authenticated-pipe-roundtrip',
            'installer-log-error-free',
            'powershell-runtime-crash-free',
            'installed-version-exact',
            'install-transaction-finalized',
            'configuration-required-exact')
        EvidenceKinds = @(
            'clean-install-execution-attestation',
            'clean-install-log',
            'configuration-required-state')
    }
    'target-credential-isolation' = [ordered]@{
        Checks = @(
            'controller-only-orchestration',
            'github-runner-absent-on-target',
            'github-job-token-absent-on-target',
            'runner-credentials-absent-on-target',
            'tailnet-auth-key-absent-on-target',
            'controller-credentials-unreachable-from-target',
            'target-session-retired')
        EvidenceKinds = @('target-isolation-attestation')
    }
    'normal-runtime' = [ordered]@{
        Checks = @(
            'windows-login-startup',
            'tray-operation',
            'even-terminal-launch',
            'codex-app-server-launch',
            'child-abnormal-exit-restart',
            'tailscale-serve-created',
            'tailscale-serve-ownership-exact',
            'qr-connection',
            'reveal-timeout',
            'token-persistence',
            'normal-update',
            'credential-evidence-redacted')
        EvidenceKinds = @(
            'runtime-startup-tray-log',
            'runtime-child-restart-log',
            'tailscale-serve-ownership-snapshot',
            'qr-connection-redacted-log',
            'token-persistence-redacted-log',
            'normal-update-log')
    }
    'v1.2.1-default-migration' = [ordered]@{
        Checks = @('v1.2.1-detected', 'default-path-migrated', 'default-ports-migrated')
        EvidenceKinds = @('v121-default-migration-log')
    }
    'v1.2.1-custom-path-ports-migration' = [ordered]@{
        Checks = @('v1.2.1-detected', 'custom-path-migrated', 'custom-ports-migrated')
        EvidenceKinds = @('v121-custom-migration-log')
    }
    'pre-boundary-rollback' = [ordered]@{
        Checks = @('old-version-restored', 'external-state-restored', 'residue-baseline-restored')
        EvidenceKinds = @('pre-boundary-rollback-log')
    }
    'post-boundary-forward-recovery' = [ordered]@{
        Checks = @('new-version-active', 'cleanup-recovered', 'external-state-committed')
        EvidenceKinds = @('post-boundary-recovery-log')
    }
    'shell-registration' = [ordered]@{
        Checks = @('start-menu-exact', 'arp-exact', 'support-surface-exact')
        EvidenceKinds = @('shell-state-snapshot')
    }
    'preserve-uninstall' = [ordered]@{
        Checks = @('user-configuration-preserved', 'owned-system-state-removed', 'residue-baseline-exact')
        EvidenceKinds = @('preserve-uninstall-log')
    }
    'complete-uninstall' = [ordered]@{
        Checks = @('user-configuration-removed', 'owned-system-state-removed', 'residue-baseline-exact')
        EvidenceKinds = @('complete-uninstall-log')
    }
    'over-the-shoulder-separate-administrator' = [ordered]@{
        Checks = @(
            'standard-user-launch',
            'different-administrator-credential',
            'original-user-sid-preserved',
            'administrator-profile-not-adopted',
            'system-state-owned-for-original-user')
        EvidenceKinds = @('ots-separate-administrator-log')
    }
    'residue-system-snapshots' = [ordered]@{
        Checks = @(
            'pre-snapshot-captured',
            'post-snapshot-captured',
            'residue-diff-approved',
            'system-diff-approved')
        EvidenceKinds = @(
            'residue-before-snapshot',
            'residue-after-snapshot',
            'system-before-snapshot',
            'system-after-snapshot')
    }
}
$requiredCheckCount = 0
foreach ($contract in $scenarioContract.Values) {
    $requiredCheckCount += @($contract.Checks).Count
}

$reportPath = Join-Path $reportRootPath 'production-installer-audit-report.json'
$report = Read-StrictJsonFile `
    -Path $reportPath `
    -MaximumBytes $script:MaximumReportBytes `
    -Context 'production installer audit report'
Assert-ExactProperties `
    -InputObject $report `
    -Expected @(
        'auditKind',
        'candidate',
        'cleanInstall',
        'completedAtUtc',
        'controller',
        'evidence',
        'run',
        'scenarios',
        'schemaVersion',
        'startedAtUtc',
        'summary',
        'target') `
    -Context 'production installer audit report'
if ($report.schemaVersion -isnot [long] -or [long]$report.schemaVersion -ne 2 -or
    $report.auditKind -isnot [string] -or
    [string]$report.auditKind -cne 'evervigil-production-installer-e2e') {
    throw 'The production installer audit report kind or schema is invalid.'
}

Assert-ExactProperties `
    -InputObject $report.candidate `
    -Expected @(
        'installerName',
        'installerSha256',
        'manifestSha256',
        'sourceSha',
        'version') `
    -Context 'audit report candidate'
if ($report.candidate.sourceSha -isnot [string] -or
    [string]$report.candidate.sourceSha -cne $ExpectedSourceSha -or
    $report.candidate.version -isnot [string] -or
    [string]$report.candidate.version -cne $ExpectedVersion -or
    $report.candidate.installerName -isnot [string] -or
    [string]$report.candidate.installerName -cne [string]$candidateManifest.installerName -or
    $report.candidate.installerSha256 -isnot [string] -or
    [string]$report.candidate.installerSha256 -cne [string]$candidateManifest.installerSha256 -or
    $report.candidate.manifestSha256 -isnot [string] -or
    [string]$report.candidate.manifestSha256 -cne $candidateManifestSha256) {
    throw 'The audit report is not exactly bound to the candidate manifest and installer.'
}

Assert-CleanInstallContract `
    -CleanInstall $report.cleanInstall `
    -ExpectedInstallerName ([string]$candidateManifest.installerName) `
    -ExpectedInstallerSha256 ([string]$candidateManifest.installerSha256) `
    -ExpectedVersion $ExpectedVersion `
    -Context 'audit report cleanInstall'

Assert-ExactProperties `
    -InputObject $report.run `
    -Expected @('auditJob', 'workflowRunAttempt', 'workflowRunId') `
    -Context 'audit report run identity'
if ($report.run.workflowRunId -isnot [string] -or
    [string]$report.run.workflowRunId -cne $ExpectedWorkflowRunId -or
    $report.run.workflowRunAttempt -isnot [string] -or
    [string]$report.run.workflowRunAttempt -cne $ExpectedWorkflowRunAttempt -or
    $report.run.auditJob -isnot [string] -or
    [string]$report.run.auditJob -cne $ExpectedAuditJob) {
    throw 'The audit report does not belong to this exact workflow job attempt.'
}

Assert-ExactProperties `
    -InputObject $report.controller `
    -Expected @('actionsRunner', 'auditSessionId', 'hostFingerprintSha256') `
    -Context 'audit report controller'
Assert-TrueBoolean `
    -Value $report.controller.actionsRunner `
    -Context 'audit controller actionsRunner'
Assert-LowerSha256 `
    -Value $report.controller.hostFingerprintSha256 `
    -Context 'audit controller hostFingerprintSha256'
if ($report.controller.auditSessionId -isnot [string] -or
    [string]$report.controller.auditSessionId -cnotmatch
    '\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z') {
    throw 'The audit controller session ID is not a canonical lowercase UUID.'
}

Assert-ExactProperties `
    -InputObject $report.target `
    -Expected @(
        'architecture',
        'auditSessionId',
        'bootSessionId',
        'cleanSnapshot',
        'controllerCredentialsUnreachable',
        'cpuVendor',
        'dedicated',
        'ephemeral',
        'githubRunnerAbsent',
        'hostFingerprintSha256',
        'jobTokenAbsent',
        'osEdition',
        'physicalMachine',
        'runnerCredentialsAbsent',
        'runnerImageSha256',
        'tailnetAuthKeyAbsent',
        'targetSessionRetired') `
    -Context 'audit report target'
if ($report.target.cpuVendor -isnot [string] -or
    [string]$report.target.cpuVendor -cne $ExpectedCpuVendor -or
    $report.target.architecture -isnot [string] -or
    [string]$report.target.architecture -cne 'X64' -or
    $report.target.osEdition -isnot [string] -or
    [string]$report.target.osEdition -cne 'Windows 11 Pro') {
    throw 'The audit report does not identify the required Windows 11 Pro physical target.'
}
foreach ($propertyName in @(
        'dedicated',
        'ephemeral',
        'cleanSnapshot',
        'physicalMachine',
        'controllerCredentialsUnreachable',
        'githubRunnerAbsent',
        'jobTokenAbsent',
        'runnerCredentialsAbsent',
        'tailnetAuthKeyAbsent',
        'targetSessionRetired')) {
    Assert-TrueBoolean `
        -Value $report.target.$propertyName `
        -Context "audit target $propertyName"
}
foreach ($propertyName in @('hostFingerprintSha256', 'runnerImageSha256')) {
    Assert-LowerSha256 `
        -Value $report.target.$propertyName `
        -Context "audit target $propertyName"
}
foreach ($propertyName in @('auditSessionId', 'bootSessionId')) {
    if ($report.target.$propertyName -isnot [string] -or
        [string]$report.target.$propertyName -cnotmatch
        '\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z') {
        throw "audit target $propertyName must be a canonical lowercase UUID."
    }
}
if ([string]$report.controller.hostFingerprintSha256 -ceq
    [string]$report.target.hostFingerprintSha256 -or
    [string]$report.controller.auditSessionId -ceq
    [string]$report.target.auditSessionId) {
    throw 'The Actions controller and credential-free production target must be distinct systems.'
}

$timestampStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
    [Globalization.DateTimeStyles]::AdjustToUniversal
$started = [DateTimeOffset]::MinValue
$completed = [DateTimeOffset]::MinValue
if ($report.startedAtUtc -isnot [string] -or
    -not [DateTimeOffset]::TryParseExact(
        [string]$report.startedAtUtc,
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture,
        $timestampStyles,
        [ref]$started) -or
    $report.completedAtUtc -isnot [string] -or
    -not [DateTimeOffset]::TryParseExact(
        [string]$report.completedAtUtc,
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture,
        $timestampStyles,
        [ref]$completed) -or
    $completed -le $started -or
    ($completed - $started) -gt [TimeSpan]::FromHours(4)) {
    throw 'The audit report timestamps do not describe one bounded completed audit session.'
}

Assert-ExactProperties `
    -InputObject $report.summary `
    -Expected @('failedChecks', 'passed', 'passedChecks', 'skippedChecks', 'totalChecks') `
    -Context 'audit report summary'
Assert-TrueBoolean -Value $report.summary.passed -Context 'audit report summary passed'
foreach ($countProperty in @('failedChecks', 'passedChecks', 'skippedChecks', 'totalChecks')) {
    if ($report.summary.$countProperty -isnot [long]) {
        throw "audit report summary $countProperty must be a JSON integer."
    }
}
if ([long]$report.summary.totalChecks -ne $requiredCheckCount -or
    [long]$report.summary.passedChecks -ne $requiredCheckCount -or
    [long]$report.summary.failedChecks -ne 0 -or
    [long]$report.summary.skippedChecks -ne 0) {
    throw 'The production installer audit must pass every required check with zero failures and zero skips.'
}

$scenarios = @($report.scenarios)
if ($scenarios.Count -ne $scenarioContract.Count) {
    throw 'The audit report does not contain the exact required scenario count.'
}
$scenarioIds = @($scenarioContract.Keys)
for ($scenarioIndex = 0; $scenarioIndex -lt $scenarioIds.Count; $scenarioIndex++) {
    $scenarioId = $scenarioIds[$scenarioIndex]
    $scenario = $scenarios[$scenarioIndex]
    $contract = $scenarioContract[$scenarioId]
    Assert-ExactProperties `
        -InputObject $scenario `
        -Expected @('checks', 'evidenceKinds', 'id', 'status') `
        -Context "audit scenario $scenarioId"
    if ($scenario.id -isnot [string] -or [string]$scenario.id -cne $scenarioId -or
        $scenario.status -isnot [string] -or [string]$scenario.status -cne 'passed') {
        throw "Audit scenario must be present once and passed: $scenarioId"
    }
    Assert-ExactStringArray `
        -Value $scenario.evidenceKinds `
        -Expected @($contract.EvidenceKinds) `
        -Context "audit scenario evidence $scenarioId"

    $checks = @($scenario.checks)
    $expectedChecks = @($contract.Checks)
    if ($checks.Count -ne $expectedChecks.Count) {
        throw "Audit scenario has an incomplete check set: $scenarioId"
    }
    for ($checkIndex = 0; $checkIndex -lt $expectedChecks.Count; $checkIndex++) {
        $check = $checks[$checkIndex]
        Assert-ExactProperties `
            -InputObject $check `
            -Expected @('id', 'status') `
            -Context "audit scenario check $scenarioId"
        if ($check.id -isnot [string] -or
            [string]$check.id -cne $expectedChecks[$checkIndex] -or
            $check.status -isnot [string] -or
            [string]$check.status -cne 'passed') {
            throw "Audit scenario check was skipped, failed, missing, or reordered: $scenarioId"
        }
    }
}

$evidenceEntries = @($report.evidence)
if ($evidenceEntries.Count -ne $requiredEvidenceKinds.Count) {
    throw 'The audit report does not contain the exact required evidence set.'
}
$evidenceByPath = @{}
$evidenceFileByKind = @{}
$evidenceTextByKind = @{}
$evidenceTotalBytes = [long]0
for ($index = 0; $index -lt $requiredEvidenceKinds.Count; $index++) {
    $entry = $evidenceEntries[$index]
    $expectedKind = $requiredEvidenceKinds[$index]
    Assert-ExactProperties `
        -InputObject $entry `
        -Expected @('kind', 'length', 'path', 'sha256') `
        -Context "audit evidence $expectedKind"
    if ($entry.kind -isnot [string] -or [string]$entry.kind -cne $expectedKind -or
        $entry.path -isnot [string] -or
        [string]$entry.path -cnotmatch '\.(?:json|log|txt)\z' -or
        $entry.length -isnot [long] -or
        [long]$entry.length -le 0 -or
        [long]$entry.length -gt $script:MaximumEvidenceFileBytes) {
        throw "Audit evidence metadata is invalid: $expectedKind"
    }
    Assert-SafeRelativePath -Path ([string]$entry.path) -Context "audit evidence path $expectedKind"
    Assert-LowerSha256 -Value $entry.sha256 -Context "audit evidence sha256 $expectedKind"
    if ([string]$entry.path -ceq 'production-installer-audit-report.json' -or
        $evidenceByPath.ContainsKey([string]$entry.path)) {
        throw 'The audit evidence manifest contains a reserved or duplicate path.'
    }
    $file = Resolve-ManifestFile `
        -Root $reportRootPath `
        -RelativePath ([string]$entry.path) `
        -Context "audit evidence file $expectedKind"
    if ($file.Length -ne [long]$entry.length -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        [string]$entry.sha256) {
        throw "Audit evidence bytes do not match the report: $expectedKind"
    }
    $evidenceText = [IO.File]::ReadAllText($file.FullName, $script:Utf8NoBom)
    Assert-CredentialFreeEvidenceText `
        -Text $evidenceText `
        -Context "audit evidence $expectedKind"
    $evidenceByPath.Add([string]$entry.path, $entry)
    $evidenceFileByKind.Add($expectedKind, $file.FullName)
    $evidenceTextByKind.Add($expectedKind, $evidenceText)
    $evidenceTotalBytes += $file.Length
}
if ($evidenceTotalBytes -gt $script:MaximumEvidenceTotalBytes) {
    throw 'The audit evidence set exceeds the bounded total size.'
}
$actualReportFiles = @(Get-ChildItem -LiteralPath $reportRootPath -File -Recurse -Force |
    Where-Object { $_.FullName -cne $reportPath })
if ($actualReportFiles.Count -ne $evidenceByPath.Count) {
    throw 'The audit artifact contains an unlisted or missing evidence file.'
}
foreach ($file in $actualReportFiles) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The audit artifact contains a reparse-point file.'
    }
    $relative = [IO.Path]::GetRelativePath($reportRootPath, $file.FullName).Replace('\', '/')
    if (-not $evidenceByPath.ContainsKey($relative)) {
        throw "The audit artifact contains an unlisted file: $relative"
    }
}

$cleanInstallEvidence = Read-StrictJsonFile `
    -Path ([string]$evidenceFileByKind['clean-install-execution-attestation']) `
    -MaximumBytes $script:MaximumReportBytes `
    -Context 'clean install execution attestation evidence'
Assert-CleanInstallContract `
    -CleanInstall $cleanInstallEvidence `
    -ExpectedInstallerName ([string]$candidateManifest.installerName) `
    -ExpectedInstallerSha256 ([string]$candidateManifest.installerSha256) `
    -ExpectedVersion $ExpectedVersion `
    -Context 'clean install execution attestation evidence'
if ((ConvertTo-CanonicalCleanInstallJson -CleanInstall $cleanInstallEvidence) -cne
    (ConvertTo-CanonicalCleanInstallJson -CleanInstall $report.cleanInstall)) {
    throw 'The clean install evidence does not exactly match report.cleanInstall.'
}
Assert-ProductionSetupLog `
    -Text ([string]$evidenceTextByKind['clean-install-log']) `
    -ExpectedSetupPath ([string]$report.cleanInstall.setup.path) `
    -Context 'clean install production Setup log evidence'

"Production installer audit report passed: $ExpectedCpuVendor, " +
    "$requiredCheckCount checks, $($requiredEvidenceKinds.Count) evidence files, zero skips."
