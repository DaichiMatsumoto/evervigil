[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$PackageRoot,
    [string]$PublishRoot,
    [string[]]$BinaryPath = @(),
    [string[]]$DenyValue = @(),
    [string[]]$DenySha256 = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot) -and
    [string]::IsNullOrWhiteSpace($PackageRoot) -and
    [string]::IsNullOrWhiteSpace($PublishRoot) -and
    $BinaryPath.Count -eq 0) {
    throw 'Specify RepositoryRoot, PackageRoot, PublishRoot, BinaryPath, or a combination.'
}

$failures = [Collections.Generic.List[string]]::new()
$forbiddenFileNames = @(
    'settings.json'
    'token.dat'
    'token.txt'
    'state.json'
    'applied-system-configuration.json'
    'pending-system-configuration.json'
    'system-configuration-required'
    'supervisor.lock'
    'diagnostic-logging.enabled'
)
$forbiddenExtensions = @('.log', '.pdb', '.user', '.suo', '.key', '.pem', '.pfx')
$textExtensions = @(
    '.bat', '.cmd', '.conf', '.config', '.cs', '.csproj', '.editorconfig',
    '.gitattributes', '.gitignore', '.ini', '.iss', '.isl', '.json', '.manifest', '.md', '.properties',
    '.props', '.ps1', '.psd1', '.psm1', '.resx', '.sh', '.sln', '.targets', '.toml',
    '.txt', '.xml', '.yaml', '.yml'
)
$allowedPackageFiles = @(
    'docs\README.en.md'
    'docs\README.ja.md'
    'docs\REFERENCE.en.md'
    'docs\REFERENCE.ja.md'
    'docs\SECURITY.en.md'
    'docs\SECURITY.ja.md'
    'docs\TECHNICAL_OVERVIEW.en.md'
    'docs\TECHNICAL_OVERVIEW.ja.md'
    'docs\images\evervigil-overview-en.png'
    'docs\images\evervigil-config-en.png'
    'docs\images\evervigil-about-en.png'
    'docs\images\evervigil-overview-ja.png'
    'docs\images\evervigil-config-ja.png'
    'docs\images\evervigil-about-ja.png'
    'licenses\DOTNET-LICENSE.txt'
    'licenses\DOTNET-THIRD-PARTY-NOTICES.txt'
    'licenses\INNO-SETUP-LICENSE.txt'
    'licenses\QRCODER-LICENSE.txt'
    'broker\EverVigil.Broker.exe'
    'payload\EverVigil.exe'
    'scripts\Complete-InstallTransaction.ps1'
    'scripts\Export-InstallerPayload.ps1'
    'scripts\InstallTransactionData.ps1'
    'scripts\Invoke-InteractiveUserTask.ps1'
    'scripts\Invoke-SystemMaintenance.ps1'
    'scripts\LegacyCompatibility.generated.ps1'
    'scripts\Resolve-SafeInstallRoot.ps1'
    'Install.ps1'
    'LICENSE'
    'NOTICE.md'
    'README.md'
    'RELEASE_NOTES.md'
    'SECURITY.md'
    'THIRD-PARTY-NOTICES.md'
    'Uninstall.ps1'
)
$script:scannedFileCount = 0
$script:scannedBinaryCount = 0
$script:hashedFileCount = 0

$fixedBrandDenySha256 = @(
    '520F30AD208EE7F88F10E2CBC08A0169' + 'D2B3C0BBF8D57C34A6E9207E4FD8DAA6'
    '5450B5B0300267199207DE95CE795A3' + '52C174BBB37661471C96D24D6FA7007D8'
)
$fixedBrandDenyValues = @(
    ('even' + '-realities-favicon')
    ('even' + '-realities.ico')
    ('https://www.' + 'evenrealities.com/android-chrome-' + '512x512.png')
    ('Official ' + 'logo')
    ('official ' + 'Even Realities icon')
    ('Even Realities' + '公式' + 'アイコン')
    ('公式' + 'アイコン')
    ('公式' + 'ロゴ')
    ('public favicon of the ' + 'Even Realities website')
    ('associated logos and marks belong to their respective ' + 'owner')
    ('upstream ' + 'brand asset')
    ('brand assets are not covered by ' + 'GPL')
    ('brand assets are excluded from ' + 'GPL coverage')
    ('ブランド資産は' + 'GPL対象外')
)

$denySha256Index = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($digest in @($fixedBrandDenySha256 + $DenySha256)) {
    if ([string]::IsNullOrWhiteSpace($digest)) {
        continue
    }
    $normalizedDigest = $digest.Trim()
    if ($normalizedDigest -cnotmatch '\A[0-9A-Fa-f]{64}\z') {
        throw "A deny-listed SHA-256 value is malformed: $digest"
    }
    [void]$denySha256Index.Add($normalizedDigest)
}

$patterns = [ordered]@{
    'absolute Windows user profile' = '(?i)\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/][^\\/\s:*?"<>|]+'
    'absolute Unix user profile' = '(?i)(?<![A-Za-z0-9._~:/\\-])/(?:home|Users)/[^/\s"''`<>]+'
    'Tailnet DNS name' = '(?i)\b[a-z0-9-]+\.[a-z0-9-]+\.ts\.net\b'
    'Tailnet IPv4 address' = '\b100\.(?:\d{1,3}\.){2}\d{1,3}\b'
    'GitHub access token' = '\b(?:gh[opsur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
    'OpenAI API key' = '\bsk-(?:(?:proj|svcacct|admin)-)?[A-Za-z0-9_-]{20,}\b'
    'private key material' = ('-----BEGIN' + '[ A-Z0-9_-]*PRIVATE KEY-----')
    'Even Terminal access token' = '(?i)(?:["'']?token["'']?\s*(?:=|:|%3D)\s*["'']?|bearer\s+)[0-9a-f]{32}\b'
}
$explicitDenyValues = @($fixedBrandDenyValues + $DenyValue) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
} | Select-Object -Unique
$explicitDenyIndex = 0
foreach ($value in $explicitDenyValues) {
    $explicitDenyIndex++
    $patterns["explicitly denied identifier #$explicitDenyIndex"] =
        '(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($value) + '(?![A-Za-z0-9_-])'
}

