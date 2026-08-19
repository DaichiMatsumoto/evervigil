[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot 'compatibility\legacy-v1.2.1.json'
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Missing '$Name' in $Context."
    }
    return $property.Value
}

function Get-RequiredSingleLineString {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    $value = Get-RequiredProperty -InputObject $InputObject -Name $Name -Context $Context
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        throw "'$Name' in $Context must be a non-empty string."
    }
    foreach ($character in $value.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ([char]::IsControl($character) -or
            $category -eq [Globalization.UnicodeCategory]::LineSeparator -or
            $category -eq [Globalization.UnicodeCategory]::ParagraphSeparator) {
            throw "'$Name' in $Context must be a single-line string without control characters."
        }
    }
    return [string]$value
}

function ConvertTo-CSharpStringLiteral {
    param([Parameter(Mandatory)][string]$Value)

    $builder = [Text.StringBuilder]::new($Value.Length + 8)
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -eq 0x22) {
            [void]$builder.Append('\"')
        } elseif ($code -eq 0x5C) {
            [void]$builder.Append('\\')
        } elseif ($code -lt 0x20 -or $code -eq 0x7F -or $code -eq 0x2028 -or
            $code -eq 0x2029) {
            [void]$builder.Append(('\u{0:X4}' -f $code))
        } else {
            [void]$builder.Append($character)
        }
    }
    return '"' + $builder.ToString() + '"'
}

function ConvertTo-PowerShellStringLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-InnoStringLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Add-GeneratedLine {
    param(
        [Parameter(Mandatory)][object]$Lines,
        [AllowEmptyString()][string]$Text = ''
    )

    if ($Lines -isnot [Collections.Generic.List[string]]) {
        throw 'Generated line destination must be a string list.'
    }
    [void]$Lines.Add($Text)
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Legacy compatibility manifest was not found: $manifestPath"
}

try {
    $manifestText = [IO.File]::ReadAllText($manifestPath, $utf8)
    $manifest = $manifestText | ConvertFrom-Json
} catch {
    throw "Legacy compatibility manifest is invalid: $($_.Exception.Message)"
}

