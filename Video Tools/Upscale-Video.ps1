<#
.SYNOPSIS
    Upscales a real-film video with Video2X/Real-ESRGAN and creates an
    aspect-ratio-preserved 1080-height output with optional mild sharpening.

.DESCRIPTION
    This script uses Video2X with the Real-ESRGAN model to enhance a real-film
    video. The output is then resized to 1080 pixels high while preserving the
    original aspect ratio, and optionally sharpened. The final output is encoded
    with H.265/HEVC.

.PARAMETER InputFile
    The path to the input video file.

.PARAMETER OutputFile
    The path to the output video file. If not specified, the output will be
    created in the same directory as the input file with a modified name.

.PARAMETER Sharpen
    The amount of sharpening to apply to the final output. Valid values are:
    - Off: No sharpening.
    - Low: Mild sharpening.
    - Medium: Moderate sharpening (default).
    - High: Strong sharpening.

.PARAMETER Crf
    The Constant Rate Factor (CRF) for the final H.265 encoding. Lower values
    result in higher quality and larger file sizes. Valid range is 1-51, with
    17 being a good balance between quality and size (default).

.PARAMETER EncoderPreset
    The encoding preset for the final H.265 encoding. Valid values are:
    - medium: Balanced speed and compression (default).
    - slow: Slower encoding with better compression.
    - slower: Even slower encoding with better compression.
    - veryslow: Slowest encoding with best compression. 

.PARAMETER KeepIntermediate
    If specified, the intermediate file created by Video2X will be retained
    after the script completes. Otherwise, it will be deleted.

.EXAMPLE
    .\Upscale-Video.ps1 -InputFile ".\input.mp4"

.EXAMPLE
    .\Upscale-Video.ps1 -InputFile ".\input.mp4" -OutputFile ".\upscaled.mp4" -Sharpen Medium

.NOTES
    Apart from FFMPEG and FFPROBE, you also need to have Video2X installed and configured with the Real-ESRGAN model. Adjust the TOOL PATHS section in the script to point to the correct locations of these executables on your system.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputFile,

    [Parameter(Position = 1)]
    [string]$OutputFile,

    [ValidateSet('Off', 'Low', 'Medium', 'High')]
    [string]$Sharpen = 'Medium',

    [ValidateRange(1, 51)]
    [int]$Crf = 17,

    [ValidateSet('medium', 'slow', 'slower', 'veryslow')]
    [string]$EncoderPreset = 'slow',

    [switch]$KeepIntermediate,

    [Alias("?", "h")]
    [switch]$Help

)