function Add-Failure {
    param(
        [Parameter(Mandatory)][string]$Message
    )

    $failures.Add($Message)
}

function Test-IsEnvironmentFile {
    param([Parameter(Mandatory)][string]$FileName)

    return $FileName.Equals('.env', [StringComparison]::OrdinalIgnoreCase) -or
        $FileName.StartsWith('.env.', [StringComparison]::OrdinalIgnoreCase)
}

function Test-FileName {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$BasePath
    )

    $relativePath = [IO.Path]::GetRelativePath($BasePath, $File.FullName)
    $script:scannedFileCount++
    if ($File.Name -in $forbiddenFileNames) {
        Add-Failure "Runtime data file is forbidden: $relativePath"
    }
    if ($File.Extension -in $forbiddenExtensions) {
        Add-Failure "Private or build-only file is forbidden: $relativePath"
    }
    if (Test-IsEnvironmentFile -FileName $File.Name) {
        Add-Failure "Environment configuration file is forbidden: $relativePath"
    }
}

function Test-FileHash {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$BasePath
    )

    $relativePath = [IO.Path]::GetRelativePath($BasePath, $File.FullName)
    $script:hashedFileCount++
    $digest = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    if ($denySha256Index.Contains($digest)) {
        Add-Failure "Deny-listed SHA-256 found in: $relativePath"
    }
}

function Test-Content {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$BasePath,
        [switch]$Binary
    )

    $relativePath = [IO.Path]::GetRelativePath($BasePath, $File.FullName)
    if ($Binary) {
        $script:scannedBinaryCount++
        if ($File.Length -gt 256MB) {
            Add-Failure "File is too large for contamination scanning: $relativePath"
            return
        }
        $bytes = [IO.File]::ReadAllBytes($File.FullName)
        $contentVariants = @(
            [Text.Encoding]::ASCII.GetString($bytes)
            [Text.Encoding]::Unicode.GetString($bytes)
            [Text.Encoding]::BigEndianUnicode.GetString($bytes)
        )
    } else {
        $contentVariants = @([IO.File]::ReadAllText($File.FullName))
    }

    foreach ($entry in $patterns.GetEnumerator()) {
        if ($contentVariants | Where-Object { $_ -match $entry.Value } | Select-Object -First 1) {
            Add-Failure "Potential $($entry.Key) found in: $relativePath"
        }
    }
}

function Test-Tree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$IsPackage,
        [switch]$IsPublish
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Scan root was not found: $Root"
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $files = @(
        if ($IsPackage -or $IsPublish) {
            Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force
        } else {
            Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force |
                Where-Object {
                    $_.FullName -notmatch '[\\/](?:\.git|\.jj|bin|obj|artifacts)[\\/]'
                }
        }
    )
    if ($IsPackage) {
        if ($files.Count -eq 0) {
            Add-Failure 'Release package is empty.'
        }
        $actualRelativePaths = @($files | ForEach-Object {
            [IO.Path]::GetRelativePath($resolvedRoot, $_.FullName)
        })
        foreach ($relativePath in $actualRelativePaths) {
            if ($relativePath -notin $allowedPackageFiles) {
                Add-Failure "Unexpected release-package file: $relativePath"
            }
        }
        foreach ($requiredPath in $allowedPackageFiles) {
            if ($requiredPath -notin $actualRelativePaths) {
                Add-Failure "Required release-package file is missing: $requiredPath"
            }
        }
    }
    if ($IsPublish -and $files.Count -eq 0) {
        Add-Failure 'Uncompressed publish tree is empty.'
    }
    foreach ($file in $files) {
        Test-FileName -File $file -BasePath $resolvedRoot
        Test-FileHash -File $file -BasePath $resolvedRoot
        if ($file.Extension -in $textExtensions -or
            $file.Name -eq 'LICENSE' -or
            (Test-IsEnvironmentFile -FileName $file.Name)) {
            Test-Content -File $file -BasePath $resolvedRoot
        } elseif ($IsPackage -or $IsPublish) {
            Test-Content `
                -File $file `
                -BasePath $resolvedRoot `
                -Binary
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Test-Tree -Root $RepositoryRoot
}
if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    Test-Tree -Root $PackageRoot -IsPackage
}
if (-not [string]::IsNullOrWhiteSpace($PublishRoot)) {
    Test-Tree -Root $PublishRoot -IsPublish
}
foreach ($path in @($BinaryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Binary scan target was not found: $path"
    }
    $binary = Get-Item -LiteralPath $path
    Test-FileName -File $binary -BasePath $binary.DirectoryName
    Test-FileHash -File $binary -BasePath $binary.DirectoryName
    Test-Content -File $binary -BasePath $binary.DirectoryName -Binary
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Public release contamination scan failed with $($failures.Count) finding(s)."
}

"Public release contamination scan passed: $script:scannedFileCount files, $script:scannedBinaryCount binaries, $script:hashedFileCount SHA-256 values."
