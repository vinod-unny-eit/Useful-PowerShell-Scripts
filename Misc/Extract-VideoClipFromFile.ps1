<#
.SYNOPSIS
    Video Clip Extractor using ffmpeg with NVENC H.265 encoding.

.DESCRIPTION
    Extracts clip from video files using ffmpeg and converts them to MKV format. 
    Supports flexible source/destination combinations with conditional downscaling to 1080p.

.PARAMETER Source
    Path to a source video file.

.PARAMETER Destination
    Path to a destination file or folder.
    - If a folder, converted files are placed inside with .mkv extension.
    - If a file, the source file is converted to that exact file name.

.PARAMETER StartTime
    Start time of the clip to extract (format: HH:MM:SS).

.PARAMETER EndTime
    End time of the clip to extract (format: HH:MM:SS).

.EXAMPLES
    Extract a clip from a video file and save it to a folder:
        .\Convert.ps1 -Source "C:\Videos\movie.mp4" -Destination "D:\Converted" -StartTime "00:01:00" -EndTime "00:02:00"

    Extract a clip from a video file and save it to a specific file name:
        .\Convert.ps1 -Source "C:\Videos\movie.mp4" -Destination "D:\Converted\movie_clip.mkv" -StartTime "00:01:00" -EndTime "00:02:00"

.NOTES
    - Ensure that ffmpeg is installed and its path is correctly set in the script
#>

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [string]$StartTime,
    [string]$EndTime,
    [Alias("?", "h")]
    [switch]$Help
)

function Show-Help {
    # Read the script file and print only the help block
    $lines = Get-Content $PSCommandPath
    $inHelp = $false
    foreach ($line in $lines) {
        if ($line -match '^<#$') { $inHelp = $true; continue }
        if ($line -match '^#>$') { $inHelp = $false; break }
        if ($inHelp) { Write-Host $line -ForegroundColor Cyan }
    }
}

# If help requested or parameters missing, show help
if ($Help -or -not $Source -or -not $Destination) {
    Show-Help
    exit
}

# If help requested or parameters missing, show help
if ($Help -or $PSBoundParameters.ContainsKey('?') -or -not $Source -or -not $Destination) {
    Show-Help
    exit
}

# Path to FFmpeg bin folder
$FFmpegBin = "D:\Portable\ffmpeg\bin"
$FFmpegExe = Join-Path $FFmpegBin "ffmpeg.exe"


$sourceIsFile = Test-Path $Source -PathType Leaf
$destIsFile = $Destination.EndsWith("mkv")
$destIsFolder = -not $destIsFile

if (-not $sourceIsFile) {
    Write-Host "Error: Cannot use a FOLDER as source. This can extract a clip only from a single file." -ForegroundColor Red
    exit
}

if ($StartTime -eq $null -or $EndTime -eq $null) {
    Write-Host "Error: StartTime and EndTime parameters are required." -ForegroundColor Red
    exit
}

# Ensure destination folder exists if needed
if ($destIsFolder -and -not (Test-Path $destFolder)) {
    New-Item -ItemType Directory -Path $destFolder | Out-Null
}

$file = Get-Item $Source
if ($destIsFolder) {
        $outfile = Join-Path $Destination ($file.BaseName + ".mkv")
    } else {
        $outfile = $Destination
    }
& $FFmpegExe -i $Source -ss $StartTime -to $EndTime -c:v hevc_nvenc -preset slow -b:v 5M -c:a copy -y $outfile