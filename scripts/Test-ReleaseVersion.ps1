[CmdletBinding(DefaultParameterSetName = 'Version')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Version')]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory, ParameterSetName = 'Tag')]
    [ValidateNotNullOrEmpty()]
    [string]$Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$numericIdentifier = '(?:0|[1-9]\d*)'
$alphanumericIdentifier = '[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*'
$prereleaseIdentifier = "(?:$numericIdentifier|$alphanumericIdentifier)"
$semanticVersionPattern =
    "$numericIdentifier\.$numericIdentifier\.$numericIdentifier" +
    "(?:-$prereleaseIdentifier(?:\.$prereleaseIdentifier)*)?"

$candidate = if ($PSCmdlet.ParameterSetName -eq 'Tag') {
    if ($Tag -notmatch "\Av(?<Version>$semanticVersionPattern)\z") {
        throw "Release tag is not a supported canonical semantic version: $Tag"
    }
    $Matches.Version
} else {
    if ($Version -notmatch "\A$semanticVersionPattern\z") {
        throw "Release version is not a supported canonical semantic version: $Version"
    }
    $Version
}

$candidate
