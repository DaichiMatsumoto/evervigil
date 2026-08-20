[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolverPath = Join-Path $repositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$adapterPath = Join-Path $repositoryRoot 'scripts\Invoke-SystemMaintenance.ps1'
$installPath = Join-Path $repositoryRoot 'Install.ps1'
$completePath = Join-Path $repositoryRoot 'scripts\Complete-InstallTransaction.ps1'
$uninstallPath = Join-Path $repositoryRoot 'Uninstall.ps1'
$buildReleasePath = Join-Path $repositoryRoot 'scripts\Build-Release.ps1'
$productionPaths = @(
    $installPath
    $completePath
    $uninstallPath
    $resolverPath
    $adapterPath
    $buildReleasePath
)

foreach ($path in $productionPaths) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in '$path': $($errors.Message -join '; ')"
    }
}

. $resolverPath

if ((Get-EverVigilProtectedBrokerPath) -cne
    'C:\ProgramData\EverVigil\Broker\2.0.0\EverVigil.Broker.exe') {
    throw 'The canonical broker path is not the fixed ProgramData version root.'
}
if (Test-EverVigilProtectedBrokerInstallation `
        -BrokerPath (Join-Path $repositoryRoot 'EverVigil.Broker.exe')) {
    throw 'A user-writable repository broker was accepted as the protected broker.'
}

$versionLayoutRoot = Join-Path `
    $repositoryRoot `
    "artifacts\broker-version-layout-$PID-$([guid]::NewGuid().ToString('N'))"
$versionLayoutStateRoot = Join-Path $versionLayoutRoot 'State'
$versionLayoutCurrentRoot = Join-Path $versionLayoutRoot '2.0.0'
try {
    Assert-EverVigilProtectedBrokerVersionLayout `
        -BrokerRoot $versionLayoutRoot `
        -VersionRoot $versionLayoutCurrentRoot
    New-Item -ItemType Directory -Path $versionLayoutStateRoot -Force | Out-Null
    $missingCurrentRejected = $false
    try {
        Assert-EverVigilProtectedBrokerVersionLayout `
            -BrokerRoot $versionLayoutRoot `
            -VersionRoot $versionLayoutCurrentRoot
    } catch {
        $missingCurrentRejected = $true
    }
    if (-not $missingCurrentRejected) {
        throw 'Protected state without the current broker version was accepted.'
    }

    New-Item -ItemType Directory -Path $versionLayoutCurrentRoot -Force | Out-Null
    Assert-EverVigilProtectedBrokerVersionLayout `
        -BrokerRoot $versionLayoutRoot `
        -VersionRoot $versionLayoutCurrentRoot
    $obsoleteVersionRoot = Join-Path $versionLayoutRoot '1.9.9'
    New-Item -ItemType Directory -Path $obsoleteVersionRoot -Force | Out-Null
    $obsoleteVersionRejected = $false
    try {
        Assert-EverVigilProtectedBrokerVersionLayout `
            -BrokerRoot $versionLayoutRoot `
            -VersionRoot $versionLayoutCurrentRoot
    } catch {
        $obsoleteVersionRejected = $true
    }
    if (-not $obsoleteVersionRejected) {
        throw 'An obsolete protected broker version was accepted for in-place upgrade.'
    }
} finally {
    if (Test-Path -LiteralPath $versionLayoutRoot) {
        Remove-Item -LiteralPath $versionLayoutRoot -Recurse -Force
    }
}

$systemSid = [Security.Principal.SecurityIdentifier]::new(
    [Security.Principal.WellKnownSidType]::LocalSystemSid,
    $null)
$administratorsSid = [Security.Principal.SecurityIdentifier]::new(
    [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
    $null)
$usersSid = [Security.Principal.SecurityIdentifier]::new(
    [Security.Principal.WellKnownSidType]::BuiltinUsersSid,
    $null)
$worldSid = [Security.Principal.SecurityIdentifier]::new(
    [Security.Principal.WellKnownSidType]::WorldSid,
    $null)
$expectedDangerousRights =
    [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::CreateFiles -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::CreateDirectories -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
$usersReadAndExecute =
    [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
    [Security.AccessControl.FileSystemRights]::Synchronize
if ($script:EverVigilProtectedBrokerDangerousRights -ne
        $expectedDangerousRights -or
    ($usersReadAndExecute -band
        $script:EverVigilProtectedBrokerDangerousRights) -ne 0) {
    throw 'The protected-broker dangerous-rights mask rejects the required Users read/execute ACL.'
}

function New-TestProtectedBrokerSecurityDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Directory,
        [Parameter(Mandatory)]
        [Security.AccessControl.FileSystemRights]$UsersRights,
        [switch]$OmitSystemFullControl,
        [switch]$OmitAdministratorsFullControl,
        [switch]$AddUsersDeny,
        [switch]$AddUnknownPrincipal
    )

    $security = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $security.SetOwner($administratorsSid)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    if (-not $OmitSystemFullControl) {
        $security.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $systemSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow))
    }
    if (-not $OmitAdministratorsFullControl) {
        $security.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $administratorsSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow))
    }
    $security.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $usersSid,
            $UsersRights,
            $inheritance,
            $propagation,
            $allow))
    if ($AddUsersDeny) {
        $security.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $usersSid,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                $propagation,
                [Security.AccessControl.AccessControlType]::Deny))
    }
    if ($AddUnknownPrincipal) {
        $security.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $worldSid,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                $propagation,
                $allow))
    }
    return $security
}

function New-TestInheritedProtectedBrokerSecurityDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Directory
    )

    $security = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $administrativeAceFlags = if ($Directory) { 'OICI' } else { '' }
    $inheritedUsersAceFlags = if ($Directory) { 'OICIID' } else { 'ID' }
    $sddl = ('O:BAG:BAD:P' +
        "(A;$administrativeAceFlags;FA;;;SY)" +
        "(A;$administrativeAceFlags;FA;;;BA)" +
        "(A;$inheritedUsersAceFlags;0x1200a9;;;BU)")
    $security.SetSecurityDescriptorSddlForm($sddl)
    return $security
}

$dangerousRightCases = @(
    [pscustomobject]@{
        Name = 'WriteData/CreateFiles'
        Right = [Security.AccessControl.FileSystemRights]::WriteData
    }
    [pscustomobject]@{
        Name = 'AppendData/CreateDirectories'
        Right = [Security.AccessControl.FileSystemRights]::AppendData
    }
    [pscustomobject]@{
        Name = 'WriteExtendedAttributes'
        Right = [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
    }
    [pscustomobject]@{
        Name = 'DeleteSubdirectoriesAndFiles'
        Right = [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
    }
    [pscustomobject]@{
        Name = 'WriteAttributes'
        Right = [Security.AccessControl.FileSystemRights]::WriteAttributes
    }
    [pscustomobject]@{
        Name = 'Delete'
        Right = [Security.AccessControl.FileSystemRights]::Delete
    }
    [pscustomobject]@{
        Name = 'ChangePermissions'
        Right = [Security.AccessControl.FileSystemRights]::ChangePermissions
    }
    [pscustomobject]@{
        Name = 'TakeOwnership'
        Right = [Security.AccessControl.FileSystemRights]::TakeOwnership
    }
)

foreach ($directory in @($false, $true)) {
    $descriptorKind = if ($directory) { 'directory' } else { 'file' }
    $validSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute
    if (-not (Test-EverVigilProtectedBrokerSecurityDescriptor `
            -SecurityDescriptor $validSecurity)) {
        throw "The production ACL validator rejected a valid $descriptorKind security descriptor."
    }

    $systemOwnedSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute
    $systemOwnedSecurity.SetOwner($systemSid)
    if (-not (Test-EverVigilProtectedBrokerSecurityDescriptor `
            -SecurityDescriptor $systemOwnedSecurity)) {
        throw "The production ACL validator rejected a SYSTEM-owned $descriptorKind security descriptor."
    }

    foreach ($dangerousRightCase in $dangerousRightCases) {
        $dangerousSecurity = New-TestProtectedBrokerSecurityDescriptor `
            -Directory $directory `
            -UsersRights ($usersReadAndExecute -bor $dangerousRightCase.Right)
        if (Test-EverVigilProtectedBrokerSecurityDescriptor `
                -SecurityDescriptor $dangerousSecurity) {
            throw "The production ACL validator accepted $($dangerousRightCase.Name) on a Users $descriptorKind ACE."
        }
    }

    $missingSystemSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute `
        -OmitSystemFullControl
    $missingAdministratorsSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute `
        -OmitAdministratorsFullControl
    $denySecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute `
        -AddUsersDeny
    $unknownPrincipalSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute `
        -AddUnknownPrincipal
    $unprotectedSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute
    $unprotectedSecurity.SetAccessRuleProtection($false, $false)
    $inheritedSecurity = New-TestInheritedProtectedBrokerSecurityDescriptor `
        -Directory $directory
    $unexpectedOwnerSecurity = New-TestProtectedBrokerSecurityDescriptor `
        -Directory $directory `
        -UsersRights $usersReadAndExecute
    $unexpectedOwnerSecurity.SetOwner($usersSid)
    foreach ($invalidSecurity in @(
            $missingSystemSecurity
            $missingAdministratorsSecurity
            $denySecurity
            $unknownPrincipalSecurity
            $unprotectedSecurity
            $inheritedSecurity
            $unexpectedOwnerSecurity
        )) {
        if (Test-EverVigilProtectedBrokerSecurityDescriptor `
                -SecurityDescriptor $invalidSecurity) {
            throw "The production ACL validator accepted an invalid $descriptorKind security descriptor."
        }
    }
}