Import-Module "$PSScriptRoot\VideoToolsCommon.psm1"
if ($Help -or -not $InputFile) {
    # Showing help for incomplete input makes the script easier to discover
    # interactively and avoids running FFmpeg with missing paths.
    Show-Help -ScriptPath $PSCommandPath
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# TOOL PATHS: EDIT THESE THREE VALUES FOR YOUR COMPUTER
# ============================================================================
$Tools = Initialize-VideoTools
$FfmpegPath  = Join-Path $Tools.FFmpegBin'ffmpeg.exe'
$FfprobePath = Join-Path $Tools.FFmpegBin 'ffprobe.exe'
$Video2XPath = 'D:\Portable\Video2X-AI\video2x.exe'
# ============================================================================

# Real-ESRGAN settings
$RealEsrganModel = 'realesrgan-plus'
$AiScale = 4
$TargetHeight = 1080

function Assert-Executable {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name was not found at: $Path`nEdit the TOOL PATHS section near the top of this script."
    }
}

function Invoke-NativeTool {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Host "`n$Description" -ForegroundColor Cyan
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

Assert-Executable -Path $FfmpegPath  -Name 'FFmpeg'
Assert-Executable -Path $FfprobePath -Name 'FFprobe'
Assert-Executable -Path $Video2XPath -Name 'Video2X'

$InputFile = (Resolve-Path -LiteralPath $InputFile).Path
$InputItem = Get-Item -LiteralPath $InputFile

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $InputItem.DirectoryName ($InputItem.BaseName + '_upscaled_1080p.mkv')
} elseif (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = Join-Path (Get-Location).Path $OutputFile
}
$OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

if ($OutputFile -eq $InputFile) {
    throw 'OutputFile must be different from InputFile.'
}

$OutputDirectory = Split-Path -Parent $OutputFile
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

# Read the source dimensions. sample_aspect_ratio is used so anamorphic video
# is converted to its true display aspect ratio before producing square pixels.
$ProbeJson = & $FfprobePath -v error -select_streams v:0 `
    -show_entries stream=width,height,sample_aspect_ratio,display_aspect_ratio `
    -of json -- $InputFile
if ($LASTEXITCODE -ne 0) { throw 'FFprobe could not read the input video.' }

$Probe = $ProbeJson | ConvertFrom-Json
if (-not $Probe.streams -or $Probe.streams.Count -lt 1) {
    throw 'No video stream was found in the input file.'
}

$Stream = $Probe.streams[0]
$SourceWidth  = [int]$Stream.width
$SourceHeight = [int]$Stream.height

# Calculate the expected output width for display. FFmpeg will perform the
# authoritative resize with force_original_aspect_ratio=decrease and setsar=1.
$SarNumerator = 1.0
$SarDenominator = 1.0
if ($Stream.sample_aspect_ratio -and $Stream.sample_aspect_ratio -ne 'N/A' -and $Stream.sample_aspect_ratio -match '^(\d+):(\d+)$') {
    $SarNumerator = [double]$Matches[1]
    $SarDenominator = [double]$Matches[2]
}
$DisplayAspect = ($SourceWidth * ($SarNumerator / $SarDenominator)) / $SourceHeight
$ExpectedWidth = [int](2 * [math]::Round(($TargetHeight * $DisplayAspect) / 2))

$SharpenAmount = @{
    Off    = $null
    Low    = '0.30'
    Medium = '0.55'
    High   = '0.80'
}[$Sharpen]

$TempFile = Join-Path $OutputDirectory ($InputItem.BaseName + '.video2x-intermediate.' + [guid]::NewGuid().ToString('N') + '.mkv')

Write-Host 'Video enhancement plan' -ForegroundColor Green
Write-Host "  Input:              $SourceWidth x $SourceHeight"
Write-Host "  Final target:       approximately $ExpectedWidth x $TargetHeight"
Write-Host '  Aspect handling:    preserve only (no crop, no pad, no stretch)'
Write-Host "  Sharpening:         $Sharpen"
Write-Host "  Real-ESRGAN model:  $RealEsrganModel"
Write-Host "  Output:             $OutputFile"

Read-Host -Prompt "Press any key to continue or <ctrl>+C to cancel..."
try {
    # Stage 1: Real-ESRGAN enhancement at its native 4x scale.
    $Video2XArgs = @(
        '-i', $InputFile,
        '-o', $TempFile,
        '-p', 'realesrgan',
        '-s', "$AiScale",
        '--realesrgan-model', $RealEsrganModel,
        '-c', 'libx264',
        '-e', 'crf=16',
        '-e', 'preset=slow'
    )

    Write-Host "`nStage 1 of 2: AI enhancement with Video2X/Real-ESRGAN" `
        -ForegroundColor Cyan

    # Video2X sometimes outputs a non-zero exit code even when it successfully produces a valid video. 
    # We will validate the output with FFprobe before deciding whether to continue or abort.
    & $Video2XPath @Video2XArgs
    $Video2XExitCode = $LASTEXITCODE

    if ($Video2XExitCode -ne 0) {

        Write-Warning "Video2X returned exit code $Video2XExitCode."

        # -----------------------------------------------------------
        # Video2X occasionally terminates abnormally after processing.
        # Do NOT blindly ignore the exit code.
        # Validate the output with FFprobe before continuing.
        # -----------------------------------------------------------

        if (-not (Test-Path -LiteralPath $TempFile -PathType Leaf)) {
            throw "Video2X failed and no intermediate video was created."
        }

        Write-Host "Validating Video2X intermediate..." `
            -ForegroundColor Yellow

        $ValidationJson = & $FfprobePath `
            -v error `
            -select_streams v:0 `
            -show_entries stream=codec_name,width,height `
            -show_entries format=duration,size `
            -of json `
            -- $TempFile

        if ($LASTEXITCODE -ne 0) {
            throw "FFprobe could not read the Video2X intermediate."
        }

        $Validation = $ValidationJson | ConvertFrom-Json

        if (-not $Validation.streams -or
            $Validation.streams.Count -eq 0) {

            throw "Video2X intermediate contains no valid video stream."
        }

        $ValidatedStream = $Validation.streams[0]

        if ([double]$Validation.format.duration -le 0) {
            throw "Video2X intermediate has an invalid duration."
        }

        Write-Warning `
            "Video2X exited abnormally, but its output passed FFprobe validation."

        Write-Host "Validated intermediate:" -ForegroundColor Green
        Write-Host "  Codec:      $($ValidatedStream.codec_name)"
        Write-Host "  Resolution: $($ValidatedStream.width) x $($ValidatedStream.height)"
        Write-Host "  Duration:   $($Validation.format.duration) seconds"
        Write-Host "  Size:       $($Validation.format.size) bytes"
        Write-Host ""
        Write-Host "Continuing with Stage 2..." -ForegroundColor Green
    }    

    # Stage 2: Preserve aspect ratio, downsample to 1080 pixels high with
    # Lanczos, convert to square pixels, and apply controlled luma sharpening.
    $Filters = @(
        "scale=-2:${TargetHeight}:flags=lanczos:force_original_aspect_ratio=decrease",
        'setsar=1'
    )
    if ($null -ne $SharpenAmount) {
        $Filters += "unsharp=5:5:${SharpenAmount}:5:5:0"
    }
    $VideoFilter = $Filters -join ','

    $FfmpegArgs = @(
        '-hide_banner',
        '-y',
        '-i', $TempFile,
        '-map', '0:v:0',
        '-map', '0:a?',
        '-map_metadata', '0',
        '-vf', $VideoFilter,
        '-c:v', 'libx265',
        '-preset', $EncoderPreset,
        '-crf', "$Crf",
        '-pix_fmt', 'yuv420p',
        '-c:a', 'copy',
        $OutputFile
    )
    Invoke-NativeTool -Executable $FfmpegPath -Arguments $FfmpegArgs `
        -Description 'Stage 2 of 2: aspect-preserved resize, sharpening and final encoding'

    Write-Host "`nCompleted successfully: $OutputFile" -ForegroundColor Green
}
finally {
    if (-not $KeepIntermediate -and (Test-Path -LiteralPath $TempFile)) {
        Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
    } elseif ($KeepIntermediate -and (Test-Path -LiteralPath $TempFile)) {
        Write-Host "Intermediate retained: $TempFile" -ForegroundColor Yellow
    }
}
