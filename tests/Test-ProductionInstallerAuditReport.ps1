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
        Checks = @('clean-install', 'configuration-required-exact')
        EvidenceKinds = @('clean-install-log', 'configuration-required-state')
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
if ($report.schemaVersion -isnot [long] -or [long]$report.schemaVersion -ne 1 -or
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

"Production installer audit report passed: $ExpectedCpuVendor, " +
    "$requiredCheckCount checks, $($requiredEvidenceKinds.Count) evidence files, zero skips."