$installedProtectedBrokerPath = Get-EverVigilProtectedBrokerPath
if ((Test-Path -LiteralPath $installedProtectedBrokerPath -PathType Leaf) -and
    -not (Test-EverVigilProtectedBrokerInstallation `
        -BrokerPath $installedProtectedBrokerPath)) {
    throw 'The actual protected broker installed by Setup was rejected by the PowerShell ACL/receipt validator.'
}

$receiptSha256 = [string]::new([char]'a', 64)
$validReceipt = @"
{
  "length": 12345,
  "schemaVersion": 1,
  "sha256": "$receiptSha256",
  "version": "2.0.0",
  "fileName": "EverVigil.Broker.exe"
}
"@
if (-not (Test-EverVigilProtectedBrokerReceipt `
        -Json $validReceipt `
        -ExecutableLength 12345 `
        -ExecutableSha256 $receiptSha256)) {
    throw 'A valid protected broker installation receipt was rejected.'
}
$invalidReceipts = @(
    $validReceipt.Replace('"schemaVersion"', '"SchemaVersion"')
    $validReceipt.Replace('"length": 12345', '"length": "12345"')
    $validReceipt.Replace('"schemaVersion": 1', '"schemaVersion": 1.0')
    $validReceipt.Replace('"version": "2.0.0"', '"version": "2.0.1"')
    $validReceipt.Replace($receiptSha256, $receiptSha256.ToUpperInvariant())
    $validReceipt.Replace(
        '"fileName": "EverVigil.Broker.exe"',
        '"fileName": "EverVigil.Broker.exe", "unexpected": 1')
    $validReceipt.Replace(
        '"fileName": "EverVigil.Broker.exe"',
        '"fileName": "EverVigil.Broker.exe", "length": 12345')
    $validReceipt.Replace(
        '"fileName": "EverVigil.Broker.exe"',
        '"fileName": "EverVigil.Broker.exe",')
)
foreach ($invalidReceipt in $invalidReceipts) {
    if (Test-EverVigilProtectedBrokerReceipt `
            -Json $invalidReceipt `
            -ExecutableLength 12345 `
            -ExecutableSha256 $receiptSha256) {
        throw "An invalid protected broker receipt was accepted: $invalidReceipt"
    }
}
if (Test-EverVigilProtectedBrokerReceipt `
        -Json $validReceipt `
        -ExecutableLength 12346 `
        -ExecutableSha256 $receiptSha256) {
    throw 'A protected broker receipt with a mismatched executable length was accepted.'
}
$differentSha256 = [string]::new([char]'b', 64)
if (Test-EverVigilProtectedBrokerReceipt `
        -Json $validReceipt `
        -ExecutableLength 12345 `
        -ExecutableSha256 $differentSha256) {
    throw 'A protected broker receipt with a mismatched executable hash was accepted.'
}

$originalRetirementPathsFunction = (Get-Command `
        Get-EverVigilProtectedBrokerRetirementPaths `
        -CommandType Function).ScriptBlock
$originalRetirementAclFunction = (Get-Command `
        Test-EverVigilProtectedBrokerRetirementAcl `
        -CommandType Function).ScriptBlock
$retirementReceiptTestRoot = Join-Path `
    $repositoryRoot `
    "artifacts\retirement-receipt-$PID-$([guid]::NewGuid().ToString('N'))"
$retirementReceiptTestPath = Join-Path $retirementReceiptTestRoot 'retirement.json'
try {
    New-Item -ItemType Directory -Path $retirementReceiptTestRoot -Force | Out-Null
    function Get-EverVigilProtectedBrokerRetirementPaths {
        [pscustomobject]@{
            RetirementReceiptPath = $retirementReceiptTestPath
        }
    }
    function Test-EverVigilProtectedBrokerRetirementAcl {
        param([string]$Path, [string]$OwnerSid, [switch]$Directory)
        return $Path -ceq $retirementReceiptTestPath -and -not $Directory
    }
    $receiptOwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $retirementTransactionId = [guid]::NewGuid()
    $retirementSha256 = [string]::new([char]'c', 64)
    $validRetirementReceipt = [ordered]@{
        schemaVersion = 1
        transactionId = $retirementTransactionId.ToString('D')
        ownerSid = $receiptOwnerSid
        version = '2.0.0'
        canonicalFileName = 'EverVigil.Broker.exe'
        length = 12345
        sha256 = $retirementSha256
        state = 'RetirementPrepared'
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        $retirementReceiptTestPath,
        $validRetirementReceipt,
        [Text.UTF8Encoding]::new($false))
    $parsedRetirementReceipt = Read-EverVigilProtectedBrokerRetirementReceipt `
        -Path $retirementReceiptTestPath `
        -OwnerSid $receiptOwnerSid
    if ([string]$parsedRetirementReceipt.transactionId -cne
        $retirementTransactionId.ToString('D')) {
        throw 'A valid protected broker retirement receipt changed during parsing.'
    }
    $invalidRetirementReceipts = @(
        $validRetirementReceipt.Replace('"schemaVersion"', '"SchemaVersion"')
        $validRetirementReceipt.Replace('"length": 12345', '"length": "12345"')
        $validRetirementReceipt.Replace($retirementSha256, $retirementSha256.ToUpperInvariant())
        $validRetirementReceipt.Replace($receiptOwnerSid, 'S-1-5-18')
        $validRetirementReceipt.Replace(
            '"state": "RetirementPrepared"',
            '"state": "RetirementPrepared", "unexpected": true')
        $validRetirementReceipt.Replace(
            '"state": "RetirementPrepared"',
            '"state": "RetirementPrepared", "length": 12345')
        $validRetirementReceipt.Replace(
            '"canonicalFileName": "EverVigil.Broker.exe"',
            '"canonicalFileName": "EverVigil.Broker.exe", "retiredFileName": "EverVigil.Broker.retired.exe"')
    )
    foreach ($invalidRetirementReceipt in $invalidRetirementReceipts) {
        [IO.File]::WriteAllText(
            $retirementReceiptTestPath,
            $invalidRetirementReceipt,
            [Text.UTF8Encoding]::new($false))
        $invalidRetirementReceiptRejected = $false
        try {
            [void](Read-EverVigilProtectedBrokerRetirementReceipt `
                    -Path $retirementReceiptTestPath `
                    -OwnerSid $receiptOwnerSid)
        } catch {
            $invalidRetirementReceiptRejected = $true
        }
        if (-not $invalidRetirementReceiptRejected) {
            throw "An invalid protected broker retirement receipt was accepted: $invalidRetirementReceipt"
        }
    }
} finally {
    Set-Item `
        -LiteralPath Function:\Get-EverVigilProtectedBrokerRetirementPaths `
        -Value $originalRetirementPathsFunction
    Set-Item `
        -LiteralPath Function:\Test-EverVigilProtectedBrokerRetirementAcl `
        -Value $originalRetirementAclFunction
    if (Test-Path -LiteralPath $retirementReceiptTestRoot) {
        Remove-Item `
            -LiteralPath $retirementReceiptTestRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# A response-loss retry can resume after all retirement files were removed but
# before the empty version directory was deleted. That directory remains a
# known child until the child-to-parent directory deletion loop reaches it.
$originalRetirementPathsFunction = (Get-Command `
        Get-EverVigilProtectedBrokerRetirementPaths `
        -CommandType Function).ScriptBlock
$originalRetirementAclFunction = (Get-Command `
        Test-EverVigilProtectedBrokerRetirementAcl `
        -CommandType Function).ScriptBlock
$retirementResumeProductRoot = Join-Path `
    $repositoryRoot `
    "artifacts\retirement-resume-$PID-$([guid]::NewGuid().ToString('N'))"
$retirementResumeBrokerRoot = Join-Path $retirementResumeProductRoot 'Broker'
$retirementResumeStateRoot = Join-Path $retirementResumeBrokerRoot 'State'
$retirementResumeVersionRoot = Join-Path $retirementResumeBrokerRoot '2.0.0'
$retirementResumeCanonicalPath = Join-Path `
    $retirementResumeVersionRoot `
    'EverVigil.Broker.exe'
$retirementResumeInstallationReceiptPath = Join-Path `
    $retirementResumeVersionRoot `
    'installation.json'
$retirementResumeReceiptPath = Join-Path `
    $retirementResumeVersionRoot `
    'retirement.json'
$retirementResumeDirectories = @(
    $retirementResumeProductRoot
    $retirementResumeBrokerRoot
    $retirementResumeStateRoot
    $retirementResumeVersionRoot
)
try {
    New-Item -ItemType Directory -Path $retirementResumeStateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $retirementResumeVersionRoot -Force | Out-Null
    function Get-EverVigilProtectedBrokerRetirementPaths {
        [pscustomobject]@{
            ProductRoot = $retirementResumeProductRoot
            BrokerRoot = $retirementResumeBrokerRoot
            StateRoot = $retirementResumeStateRoot
            VersionRoot = $retirementResumeVersionRoot
            CanonicalPath = $retirementResumeCanonicalPath
            InstallationReceiptPath = $retirementResumeInstallationReceiptPath
            RetirementReceiptPath = $retirementResumeReceiptPath
        }
    }
    function Test-EverVigilProtectedBrokerRetirementAcl {
        param([string]$Path, [string]$OwnerSid, [switch]$Directory)
        return $Directory -and $Path -cin $retirementResumeDirectories
    }
    Complete-EverVigilProtectedBrokerRetirementFromReceipt `
        -ExpectedOwnerSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
        -ExpectedTransactionId ([guid]::NewGuid())
    if (Test-Path -LiteralPath $retirementResumeProductRoot) {
        throw 'Protected broker retirement did not remove its empty version tree.'
    }
} finally {
    Set-Item `
        -LiteralPath Function:\Get-EverVigilProtectedBrokerRetirementPaths `
        -Value $originalRetirementPathsFunction
    Set-Item `
        -LiteralPath Function:\Test-EverVigilProtectedBrokerRetirementAcl `
        -Value $originalRetirementAclFunction
    if (Test-Path -LiteralPath $retirementResumeProductRoot) {
        Remove-Item `
            -LiteralPath $retirementResumeProductRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

$transactionId = [guid]::NewGuid()
$validResponse = [pscustomobject]@{
    schemaVersion = [int64]1
    transactionId = $transactionId.ToString('D')
    success = $true
    disposition = 'Completed'
    errorCode = 'None'
    message = 'ok'
}
Assert-EverVigilBrokerResponse `
    -Response $validResponse `
    -TransactionId $transactionId
$retirementResponse = $validResponse.PSObject.Copy()
$retirementResponse.disposition = 'RetirementRequired'
Assert-EverVigilBrokerResponse `
    -Response $retirementResponse `
    -TransactionId $transactionId

$stringBooleanResponse = $validResponse.PSObject.Copy()
$stringBooleanResponse.success = 'false'
$stringBooleanRejected = $false
try {
    Assert-EverVigilBrokerResponse `
        -Response $stringBooleanResponse `
        -TransactionId $transactionId
} catch {
    $stringBooleanRejected = $_.Exception.Message -match 'malformed response'
}
if (-not $stringBooleanRejected) {
    throw 'A string-valued broker success property was accepted as a JSON boolean.'
}

$unknownPropertyResponse = $validResponse.PSObject.Copy()
$unknownPropertyResponse | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
$unknownPropertyRejected = $false
try {
    Assert-EverVigilBrokerResponse `
        -Response $unknownPropertyResponse `
        -TransactionId $transactionId
} catch {
    $unknownPropertyRejected = $_.Exception.Message -match 'malformed response'
}
if (-not $unknownPropertyRejected) {
    throw 'A broker response with an unmapped property was accepted.'
}

$payload = [Text.UTF8Encoding]::new($false).GetBytes('{"ok":true}')
$length = [BitConverter]::GetBytes([uint32]$payload.Length)
if (-not [BitConverter]::IsLittleEndian) {
    [Array]::Reverse($length)
}
$framed = [byte[]]::new($length.Length + $payload.Length)
[Array]::Copy($length, 0, $framed, 0, $length.Length)
[Array]::Copy($payload, 0, $framed, $length.Length, $payload.Length)
$stream = [IO.MemoryStream]::new($framed, $false)
try {
    $roundTrip = Read-EverVigilPipeFrame -Stream $stream
    if ([BitConverter]::ToString($payload) -cne
        [BitConverter]::ToString($roundTrip)) {
        throw 'The broker frame reader changed the payload.'
    }
} finally {
    $stream.Dispose()
}

$oversizedLength = [BitConverter]::GetBytes([uint32]65537)
if (-not [BitConverter]::IsLittleEndian) {
    [Array]::Reverse($oversizedLength)
}
$stream = [IO.MemoryStream]::new($oversizedLength, $false)
$oversizedRejected = $false
try {
    [void](Read-EverVigilPipeFrame -Stream $stream)
} catch {
    $oversizedRejected = $_.Exception.Message -match 'length is invalid'
} finally {
    $stream.Dispose()
}
if (-not $oversizedRejected) {
    throw 'An oversized broker response frame was accepted.'
}

# PowerShell 7.6 emits VoidTaskResult from non-generic Task.GetResult() calls.
# The broker client must suppress those implementation values or a valid JSON
# response becomes an object array and strict disposition validation fails.
$brokerWriteProbe = [IO.MemoryStream]::new()
try {
    $firstBrokerWrite = [byte[]](0x01, 0x02)
    $secondBrokerWrite = [byte[]](0x03, 0x04)
    $brokerWriteOutput = @(& {
            [void]($brokerWriteProbe.WriteAsync(
                    $firstBrokerWrite,
                    0,
                    $firstBrokerWrite.Length,
                    [Threading.CancellationToken]::None).GetAwaiter().GetResult())
            [void]($brokerWriteProbe.WriteAsync(
                    $secondBrokerWrite,
                    0,
                    $secondBrokerWrite.Length,
                    [Threading.CancellationToken]::None).GetAwaiter().GetResult())
            [void]($brokerWriteProbe.FlushAsync(
                    [Threading.CancellationToken]::None).GetAwaiter().GetResult())
        })
    $brokerWriteBytes = $brokerWriteProbe.ToArray()
} finally {
    $brokerWriteProbe.Dispose()
}
if ($brokerWriteOutput.Count -ne 0 -or
    [Convert]::ToHexString($brokerWriteBytes) -cne '01020304') {
    throw 'Broker async writes leaked task implementation values or changed bytes.'
}

$contents = @{}
foreach ($path in $productionPaths) {
    $contents[$path] = Get-Content -LiteralPath $path -Raw
}
$resolverContent = $contents[$resolverPath]
$adapterContent = $contents[$adapterPath]
$buildReleaseContent = $contents[$buildReleasePath]
$callerContent = @(
    $contents[$installPath]
    $contents[$completePath]
    $contents[$uninstallPath]
) -join "`n"
$allContent = @($contents.Values) -join "`n"

$installTokens = $null
$installParseErrors = $null
$installAst = [Management.Automation.Language.Parser]::ParseFile(
    $installPath,
    [ref]$installTokens,
    [ref]$installParseErrors)
$tokenHealthFunction = $installAst.Find(
    {
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Test-ExistingSupervisorHealth'
    },
    $true)
if ($null -eq $tokenHealthFunction) {
    throw 'The installer loopback token-health function is missing.'
}
$tokenHealthContent = $tokenHealthFunction.Extent.Text
foreach ($loopbackTokenHealthGuard in @(
        '"http://127.0.0.1:$BackendPort/api/sessions?provider=codex&limit=1"'
        '$handler.AllowAutoRedirect = $false'
        '$handler.UseProxy = $false'
        'AuthenticationHeaderValue]::new('
        "'Bearer'"
    )) {
    if (-not $tokenHealthContent.Contains(
            $loopbackTokenHealthGuard,
            [StringComparison]::Ordinal)) {
        throw "The installer loopback token-health guard is missing: $loopbackTokenHealthGuard"
    }
}
foreach ($attackerControlledTokenDestination in @(
        'SettingsPath'
        'PublicPort'
        'publicHost'
        'UriBuilder'
        'Dns'
        '.ts.net'
        'tailscale'
    )) {
    if ($tokenHealthContent.Contains(
            $attackerControlledTokenDestination,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The installer token-health path still accepts an attacker-controlled destination: $attackerControlledTokenDestination"
    }
}
if ([regex]::Matches(
        $tokenHealthContent,
        '(?i)https?://').Count -ne 1 -or
    -not $contents[$installPath].Contains(
        '$systemConfigurationCanBePreserved = $false',
        [StringComparison]::Ordinal) -or
    -not $contents[$installPath].Contains(
        'whose protected ledger is the sole ownership authority.',
        [StringComparison]::Ordinal)) {
    throw 'Installer health must have exactly one loopback HTTP destination and defer route/firewall ownership to the protected broker.'
}

$unsafeTokenHealthFixtures = @(
    $tokenHealthContent.Replace('127.0.0.1', 'attacker.invalid')
    $tokenHealthContent.Replace('$handler.AllowAutoRedirect = $false', '$handler.AllowAutoRedirect = $true')
    ($tokenHealthContent + "`n`$settings.publicHost`n")
    ($tokenHealthContent + "`n[Net.Dns]::GetHostAddresses('attacker.invalid')`n")
)
foreach ($unsafeTokenHealthFixture in $unsafeTokenHealthFixtures) {
    $isFixedLoopbackOnly =
        $unsafeTokenHealthFixture.Contains(
            '"http://127.0.0.1:$BackendPort/api/sessions?provider=codex&limit=1"',
            [StringComparison]::Ordinal) -and
        $unsafeTokenHealthFixture.Contains(
            '$handler.AllowAutoRedirect = $false',
            [StringComparison]::Ordinal) -and
        -not [regex]::IsMatch(
            $unsafeTokenHealthFixture,
            '(?i)publicHost|UriBuilder|Dns|https?://(?!127\.0\.0\.1:)')
    if ($isFixedLoopbackOnly) {
        throw 'An attacker host/IP/redirect/DNS token-health fixture was not rejected.'
    }
}

if ($null -eq ('EverVigilInstallerHealthRedirectFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class EverVigilInstallerHealthRedirectFixture : IDisposable
{
    private readonly TcpListener source = new TcpListener(IPAddress.Loopback, 0);
    private readonly TcpListener sink = new TcpListener(IPAddress.Loopback, 0);
    private Task sourceTask;
    private Task sinkTask;
    private int sourceConnections;
    private int sinkConnections;

    public int SourcePort { get; private set; }
    public int SourceConnections { get { return Volatile.Read(ref sourceConnections); } }
    public int SinkConnections { get { return Volatile.Read(ref sinkConnections); } }

    public void Start()
    {
        source.Server.ExclusiveAddressUse = true;
        sink.Server.ExclusiveAddressUse = true;
        source.Start();
        sink.Start();
        SourcePort = ((IPEndPoint)source.LocalEndpoint).Port;
        var sinkPort = ((IPEndPoint)sink.LocalEndpoint).Port;
        sourceTask = ServeSourceAsync(sinkPort);
        sinkTask = ServeSinkAsync();
    }

    public bool WaitForSource(int milliseconds)
    {
        try { return sourceTask != null && sourceTask.Wait(milliseconds); }
        catch (AggregateException) { return false; }
    }

    private async Task ServeSourceAsync(int sinkPort)
    {
        try
        {
            using (var client = await source.AcceptTcpClientAsync().ConfigureAwait(false))
            {
                Interlocked.Increment(ref sourceConnections);
                var response = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 302 Found\r\n" +
                    "Location: http://127.0.0.1:" + sinkPort + "/credential-sink\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n");
                var stream = client.GetStream();
                await stream.WriteAsync(response, 0, response.Length).ConfigureAwait(false);
                await stream.FlushAsync().ConfigureAwait(false);
            }
        }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    private async Task ServeSinkAsync()
    {
        try
        {
            using (var client = await sink.AcceptTcpClientAsync().ConfigureAwait(false))
            {
                Interlocked.Increment(ref sinkConnections);
                var body = Encoding.UTF8.GetBytes("{\"sessions\":[]}");
                var header = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                    "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
                var stream = client.GetStream();
                await stream.WriteAsync(header, 0, header.Length).ConfigureAwait(false);
                await stream.WriteAsync(body, 0, body.Length).ConfigureAwait(false);
                await stream.FlushAsync().ConfigureAwait(false);
            }
        }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    public void Dispose()
    {
        source.Stop();
        sink.Stop();
        if (sourceTask != null) { try { sourceTask.Wait(1000); } catch { } }
        if (sinkTask != null) { try { sinkTask.Wait(1000); } catch { } }
    }
}
'@
}

. ([scriptblock]::Create($tokenHealthContent))
$redirectTestRoot = Join-Path `
    $repositoryRoot `
    "artifacts\installer-token-health-$PID-$([guid]::NewGuid().ToString('N'))"
$redirectFixture = $null
try {
    New-Item -ItemType Directory -Path $redirectTestRoot -Force | Out-Null
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
    $redirectEntropyContext = 'EverVigil.Test.RedirectIsolation'
    $redirectEntropy = [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($redirectEntropyContext))
    $redirectToken = ('0011223344556677' + '8899aabbccddeeff')
    $protectedRedirectToken = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::ASCII.GetBytes($redirectToken),
        $redirectEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $redirectTokenPath = Join-Path $redirectTestRoot 'token.dat'
    [IO.File]::WriteAllBytes($redirectTokenPath, $protectedRedirectToken)

    $redirectFixture = [EverVigilInstallerHealthRedirectFixture]::new()
    $redirectFixture.Start()
    $redirectResult = Test-ExistingSupervisorHealth `
        -TokenPath $redirectTokenPath `
        -EntropyContext $redirectEntropyContext `
        -BackendPort $redirectFixture.SourcePort
    if ($redirectResult -or
        -not $redirectFixture.WaitForSource(5000) -or
        $redirectFixture.SourceConnections -ne 1) {
        throw 'The installer token-health redirect fixture did not reach the fixed loopback source exactly once.'
    }
    [Threading.Thread]::Sleep(500)
    if ($redirectFixture.SinkConnections -ne 0) {
        throw 'The installer token-health request followed a redirect and exposed its credential to a second endpoint.'
    }
} finally {
    if ($redirectFixture) {
        $redirectFixture.Dispose()
    }
    if (Test-Path -LiteralPath $redirectTestRoot) {
        Remove-Item -LiteralPath $redirectTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([regex]::Matches($allContent, '(?im)-Verb\s+RunAs\b').Count -ne 1 -or
    [regex]::Matches($resolverContent, '(?im)-Verb\s+RunAs\b').Count -ne 1) {
    throw 'Exactly one RunAs call is allowed, inside the shared protected-broker client.'
}
foreach ($forbiddenElevation in @(
        'ApplicationExecutablePath'
        'Invoke-ElevatedSystemMaintenance'
        '-FilePath $PowerShellPath'
        "'-File',"
        'pwsh.exe --configure-system'
    )) {
    if ($allContent.Contains($forbiddenElevation, [StringComparison]::Ordinal)) {
        throw "A user-writable PowerShell/application elevation path remains: $forbiddenElevation"
    }
}
foreach ($privilegedPowerShellMutation in @(
        'Remove-NetFirewallRule'
        'New-NetFirewallRule'
        'Unregister-ScheduledTask'
        'Register-ScheduledTask'
        "@('serve', '--yes'"
        "@('serve', 'reset'"
    )) {
    if ($allContent.Contains(
            $privilegedPowerShellMutation,
            [StringComparison]::Ordinal)) {
        throw "A privileged mutation remains in PowerShell: $privilegedPowerShellMutation"
    }
}
foreach ($brokerGuard in @(
        "'EverVigil\Broker\2.0.0\EverVigil.Broker.exe'"
        "'broker\EverVigil.Broker.exe'"
        'Test-EverVigilProtectedBrokerInstallation'
        'Test-EverVigilProtectedBrokerSecurityDescriptor'
        'Test-EverVigilProtectedBrokerAcl'
        'Test-EverVigilProtectedBrokerReceipt'
        'Test-EverVigilProtectedBrokerRetirementAcl'
        'Read-EverVigilProtectedBrokerRetirementReceipt'
        "'RetirementRequired'"
        "[string]`$state -cne 'RetirementPrepared'"
        "Join-Path `$versionRoot 'installation.json'"
        '[IO.File]::ReadAllBytes($receiptPath)'
        '[Text.UTF8Encoding]::new('
        '(Get-FileHash `'
        '-Algorithm SHA256'
        '$brokerInfo.Length'
        "[string]`$version -cne '2.0.0'"
        "[string]`$fileName -cne 'EverVigil.Broker.exe'"
        '[string]$receiptSha256 -cnotmatch ''\A[0-9a-f]{64}\z'''
        '[IO.FileAttributes]::ReparsePoint'
        '$security.AreAccessRulesProtected'
        '[Security.Principal.WellKnownSidType]::LocalSystemSid'
        '[Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid'
        '[Security.AccessControl.FileSystemRights]::WriteData'
        '[Security.AccessControl.FileSystemRights]::CreateFiles'
        '[Security.AccessControl.FileSystemRights]::AppendData'
        '[Security.AccessControl.FileSystemRights]::CreateDirectories'
        '[Security.AccessControl.FileSystemRights]::WriteExtendedAttributes'
        '[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles'
        '[Security.AccessControl.FileSystemRights]::WriteAttributes'
        '[Security.AccessControl.FileSystemRights]::Delete'
        '[Security.AccessControl.FileSystemRights]::ChangePermissions'
        '[Security.AccessControl.FileSystemRights]::TakeOwnership'
        '[Security.Cryptography.RandomNumberGenerator]::Create()'
        '$random.GetBytes($nonceBytes)'
        '[BitConverter]::ToString($nonceBytes).Replace('
        '$nonceBytes = [byte[]]::new(32)'
        'EverVigil.Broker.$([guid]::NewGuid().ToString(''N''))'
        "'--client-pid', [string]`$PID"
        "'--pipe', `$pipeName"
        "'--nonce', `$nonce"
        "'--transaction-id', `$TransactionId.ToString('D')"
        'migrateLegacySystemState = [bool]$MigrateV121SystemState'
        'return $bootstrapResponse'
        'public sealed class BootstrapPathLock : IDisposable'
        'FileFlagOpenReparsePoint'
        'FileFlagBackupSemantics'
        'GetFileInformationByHandleEx('
        'information.NumberOfLinks != 1'
        'FileShareRead,'
        '$bootstrapPathLock = [EverVigil.BootstrapPathLock]::Acquire('
        '$bootstrapPathLock.ExecutableLength -le 0'
        '$bootstrapPathLock.Validate()'
        '$bootstrapPathLock.Dispose()'
        'Invoke-ProtectedBrokerOnce -ExecutablePath $protectedBrokerPath'
        '[IO.Pipes.PipeTransmissionMode]::Byte'
        '$pipe.Connect(250)'
        '[Threading.CancellationTokenSource]::new('
        '[TimeSpan]::FromSeconds(90)'
        '$pipe.WriteAsync('
        '$pipe.FlushAsync('
        '[BitConverter]::GetBytes([uint32]$requestBytes.Length)'
        'Read-EverVigilPipeFrame'
        'Assert-EverVigilBrokerResponse'
    )) {
    if (-not $resolverContent.Contains($brokerGuard, [StringComparison]::Ordinal)) {
        throw "A protected-broker client guard is missing: $brokerGuard"
    }
}
$suppressedBrokerWriteAwaitCount = [regex]::Matches(
    $resolverContent,
    '\[void\]\(\s*\$pipe\.WriteAsync\(').Count
$suppressedBrokerFlushAwaitCount = [regex]::Matches(
    $resolverContent,
    '\[void\]\(\s*\$pipe\.FlushAsync\(').Count
if ($suppressedBrokerWriteAwaitCount -ne 2 -or
    $suppressedBrokerFlushAwaitCount -ne 1) {
    throw 'Every broker async write/flush await must suppress VoidTaskResult output.'
}
if (-not $resolverContent.Contains('-FilePath $ExecutablePath', [StringComparison]::Ordinal) -or
    $resolverContent.Contains('-FilePath $InstalledExecutable', [StringComparison]::Ordinal) -or
    $resolverContent.Contains('-FilePath $PowerShellPath', [StringComparison]::Ordinal)) {
    throw 'RunAs must launch only the fixed bootstrap/canonical broker executable.'
}
$bootstrapLockIndex = $resolverContent.IndexOf(
    '$bootstrapPathLock = [EverVigil.BootstrapPathLock]::Acquire(',
    [StringComparison]::Ordinal)
$bootstrapLaunchIndex = $resolverContent.IndexOf(
    '$bootstrapResponse = Invoke-ProtectedBrokerOnce',
    $bootstrapLockIndex,
    [StringComparison]::Ordinal)
$bootstrapValidationIndex = $resolverContent.IndexOf(
    'if (-not (Test-EverVigilProtectedBrokerInstallation',
    $bootstrapLaunchIndex,
    [StringComparison]::Ordinal)
$bootstrapUnlockIndex = $resolverContent.IndexOf(
    '$bootstrapPathLock.Dispose()',
    $bootstrapValidationIndex,
    [StringComparison]::Ordinal)
if ($bootstrapLockIndex -lt 0 -or
    $bootstrapLaunchIndex -le $bootstrapLockIndex -or
    $bootstrapValidationIndex -le $bootstrapLaunchIndex -or
    $bootstrapUnlockIndex -le $bootstrapValidationIndex) {
    throw 'The package broker component lock must span UAC bootstrap through canonical receipt/hash/ACL validation.'
}

$bootstrapLockTestRoot = Join-Path `
    $repositoryRoot `
    "artifacts\broker-bootstrap-lock-$PID-$([guid]::NewGuid().ToString('N'))"
$bootstrapLockMovedTestRoot = "$bootstrapLockTestRoot-moved"
$bootstrapPackageRoot = Join-Path $bootstrapLockTestRoot 'package'
$bootstrapMovedPackageRoot = Join-Path $bootstrapLockTestRoot 'package-moved'
$bootstrapBrokerDirectory = Join-Path $bootstrapPackageRoot 'broker'
$bootstrapMovedBrokerDirectory = Join-Path $bootstrapPackageRoot 'broker-moved'
$bootstrapLock = $null
try {
    New-Item -ItemType Directory -Path $bootstrapBrokerDirectory -Force | Out-Null
    $bootstrapLockPath = Join-Path $bootstrapBrokerDirectory 'EverVigil.Broker.exe'
    $bootstrapMovedPath = Join-Path $bootstrapBrokerDirectory 'replaced.exe'
    Copy-Item `
        -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') `
        -Destination $bootstrapLockPath
    $bootstrapLock = [EverVigil.BootstrapPathLock]::Acquire(
        $bootstrapLockPath)
    $bootstrapLock.Validate()
    $writeRejected = $false
    try {
        [IO.File]::WriteAllBytes($bootstrapLockPath, [byte[]](5, 6, 7, 8))
    } catch [IO.IOException] {
        $writeRejected = $true
    }
    $renameRejected = $false
    try {
        [IO.File]::Move($bootstrapLockPath, $bootstrapMovedPath)
    } catch [IO.IOException] {
        $renameRejected = $true
    }
    if (-not $writeRejected -or -not $renameRejected) {
        throw 'A write or rename could replace the package broker while its bootstrap lock was held.'
    }

    $brokerDirectoryRenameRejected = $false
    try {
        [IO.Directory]::Move($bootstrapBrokerDirectory, $bootstrapMovedBrokerDirectory)
    } catch [IO.IOException] {
        $brokerDirectoryRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $brokerDirectoryRenameRejected = $true
    }
    $packageDirectoryRenameRejected = $false
    try {
        [IO.Directory]::Move($bootstrapPackageRoot, $bootstrapMovedPackageRoot)
    } catch [IO.IOException] {
        $packageDirectoryRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $packageDirectoryRenameRejected = $true
    }
    $testRootRenameRejected = $false
    try {
        [IO.Directory]::Move($bootstrapLockTestRoot, $bootstrapLockMovedTestRoot)
    } catch [IO.IOException] {
        $testRootRenameRejected = $true
    } catch [UnauthorizedAccessException] {
        $testRootRenameRejected = $true
    }
    if (-not $brokerDirectoryRenameRejected -or
        -not $packageDirectoryRenameRejected -or
        -not $testRootRenameRejected) {
        throw 'A broker, package, or test-root ancestor directory could be renamed while the package broker lock was held.'
    }

    $bootstrapLock.Validate()

    $lockedImageProcess = Start-Process `
        -FilePath $bootstrapLockPath `
        -ArgumentList 'cmd.exe' `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    try {
        if ($lockedImageProcess.ExitCode -ne 0) {
            throw 'Windows could not load a read-locked package executable.'
        }
    } finally {
        $lockedImageProcess.Dispose()
    }
} finally {
    if ($bootstrapLock) {
        $bootstrapLock.Dispose()
    }
    foreach ($bootstrapLockCleanupPath in @(
            $bootstrapLockTestRoot,
            $bootstrapLockMovedTestRoot)) {
        if (Test-Path -LiteralPath $bootstrapLockCleanupPath) {
            Remove-Item `
                -LiteralPath $bootstrapLockCleanupPath `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Assert-EverVigilBootstrapPathRejected {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )

    $unexpectedLock = $null
    $rejected = $false
    try {
        $unexpectedLock = [EverVigil.BootstrapPathLock]::Acquire($Path)
    } catch {
        if (-not $_.Exception.ToString().Contains(
                $ExpectedMessage,
                [StringComparison]::Ordinal)) {
            throw
        }
        $rejected = $true
    } finally {
        if ($unexpectedLock) {
            $unexpectedLock.Dispose()
        }
    }
    if (-not $rejected) {
        throw "An unsafe bootstrap path was accepted: $Path"
    }
}

$bootstrapReparseTestRoot = Join-Path `
    $repositoryRoot `
    "artifacts\broker-bootstrap-reparse-$PID-$([guid]::NewGuid().ToString('N'))"
$bootstrapReparseLinks = [Collections.Generic.List[string]]::new()
try {
    $wherePath = Join-Path $env:SystemRoot 'System32\where.exe'

    $ancestorTarget = Join-Path $bootstrapReparseTestRoot 'ancestor-target'
    $ancestorTargetBroker = Join-Path $ancestorTarget 'package\broker'
    New-Item -ItemType Directory -Path $ancestorTargetBroker -Force | Out-Null
    Copy-Item -LiteralPath $wherePath -Destination (Join-Path `
            $ancestorTargetBroker `
            'EverVigil.Broker.exe')
    $ancestorLink = Join-Path $bootstrapReparseTestRoot 'ancestor-link'
    New-Item -ItemType Junction -Path $ancestorLink -Target $ancestorTarget | Out-Null
    $bootstrapReparseLinks.Add($ancestorLink)
    Assert-EverVigilBootstrapPathRejected `
        -Path (Join-Path $ancestorLink 'package\broker\EverVigil.Broker.exe') `
        -ExpectedMessage 'A reparse point is forbidden in the bootstrap path'

    $packageParent = Join-Path $bootstrapReparseTestRoot 'package-parent'
    $packageTargetBroker = Join-Path $bootstrapReparseTestRoot 'package-target\broker'
    New-Item -ItemType Directory -Path $packageParent -Force | Out-Null
    New-Item -ItemType Directory -Path $packageTargetBroker -Force | Out-Null
    Copy-Item -LiteralPath $wherePath -Destination (Join-Path `
            $packageTargetBroker `
            'EverVigil.Broker.exe')
    $packageLink = Join-Path $packageParent 'package'
    New-Item `
        -ItemType Junction `
        -Path $packageLink `
        -Target (Split-Path -Parent $packageTargetBroker) | Out-Null
    $bootstrapReparseLinks.Add($packageLink)
    Assert-EverVigilBootstrapPathRejected `
        -Path (Join-Path $packageLink 'broker\EverVigil.Broker.exe') `
        -ExpectedMessage 'A reparse point is forbidden in the bootstrap path'

    $brokerPackage = Join-Path $bootstrapReparseTestRoot 'broker-parent\package'
    $brokerTarget = Join-Path $bootstrapReparseTestRoot 'broker-target'
    New-Item -ItemType Directory -Path $brokerPackage -Force | Out-Null
    New-Item -ItemType Directory -Path $brokerTarget -Force | Out-Null
    Copy-Item -LiteralPath $wherePath -Destination (Join-Path `
            $brokerTarget `
            'EverVigil.Broker.exe')
    $brokerLink = Join-Path $brokerPackage 'broker'
    New-Item -ItemType Junction -Path $brokerLink -Target $brokerTarget | Out-Null
    $bootstrapReparseLinks.Add($brokerLink)
    Assert-EverVigilBootstrapPathRejected `
        -Path (Join-Path $brokerLink 'EverVigil.Broker.exe') `
        -ExpectedMessage 'A reparse point is forbidden in the bootstrap path'

    $hardLinkBroker = Join-Path $bootstrapReparseTestRoot 'hardlink\package\broker'
    New-Item -ItemType Directory -Path $hardLinkBroker -Force | Out-Null
    $hardLinkSource = Join-Path $bootstrapReparseTestRoot 'hardlink-source.exe'
    $hardLinkPath = Join-Path $hardLinkBroker 'EverVigil.Broker.exe'
    Copy-Item -LiteralPath $wherePath -Destination $hardLinkSource
    New-Item -ItemType HardLink -Path $hardLinkPath -Target $hardLinkSource | Out-Null
    Assert-EverVigilBootstrapPathRejected `
        -Path $hardLinkPath `
        -ExpectedMessage 'The bootstrap executable must have exactly one hard link'
} finally {
    foreach ($bootstrapReparseLink in $bootstrapReparseLinks) {
        if (Test-Path -LiteralPath $bootstrapReparseLink) {
            Remove-Item -LiteralPath $bootstrapReparseLink -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $bootstrapReparseTestRoot) {
        Remove-Item `
            -LiteralPath $bootstrapReparseTestRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
foreach ($callerGuard in @(
        'Invoke-EverVigilSystemBroker'
        'ReleaseMutex()'
        'WaitOne([TimeSpan]::FromMinutes(10))'
        'Get-ValidatedEverVigilProtectedBrokerRetirementState'
        'Complete-EverVigilProtectedBrokerRetirement'
        "'NeedsBrokerResume'"
        '-ExpectedTransactionId $pendingRecoveryTransactionId'
        "[string]`$retirementRecoveryResponse.disposition -cne"
        "'RetirementRequired'"
        '[IO.File]::Delete($retirementFile)'
        '[IO.Directory]::Delete($retirementDirectory, $false)'
    )) {
    if (-not $callerContent.Contains($callerGuard, [StringComparison]::Ordinal)) {
        throw "A medium caller broker/mutex guard is missing: $callerGuard"
    }
}
$retirementFileDeleteOrder = @(
    '$paths.CanonicalPath,'
    '$paths.InstallationReceiptPath,'
    '$paths.RetirementReceiptPath)'
)
$retirementOrderCursor = $contents[$uninstallPath].IndexOf(
    'function Complete-EverVigilProtectedBrokerRetirement',
    [StringComparison]::Ordinal)
foreach ($retirementOrderGuard in $retirementFileDeleteOrder) {
    $nextRetirementOrderCursor = $contents[$uninstallPath].IndexOf(
        $retirementOrderGuard,
        $retirementOrderCursor,
        [StringComparison]::Ordinal)
    if ($nextRetirementOrderCursor -le $retirementOrderCursor) {
        throw "Protected broker retirement deletion order is missing: $retirementOrderGuard"
    }
    $retirementOrderCursor = $nextRetirementOrderCursor
}
if (-not $contents[$installPath].Contains(
        '-AllowBootstrap:($Mode -eq ''Install'')',
        [StringComparison]::Ordinal) -or
    $resolverContent.Contains('[string]$PackageRoot', [StringComparison]::Ordinal) -or
    $contents[$uninstallPath].Contains('-AllowBootstrap', [StringComparison]::Ordinal) -or
    [regex]::Matches(
        $contents[$completePath],
        '(?m)-AllowBootstrap\s*$').Count -ne 1) {
    throw 'Only installer Apply and the authorized initial-rollback Status recovery may bootstrap the protected broker.'
}
foreach ($rollbackBootstrapGuard in @(
        '$bootstrapInitialRollback'
        '$Mode -eq ''Rollback'''
        '-Operation Status'
        '-Initiator Installer'
        '-AllowBootstrap'
        "'CanonicalReady'"
        "'NoChange'"
    )) {
    if (-not $contents[$completePath].Contains(
            $rollbackBootstrapGuard,
            [StringComparison]::Ordinal)) {
        throw "An authorized initial-rollback Status bootstrap guard is missing: $rollbackBootstrapGuard"
    }
}
foreach ($singlePromptBrokerBootstrapGuard in @(
        "[ValidateSet('Install', 'Commit', 'Rollback')]"
        "'Install' { 'Apply' }"
        '-AllowBootstrap:($Mode -eq ''Install'')'
        '$transactionState.protectedBrokerReady = $true'
    )) {
    if (-not $contents[$installPath].Contains(
            $singlePromptBrokerBootstrapGuard,
            [StringComparison]::Ordinal)) {
        throw "A single-prompt installer Apply bootstrap guard is missing: $singlePromptBrokerBootstrapGuard"
    }
}
if ($contents[$installPath].Contains(
        'Invoke-SystemBrokerMaintenance -Mode Prepare',
        [StringComparison]::Ordinal)) {
    throw 'Installer preparation must not trigger a standalone elevated broker request.'
}
foreach ($v121MigrationGuard in @(
        '$migrateV121SystemState = [bool]$legacyCleanupAuthorized -and'
        '$appliedSystemConfigurationWasPresent'
        'if (-not $systemConfigurationCanBePreserved -or'
        '-MigrateV121SystemState:$migrateV121SystemState'
        'migrateV121SystemState = $migrateV121SystemState'
    )) {
    if (-not $contents[$installPath].Contains(
            $v121MigrationGuard,
            [StringComparison]::Ordinal)) {
        throw "A strict v1.2.1 system-state migration guard is missing: $v121MigrationGuard"
    }
}
foreach ($credentialCoupling in @(
        '-MigrateV121SystemState:$legacyCredentialFound'
        '-MigrateLegacySystemState:$legacyCredentialFound'
        '[switch]$LegacyCredentialOwned'
    )) {
    if ($callerContent.Contains($credentialCoupling, [StringComparison]::Ordinal)) {
        throw "v1.2.1 system-state migration is still coupled to an older plaintext credential: $credentialCoupling"
    }
}
foreach ($adapterForbidden in @(
        'Get-NetFirewallRule'
        'Remove-NetFirewallRule'
        'New-NetFirewallRule'
        'Get-ScheduledTask'
        'Unregister-ScheduledTask'
        'tailscale serve'
        'Start-Process'
    )) {
    if ($adapterContent.Contains($adapterForbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The medium system adapter still contains privileged logic: $adapterForbidden"
    }
}

foreach ($brokerPackageGuard in @(
        "'src\EverVigil.Broker\EverVigil.Broker.csproj'"
        "Join-Path `$resolvedOutputRoot 'broker-publish'"
        "Join-Path `$packageRoot 'broker'"
        '-p:PublishSingleFile=true'
        '$publishedBrokerFiles.Count -ne 1'
        "Join-Path `$brokerPublishRoot 'EverVigil.Broker.exe'"
        'Copy-Item -LiteralPath $publishedBroker -Destination (Join-Path $packageRoot ''broker'')'
        '-PublishRoot $brokerPublishRoot'
        '$brokerPublishRoot,'
    )) {
    if (-not $buildReleaseContent.Contains(
            $brokerPackageGuard,
            [StringComparison]::Ordinal)) {
        throw "A privileged-broker release-package guard is missing: $brokerPackageGuard"
    }
}

'System broker tests passed: canonical ACL/receipt/hash gate, single-prompt installer Apply bootstrap, strict authenticated framing, one-shot nonce/transaction binding, loopback-only token health with redirect isolation, response type guards, and PowerShell elevation/mutation ban.'
