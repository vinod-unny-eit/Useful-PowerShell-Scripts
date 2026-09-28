<#
.SYNOPSIS
    Video batch converter using ffmpeg with NVENC H.265 encoding.

.DESCRIPTION
    Converts video files using ffmpeg. Supports flexible source/destination
    combinations with conditional downscaling to 1080p.

.PARAMETER Source
    Path to a source file or folder.
    - If a folder, all video files inside are processed.
    - If a file, only that file is processed.

.PARAMETER Destination
    Path to a destination file or folder.
    - If a folder, converted files are placed inside with .mkv extension.
    - If a file, the source file is converted to that exact file name.

.EXAMPLES
    Convert all files in a folder to another folder:
        .\Convert.ps1 -Source "C:\Videos" -Destination "D:\Converted"

    Convert a single file to a folder:
        .\Convert.ps1 -Source "C:\Videos\movie.mp4" -Destination "D:\Converted"

    Convert a single file to a specific file name:
        .\Convert.ps1 -Source "C:\Videos\movie.mp4" -Destination "D:\Converted\movie_new.mkv"

.NOTES
    Rule restrictions:
    - Source folder + Destination file → ❌ Not allowed.
    - All other combinations are valid.
    Ensure that ffmpeg is installed and its path is correctly set in the script.
#>

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [Alias("?", "h")]
    [switch]$Help
)
Import-Module "$PSScriptRoot\VideoToolsCommon.psm1"

# If help requested or parameters missing, show help
if ($Help -or -not $Source -or -not $Destination) {
    Show-Help -ScriptPath $PSCommandPath
    exit
}

# If help requested or parameters missing, show help
if ($Help -or $PSBoundParameters.ContainsKey('?') -or -not $Source -or -not $Destination) {
    Show-Help -ScriptPath $PSCommandPath
    exit
}

# Path to FFmpeg bin folder
$Tools = Initialize-VideoTools
$FFmpegBin = $Tools.FFmpegBin
$FFmpegExe = Join-Path $FFmpegBin "ffmpeg.exe"
$FFprobeExe = Join-Path $FFmpegBin "ffprobe.exe"
$progressFile = "$env:TEMP\progress.txt"
$duration = 0

# Validate source and destination
$sourceIsFile = Test-Path $Source -PathType Leaf
$sourceIsFolder = Test-Path $Source -PathType Container
$destIsFile = $Destination.EndsWith("mkv")
$destIsFolder = -not $destIsFile

if ($sourceIsFolder -and $destIsFile) {
    Write-Host "❌ Invalid combination: Source is a folder but destination is a file." -ForegroundColor Red
    Show-Help
    exit
}

# Build file list and destination mapping
$files = @()
if ($sourceIsFolder -and $destIsFolder) {
    # Rule 1: Source folder → Destination folder
    Write-Host "✔️ Converting from Source folder ➡️ Destination folder." -ForegroundColor Yellow
    $files = Get-ChildItem -Path $Source\* -Include *.mp4, *.avi, *.mov, *.wmv, *.ts, *.webm -File
    $destFolder = $Destination
}
elseif ($sourceIsFile -and $destIsFolder) {
    # Rule 2: Source file → Destination folder
    Write-Host "✔️ Converting from Source file ➡️ Destination folder." -ForegroundColor Yellow
    $files = @(Get-Item $Source)
    $destFolder = $Destination
}
elseif ($sourceIsFile -and $destIsFile) {
    # Rule 3: Source file → Destination file
    Write-Host "✔️ Converting from Source file ➡️ Destination file." -ForegroundColor Yellow
    $files = @(Get-Item $Source)
    $destFile = $Destination
}
else {
    Write-Host "❌ Invalid source/destination combination." -ForegroundColor Red
    Show-Help
    exit
}

# Ensure destination folder exists if needed
if ($destIsFolder -and -not (Test-Path $destFolder)) {
    New-Item -ItemType Directory -Path $destFolder | Out-Null
}

# Get all video files
#$files = Get-ChildItem -Path $SourceFolder\* -Include *.mp4, *.avi, *.mov, *.wmv, *.ts, *.webm -File

foreach ($file in $files) {
    if ($destIsFolder) {
        $outfile = Join-Path $destFolder ($file.BaseName + ".mkv")
    } else {
        $outfile = $destFile
    }

    # Get duration in seconds using ffprobe
    $durationRaw = & $FFprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)"
    [double]::TryParse($durationRaw, [ref]$duration) | Out-Null
    if (-not $duration -or $duration -le 0) { $duration = 1 }  # fallback
    
    # Track start time
    $startTime = Get-Date

    # Progress file
    if (Test-Path $progressFile) { Remove-Item $progressFile }

    # Start ffmpeg with progress redirected
    $process = Start-Process $FFmpegExe -ArgumentList @(
        "-hide_banner","-loglevel","quiet",
        "-i","`"$($file.FullName)`"",
        "-c:v","hevc_nvenc","-preset","medium","-cq","30","-rc-lookahead","10",
	"-vf","scale='if(gt(iw,1920),1920,iw)':'if(gt(ih,1080),1080,ih)'",
        "-c:a","copy",
        "-map_metadata","0","-map_chapters","0",
        "-progress","pipe:1",
        "`"$outfile`""
    ) -NoNewWindow -RedirectStandardOutput $progressFile -PassThru

    # Monitor progress
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 2
        if (Test-Path $progressFile) {
            $lines = Get-Content $progressFile
            $outTimeLine = ($lines | Where-Object {$_ -like "out_time=*"} | Select-Object -Last 1)	# get the latest time in file of conversion
            $speedLine   = ($lines | Where-Object {$_ -like "speed=*"} | Select-Object -Last 1)		# get the latest speed of conversion

            if ($outTimeLine) {
                $rawCurrent = $outTimeLine.Split("=")[1]
                $current_ms = 0
		$current_s = [TimeSpan]::Parse($rawCurrent).TotalSeconds	# Get time in seconds

                # Clamp current time
                if ($current_s -gt $duration) { $current_s = $duration }

                # Percent complete
                $percent = if ($duration -gt 0) {
                    [math]::Round(($current_s / $duration) * 100, 2)
                } else { 0 }

                # Parse speed safely
                $speed = 1.0
                if ($speedLine) {
                    $rawSpeed = $speedLine.Split("=")[1].TrimEnd("x")
                    $parsedSpeed = 0
                    if ([double]::TryParse($rawSpeed, [ref]$parsedSpeed)) {
                        if ($parsedSpeed -gt 0) { $speed = $parsedSpeed }
                    }
                }

                # ETA calculation
                $eta = ($duration - $current_s) / $speed
                if ($eta -lt 0) { $eta = 0 }

                # Format ETA as mm:ss
                $etaSpan = [TimeSpan]::FromSeconds($eta)
                $etaFormatted = "{0:mm\:ss}" -f $etaSpan

		# Colored output
		Write-Host $file.Name -ForegroundColor Cyan -NoNewline
		Write-Host " | " -NoNewline
		Write-Host ("{0}%" -f $percent) -ForegroundColor Magenta -NoNewline
		Write-Host " | " -NoNewline
		Write-Host ("ETA: {0}" -f $etaFormatted) -ForegroundColor Yellow -NoNewline
		Write-Host "`r" -NoNewline

            }
        }
    }

    # After completion
    $endTime = Get-Date
    $elapsed = $endTime - $startTime
    $elapsedFormatted = "{0:hh\:mm\:ss}" -f $elapsed

    # Final line after completion
    Write-Host -ForegroundColor Green ("{0} | 100% | Completed in $elapsedFormatted" -f $file.Name)
}
