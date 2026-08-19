[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing.Common

$sourceSize = 1024
$iconSizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$assetRoot = Join-Path $RepositoryRoot 'src\EverVigil\Assets'
$sourcePath = Join-Path $assetRoot 'evervigil-placeholder-source.png'
$iconPath = Join-Path $assetRoot 'evervigil-placeholder.ico'

function New-PlaceholderBitmap {
    param([Parameter(Mandatory)][int]$Size)

    $bitmap = [Drawing.Bitmap]::new(
        $Size,
        $Size,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $scale = $Size / 1024.0
        [Drawing.PointF[]]$outer = @(
            [Drawing.PointF]::new(512 * $scale, 72 * $scale)
            [Drawing.PointF]::new(818 * $scale, 248 * $scale)
            [Drawing.PointF]::new(756 * $scale, 724 * $scale)
            [Drawing.PointF]::new(512 * $scale, 928 * $scale)
            [Drawing.PointF]::new(268 * $scale, 724 * $scale)
            [Drawing.PointF]::new(206 * $scale, 248 * $scale)
        )
        [Drawing.PointF[]]$inner = @(
            [Drawing.PointF]::new(512 * $scale, 232 * $scale)
            [Drawing.PointF]::new(626 * $scale, 512 * $scale)
            [Drawing.PointF]::new(512 * $scale, 792 * $scale)
            [Drawing.PointF]::new(398 * $scale, 512 * $scale)
        )

        $outerBrush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#07130C'))
        $innerBrush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#39FF88'))
        $outline = [Drawing.Pen]::new(
            [Drawing.ColorTranslator]::FromHtml('#E7FCE8'),
            [Math]::Max(1.0, 30 * $scale))
        try {
            $outline.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
            $graphics.FillPolygon($outerBrush, $outer)
            $graphics.DrawPolygon($outline, $outer)
            $graphics.FillPolygon($innerBrush, $inner)

            # Matrix-inspired visor: opaque lenses keep the mark legible at 16px,
            # while the neon bridge and temples preserve the Even Terminal cue.
            [Drawing.PointF[]]$leftLens = @(
                [Drawing.PointF]::new(326 * $scale, 434 * $scale)
                [Drawing.PointF]::new(488 * $scale, 434 * $scale)
                [Drawing.PointF]::new(458 * $scale, 556 * $scale)
                [Drawing.PointF]::new(350 * $scale, 556 * $scale))
            [Drawing.PointF[]]$rightLens = @(
                [Drawing.PointF]::new(536 * $scale, 434 * $scale)
                [Drawing.PointF]::new(698 * $scale, 434 * $scale)
                [Drawing.PointF]::new(674 * $scale, 556 * $scale)
                [Drawing.PointF]::new(566 * $scale, 556 * $scale))
            $lensBrush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#020503'))
            $lensPen = [Drawing.Pen]::new(
                [Drawing.ColorTranslator]::FromHtml('#39FF88'),
                [Math]::Max(1.0, 16 * $scale))
            try {
                $lensPen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
                $graphics.FillPolygon($lensBrush, $leftLens)
                $graphics.FillPolygon($lensBrush, $rightLens)
                $graphics.DrawPolygon($lensPen, $leftLens)
                $graphics.DrawPolygon($lensPen, $rightLens)
                $graphics.DrawLine(
                    $lensPen,
                    [Drawing.PointF]::new(488 * $scale, 472 * $scale),
                    [Drawing.PointF]::new(536 * $scale, 472 * $scale))
                $graphics.DrawLine(
                    $lensPen,
                    [Drawing.PointF]::new(326 * $scale, 452 * $scale),
                    [Drawing.PointF]::new(250 * $scale, 420 * $scale))
                $graphics.DrawLine(
                    $lensPen,
                    [Drawing.PointF]::new(698 * $scale, 452 * $scale),
                    [Drawing.PointF]::new(774 * $scale, 420 * $scale))
            } finally {
                $lensPen.Dispose()
                $lensBrush.Dispose()
            }
        } finally {
            $outline.Dispose()
            $innerBrush.Dispose()
            $outerBrush.Dispose()
        }
    } finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Convert-BitmapToPngBytes {
    param([Parameter(Mandatory)][Drawing.Bitmap]$Bitmap)

    $stream = [IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function New-MultiSizeIconBytes {
    $images = @(foreach ($size in $iconSizes) {
        $bitmap = New-PlaceholderBitmap -Size $size
        try {
            [pscustomobject]@{
                Size = $size
                Bytes = Convert-BitmapToPngBytes -Bitmap $bitmap
            }
        } finally {
            $bitmap.Dispose()
        }
    })

    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$images.Count)
        $offset = 6 + (16 * $images.Count)
        foreach ($image in $images) {
            $dimension = if ($image.Size -eq 256) { 0 } else { $image.Size }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$image.Bytes.Length)
            $writer.Write([uint32]$offset)
            $offset += $image.Bytes.Length
        }
        foreach ($image in $images) {
            $writer.Write([byte[]]$image.Bytes)
        }
        $writer.Flush()
        return ,$stream.ToArray()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$sourceBitmap = New-PlaceholderBitmap -Size $sourceSize
try {
    $sourceBytes = Convert-BitmapToPngBytes -Bitmap $sourceBitmap
} finally {
    $sourceBitmap.Dispose()
}
$iconBytes = New-MultiSizeIconBytes

if ($Check) {
    foreach ($candidate in @(
            @{ Path = $sourcePath; Expected = $sourceBytes }
            @{ Path = $iconPath; Expected = $iconBytes }
        )) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) {
            throw "Generated placeholder asset is missing: $($candidate.Path)"
        }
        [byte[]]$actual = [IO.File]::ReadAllBytes($candidate.Path)
        [byte[]]$expected = $candidate.Expected
        $actualHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($actual))
        $expectedHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($expected))
        if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::Ordinal)) {
            throw "Generated placeholder asset is stale: $($candidate.Path)"
        }
    }
    'Placeholder icon assets are current.'
    return
}

New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
[IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
[IO.File]::WriteAllBytes($iconPath, $iconBytes)

[pscustomobject]@{
    Source = $sourcePath
    SourceSize = "${sourceSize}x${sourceSize}"
    Icon = $iconPath
    IconSizes = $iconSizes -join ', '
}