$schemaVersion = Get-RequiredProperty `
    -InputObject $manifest `
    -Name 'schemaVersion' `
    -Context 'manifest root'
$schemaTypeCode = if ($null -eq $schemaVersion) {
    [TypeCode]::Empty
} else {
    [Type]::GetTypeCode($schemaVersion.GetType())
}
$integerTypeCodes = @(
    [TypeCode]::Byte
    [TypeCode]::SByte
    [TypeCode]::Int16
    [TypeCode]::UInt16
    [TypeCode]::Int32
    [TypeCode]::UInt32
    [TypeCode]::Int64
    [TypeCode]::UInt64
)
if ($schemaTypeCode -notin $integerTypeCodes -or [uint64]$schemaVersion -ne 1) {
    throw "Unsupported legacy compatibility schema version: $schemaVersion"
}
$schemaVersion = 1

$groups = @(Get-RequiredProperty -InputObject $manifest -Name 'groups' -Context 'manifest root')
if ($groups.Count -eq 0) {
    throw 'Legacy compatibility manifest must contain at least one group.'
}

$validatedGroups = [Collections.Generic.List[object]]::new()
$groupNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$flatNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($group in $groups) {
    $groupName = Get-RequiredSingleLineString `
        -InputObject $group `
        -Name 'name' `
        -Context 'compatibility group'
    if ($groupName -cnotmatch '\A[A-Z][A-Za-z0-9]*\z') {
        throw "Compatibility group name is not a C-style identifier: $groupName"
    }
    if (-not $groupNames.Add($groupName)) {
        throw "Duplicate compatibility group name: $groupName"
    }
    $groupPurpose = Get-RequiredSingleLineString `
        -InputObject $group `
        -Name 'purpose' `
        -Context "group '$groupName'"
    $entries = @(Get-RequiredProperty `
            -InputObject $group `
            -Name 'entries' `
            -Context "group '$groupName'")
    if ($entries.Count -eq 0) {
        throw "Compatibility group '$groupName' must contain at least one entry."
    }

    $validatedEntries = [Collections.Generic.List[object]]::new()
    $entryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $entryName = Get-RequiredSingleLineString `
            -InputObject $entry `
            -Name 'name' `
            -Context "group '$groupName' entry"
        if ($entryName -cnotmatch '\A[A-Z][A-Za-z0-9]*\z') {
            throw "Compatibility entry name is not a C-style identifier: $groupName.$entryName"
        }
        if (-not $entryNames.Add($entryName)) {
            throw "Duplicate compatibility entry name: $groupName.$entryName"
        }
        $flatName = "$groupName$entryName"
        if (-not $flatNames.Add($flatName)) {
            throw "Flattened compatibility name is ambiguous: $flatName"
        }
        $entryValue = Get-RequiredSingleLineString `
            -InputObject $entry `
            -Name 'value' `
            -Context "entry '$groupName.$entryName'"
        $entryPurpose = Get-RequiredSingleLineString `
            -InputObject $entry `
            -Name 'purpose' `
            -Context "entry '$groupName.$entryName'"
        $validatedEntries.Add([pscustomobject]@{
                Name = $entryName
                Value = $entryValue
                Purpose = $entryPurpose
            })
    }
    $validatedGroups.Add([pscustomobject]@{
            Name = $groupName
            Purpose = $groupPurpose
            Entries = @($validatedEntries)
        })
}

$csharp = [Collections.Generic.List[string]]::new()
Add-GeneratedLine $csharp '// <auto-generated />'
Add-GeneratedLine $csharp '#nullable enable'
Add-GeneratedLine $csharp
Add-GeneratedLine $csharp 'namespace EverVigil.Compatibility;'
Add-GeneratedLine $csharp
Add-GeneratedLine $csharp 'internal static class LegacyCompatibility'
Add-GeneratedLine $csharp '{'
Add-GeneratedLine $csharp "    internal const int ManifestSchemaVersion = $schemaVersion;"
foreach ($group in $validatedGroups) {
    Add-GeneratedLine $csharp
    Add-GeneratedLine $csharp "    // $($group.Purpose)"
    Add-GeneratedLine $csharp "    internal static class $($group.Name)"
    Add-GeneratedLine $csharp '    {'
    foreach ($entry in $group.Entries) {
        Add-GeneratedLine $csharp "        // $($entry.Purpose)"
        Add-GeneratedLine $csharp (
            "        internal const string $($entry.Name) = " +
            "$(ConvertTo-CSharpStringLiteral $entry.Value);")
    }
    Add-GeneratedLine $csharp '    }'
}
Add-GeneratedLine $csharp '}'

$powershell = [Collections.Generic.List[string]]::new()
Add-GeneratedLine $powershell '# <auto-generated />'
Add-GeneratedLine $powershell '# Generated by scripts/Sync-LegacyCompatibility.ps1. Do not edit.'
Add-GeneratedLine $powershell
Add-GeneratedLine $powershell ('$script:LegacyCompatibilityManifestSchemaVersion = ' + $schemaVersion)
foreach ($group in $validatedGroups) {
    Add-GeneratedLine $powershell
    Add-GeneratedLine $powershell "# $($group.Purpose)"
    foreach ($entry in $group.Entries) {
        Add-GeneratedLine $powershell "# $($entry.Purpose)"
        Add-GeneratedLine $powershell (
            '$script:LegacyCompatibility' + $group.Name + $entry.Name + ' = ' +
            (ConvertTo-PowerShellStringLiteral $entry.Value))
    }
}

$inno = [Collections.Generic.List[string]]::new()
Add-GeneratedLine $inno '; <auto-generated />'
Add-GeneratedLine $inno '; Generated by scripts/Sync-LegacyCompatibility.ps1. Do not edit.'
Add-GeneratedLine $inno
Add-GeneratedLine $inno "#define LegacyCompatibilityManifestSchemaVersion $schemaVersion"
foreach ($group in $validatedGroups) {
    Add-GeneratedLine $inno
    Add-GeneratedLine $inno "; $($group.Purpose)"
    foreach ($entry in $group.Entries) {
        Add-GeneratedLine $inno "; $($entry.Purpose)"
        Add-GeneratedLine $inno (
            '#define LegacyCompatibility' + $group.Name + $entry.Name + ' ' +
            (ConvertTo-InnoStringLiteral $entry.Value))
    }
}

$outputs = @(
    [pscustomobject]@{
        Path = Join-Path $repositoryRoot 'src\EverVigil\Compatibility\LegacyCompatibility.g.cs'
        Content = ($csharp -join "`n") + "`n"
    }
    [pscustomobject]@{
        Path = Join-Path $repositoryRoot 'scripts\LegacyCompatibility.generated.ps1'
        Content = ($powershell -join "`r`n") + "`r`n"
    }
    [pscustomobject]@{
        Path = Join-Path $repositoryRoot 'installer\LegacyCompatibility.generated.iss'
        Content = ($inno -join "`n") + "`n"
    }
)

$stalePaths = [Collections.Generic.List[string]]::new()
foreach ($output in $outputs) {
    $expectedBytes = $utf8.GetBytes([string]$output.Content)
    $matches = $false
    if (Test-Path -LiteralPath $output.Path -PathType Leaf) {
        $actualBytes = [IO.File]::ReadAllBytes($output.Path)
        $matches = $actualBytes.Length -eq $expectedBytes.Length
        if ($matches) {
            for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
                if ($actualBytes[$index] -ne $expectedBytes[$index]) {
                    $matches = $false
                    break
                }
            }
        }
    }

    if ($matches) {
        continue
    }
    if ($Check) {
        $relativePath = $output.Path.Substring($repositoryRoot.Length).TrimStart('\', '/')
        $stalePaths.Add($relativePath)
        continue
    }

    $directory = Split-Path -Parent $output.Path
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllBytes($output.Path, $expectedBytes)
}

if ($stalePaths.Count -gt 0) {
    throw (
        'Legacy compatibility generated files are missing or stale: ' +
        ($stalePaths -join ', ') +
        '. Run scripts\Sync-LegacyCompatibility.ps1 and review the result.')
}
