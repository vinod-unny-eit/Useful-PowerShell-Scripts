<#
.SYNOPSIS
    Download entire video or short clips from web sources using ffmpeg into MKV.

.DESCRIPTION
    Downloads video files from web sources using ffmpeg and converts them to MKV format. 
    You can optionally extract clips from the video by specifying start and end times. 
    Supports flexible source/destination combinations with conditional downscaling to 1080p.

.PARAMETER URL
    URL of the source video file.

.PARAMETER Destination
    Path to a destination file or folder.
    - Default is the current directory if not specified.
    - If a folder, converted files are placed inside with .mkv extension.
    - If a file, the source file is converted to that exact file name.

.PARAMETER StartTime
    (Optional) Start time of the clip to extract (format: HH:MM:SS).

.PARAMETER EndTime
    (Optional) End time of the clip to extract (format: HH:MM:SS).

.EXAMPLES
    Download a video file from a URL and save it to a folder:
        .\Download-VideoFromWeb.ps1 -URL "https://example.com/video.mp4" -Destination "D:\Downloaded" 

    Extract a clip from a video URL and save it to a specific file name:
        .\Download-VideoFromWeb.ps1 -URL "https://example.com/video.mp4" -Destination "D:\Downloaded\video_clip.mkv" -StartTime "00:01:00" -EndTime "00:02:00"

.NOTES
    - Ensure that ffmpeg and yt-dlp are installed and their paths are correctly set in the script.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$URL,

    [Parameter()]
    [string]$Destination,

    [Parameter()]
    [string]$StartTime,

    [Parameter()]
    [string]$EndTime,

    [Parameter()]
    [Alias("?", "h")]
    [switch]$Help
)
Import-Module "$PSScriptRoot\VideoToolsCommon.psm1"

# If help is requested or required parameters are missing, show help
if ($Help -or -not $URL -or $PSBoundParameters.ContainsKey('?')) {
    Show-Help -ScriptPath $PSCommandPath
    exit
}

$Tools = Initialize-VideoTools
$FFmpegBin = $Tools.FFmpegBin
$FFmpegExe = Join-Path $FFmpegBin "ffmpeg.exe"
$YTDownloaderExe = Join-Path $Tools.YtDlpBin "yt-dlp.exe"
$Destination = if ($Destination) { $Destination } else { Get-Location }
$destIsFile = $Destination.EndsWith("mkv")

# Download a list of available formats for given video URL
Write-Host "Downloading list of available formats for this video..."
$info = & "$YTDownloaderExe" --no-warnings -j $URL | ConvertFrom-Json
$title = $info.title

# Extract the relevant data into fields
$formats = $info.formats | ForEach-Object {
    [pscustomobject]@{
        ID         = $_.format_id
        Extension  = $_.ext
        Resolution = $_.resolution
        Note       = $_.format_note
    }
}

# Allow user to choose an audio and video format to download and merge
Write-Host "Select formats you wish to download and merge (one Audio & one Video)..."
$selectedFormats = $formats | Out-GridView -Title "Select Formats to Download" -PassThru 


# If the user clicked OK, check if any formats were selected
if ($selectedFormats) {
    
    # Check if the destination is a folder or file and create the folder if it doesn't exist
    if(-not $destIsFile -and -not (Test-Path $Destination)) {
        Write-Host "Destination folder does not exist. Creating it..."
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    if($destIsFile) {
        $Outfile = $Destination
    } else {
        $Outfile = Join-Path $Destination "$title.mkv"
    }

    # Join the formats with a "+"
    $selectedIDs = $selectedFormats.ID -join "+"
    Write-Host "You selected format IDs: $selectedIDs"
    # Download the formats and merge them
    if($StartTime -ne $null -and $StartTime -ne "") {
	    Write-Host "Attempting to download CLIP between $startTime and $EndTime and merge formats..."
	    $output = & "$YTDownloaderExe" --ffmpeg-location $FFmpegBin --no-warnings -q --print after_move:filepath --cookies $PSScriptRoot'\YTCookies.txt'     --download-sections "*$StartTime-$EndTime" -f "$SelectedIDs" --merge-output-format mkv --recode-video mkv --postprocessor-args "ffmpeg:-c:v hevc_nvenc -preset fast -b:v 5M -c:a copy" -o $Outfile $URL
    }
    else {
	    Write-Host "Attempting to download and merge formats..."
	    $output = & "$YTDownloaderExe" --ffmpeg-location $FFmpegBin --no-warnings -q --print after_move:filepath --cookies $PSScriptRoot'\YTCookies.txt' -f "$SelectedIDs" --merge-output-format mkv --recode-video mkv --postprocessor-args "ffmpeg:-c:v hevc_nvenc -preset fast -b:v 5M -c:a copy" -o $Outfile $URL
    }

    # Display the full path to the downloaded video file
    $filename = ($output -split '`n')[-1]   #output has a number of lines. Get the last one for the actual filename.
    Write-Host "File saved to: " -NoNewLine
    Write-Host $filename -ForegroundColor Green
} else {
    Write-Host "No formats were selected."
}
