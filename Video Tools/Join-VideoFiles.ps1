<#
.SYNOPSIS
    Combines multiple video files into one file using ffmpeg.

.DESCRIPTION
    Checks the audio and video stream properties of each input. Compatible
    inputs are combined directly; incompatible inputs are first normalized to
    common video and audio properties. The final output is H.265 in an MKV
    container. Input files are sorted naturally by filename, so numeric
    portions are ordered as 1, 2, 10, 11.
    The source can be a folder or a wildcard path. Files are combined in
    natural filename order, which treats embedded numbers numerically.

.PARAMETER Source
    Path to a source folder or a wildcard path.
    - A folder includes supported video files directly inside that folder.
    - A wildcard path includes all matching supported video files.

.PARAMETER Destination
    Path to a destination folder or file.
    - If a folder, the output is saved as CombinedVideo.mkv inside it.
    - If a file, it must have a .mkv extension and is saved to that exact path.

.EXAMPLES
    Combine all supported videos in a folder:
        .\Join-VideoFiles.ps1 -Source "C:\Videos" -Destination "D:\Output"

    Combine files selected by a wildcard:
        .\Join-VideoFiles.ps1 -Source "C:\Videos\Part-*.mp4" -Destination "D:\Output\FullVideo.mkv"

.NOTES
    - Ensure that ffmpeg is installed and its path is correctly set in the script.
    - FFmpeg's concat demuxer requires matching stream layouts and properties.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Source,

    [Parameter(Position = 1)]
    [string]$Destination,

    [Alias("?", "h")]
    [switch]$Help
)
Import-Module "$PSScriptRoot\VideoToolsCommon.psm1"
if ($Help -or -not $Source -or -not $Destination) {
    # Showing help for incomplete input makes the script easier to discover
    # interactively and avoids running FFmpeg with missing paths.
    Show-Help -ScriptPath $PSCommandPath
    exit 0
}

# Keep the FFmpeg tools together so the script can use a portable installation
# and so ffmpeg and ffprobe are guaranteed to come from the same distribution.
$Tools = Initialize-VideoTools
$FFmpegBin = $Tools.FFmpegBin
$FFmpegExe = Join-Path $FFmpegBin "ffmpeg.exe"
$FFprobeExe = Join-Path $FFmpegBin "ffprobe.exe"
$videoExtensions = @(".mp4", ".m4v", ".mkv", ".avi", ".mov", ".wmv", ".ts", ".webm", ".m2ts")

# Fail early with an actionable message instead of producing a less clear
# command-not-found error later in the processing pipeline.
if (-not (Test-Path -LiteralPath $FFmpegExe -PathType Leaf)) {
    throw "FFmpeg was not found at '$FFmpegExe'. Update the FFmpeg path in this script."
}
if (-not (Test-Path -LiteralPath $FFprobeExe -PathType Leaf)) {
    throw "FFprobe was not found at '$FFprobeExe'. Update the FFmpeg path in this script."
}

$sourceFolder = Test-Path -LiteralPath $Source -PathType Container
$sourceFiles = @()

if ($sourceFolder) {
    # A directory source is intentionally limited to files in that directory;
    # subdirectories are not searched unless the caller supplies a wildcard
    # pattern that explicitly selects them.
    $sourceFiles = Get-ChildItem -LiteralPath $Source -File |
        Where-Object { $videoExtensions -contains $_.Extension.ToLowerInvariant() }
}
else {
    # Get-ChildItem expands wildcard sources. Suppressing its lookup error lets
    # the common "no matching files" case reach the clearer validation below.
    $sourceFiles = Get-ChildItem -Path $Source -File -ErrorAction SilentlyContinue |
        Where-Object { $videoExtensions -contains $_.Extension.ToLowerInvariant() }
}

function Get-NaturalSortKey {
    param([string]$Name)

    # Pad each numeric portion to a fixed width so ordinary string sorting
    # places "Part 10" after "Part 2" instead of after "Part 1".
    [regex]::Replace($Name, "\d+", {
        param($match)
        $match.Value.PadLeft(20, "0")
    })
}

$sourceFiles = @($sourceFiles | Sort-Object `
    @{ Expression = { Get-NaturalSortKey $_.Name } }, `
    @{ Expression = { $_.Name } }, `
    @{ Expression = { $_.FullName } })
if ($sourceFiles.Count -eq 0) {
    # Do not create an empty concat list; an empty input set is not a valid
    # video and usually indicates a typo in the source path or wildcard.
    throw "No supported video files were found for source '$Source'."
}

# An existing directory is unambiguously a folder destination. For a path that
# does not exist, a file extension is used to distinguish a filename from a
# directory that still needs to be created.
$destinationExistsAsFolder = Test-Path -LiteralPath $Destination -PathType Container
$destinationExtension = [IO.Path]::GetExtension($Destination)
$destinationIsFile = -not $destinationExistsAsFolder -and ($destinationExtension -ne "")

if ($destinationIsFile) {
    $outputFile = [IO.Path]::GetFullPath($Destination)
    $outputFolder = Split-Path -Parent $outputFile

    # The output is always encoded into an MKV container, so reject misleading
    # extensions rather than silently writing MKV data to another filename.
    if ([IO.Path]::GetExtension($outputFile).ToLowerInvariant() -ne ".mkv") {
        throw "The destination filename must have a .mkv extension."
    }
}
else {
    $outputFolder = [IO.Path]::GetFullPath($Destination)
    $outputFile = Join-Path $outputFolder "CombinedVideo.mkv"
}

if (-not (Test-Path -LiteralPath $outputFolder -PathType Container)) {
    # Create only the requested destination folder hierarchy.
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
}

# Resolve all source paths before invoking external tools so the concat list
# remains stable even if the current working directory changes.
$sourcePaths = @($sourceFiles | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
if ($sourcePaths | Where-Object { $_.Equals($outputFile, [StringComparison]::OrdinalIgnoreCase) }) {
    # Prevent an existing output from being fed back into itself on a later run.
    throw "The destination file cannot also be one of the source files."
}

# These unique temporary paths avoid collisions with other script instances.
$concatList = Join-Path ([IO.Path]::GetTempPath()) ("ffmpeg-concat-{0}.txt" -f [Guid]::NewGuid())
$normalizationFolder = Join-Path ([IO.Path]::GetTempPath()) ("ffmpeg-normalized-{0}" -f [Guid]::NewGuid())

function Get-StreamInfo {
    param([string]$Path)

    # FFprobe returns structured stream metadata, which is more reliable than
    # parsing human-readable FFmpeg console output.
    $json = & $FFprobeExe -v error -show_streams -of json $Path
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "FFprobe could not read '$Path'."
    }

    $probe = $json | ConvertFrom-Json
    # The first video and audio streams define the streams used by this script.
    # Audio is optional because some video files contain no audio stream.
    $video = @($probe.streams | Where-Object { $_.codec_type -eq "video" })[0]
    $audio = @($probe.streams | Where-Object { $_.codec_type -eq "audio" })[0]
    if (-not $video) {
        throw "No video stream was found in '$Path'."
    }

    # Store the original stream objects for normalization and a compact
    # comparison signature for deciding whether direct concatenation is safe.
    [pscustomobject]@{
        Video = $video
        Audio = $audio
        Signature = [pscustomobject]@{
            VideoCodec = $video.codec_name
            Width = $video.width
            Height = $video.height
            PixelFormat = $video.pix_fmt
            FrameRate = $video.avg_frame_rate
            AudioCodec = if ($audio) { $audio.codec_name } else { "" }
            SampleRate = if ($audio) { $audio.sample_rate } else { "" }
            Channels = if ($audio) { $audio.channels } else { "" }
            ChannelLayout = if ($audio) { $audio.channel_layout } else { "" }
        }
    }
}

try {
    # Show the exact order selected by the natural sort before any media work
    # begins, allowing the user to spot an unexpected filename order.
    Write-Host "Input file order:" -ForegroundColor Cyan
    for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
        Write-Host ("  {0}. {1}" -f ($index + 1), $sourceFiles[$index].Name)
    }

    Write-Host "Checking stream compatibility..."
    # Compare every input with the first file. The concat demuxer requires
    # matching stream characteristics, not merely matching file extensions.
    $streamInfo = @($sourcePaths | ForEach-Object { Get-StreamInfo $_ })
    $referenceSignature = $streamInfo[0].Signature | ConvertTo-Json -Compress
    $inputsAreCompatible = @($streamInfo | Where-Object {
        (($_.Signature | ConvertTo-Json -Compress) -ne $referenceSignature)
    }).Count -eq 0

    # Compatible files can be passed directly to concat; otherwise all files
    # use the same normalized representation before they are joined.
    $concatPaths = $sourcePaths
    if (-not $inputsAreCompatible) {
        Write-Host "Input streams are incompatible; normalizing all inputs before concatenation." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $normalizationFolder -Force | Out-Null

        # Use the first file's dimensions as the common target. The filter
        # preserves aspect ratio, pads to a consistent frame size, resets the
        # sample aspect ratio, and establishes a constant frame rate.
        $referenceVideo = $streamInfo[0].Video
        $targetWidth = [int]$referenceVideo.width
        $targetHeight = [int]$referenceVideo.height
        if ($targetWidth % 2 -ne 0) { $targetWidth-- }
        if ($targetHeight % 2 -ne 0) { $targetHeight-- }
        $videoFilter = "scale=${targetWidth}:${targetHeight}:force_original_aspect_ratio=decrease,pad=${targetWidth}:${targetHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30"

        $concatPaths = @()
        for ($index = 0; $index -lt $sourcePaths.Count; $index++) {
            # Numbered temporary files preserve the already-selected input
            # order when the normalized files are written.
            $normalizedPath = Join-Path $normalizationFolder ("input-{0:D4}.mkv" -f $index)
            $arguments = @("-hide_banner", "-loglevel", "error", "-i", $sourcePaths[$index])
            if ($streamInfo[$index].Audio) {
                # Re-encode the video and audio to one common stream layout.
                $arguments += @("-map", "0:v:0", "-map", "0:a:0", "-vf", $videoFilter,
                    "-c:v", "hevc_nvenc", "-preset", "medium", "-cq", "30",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", "-y", $normalizedPath)
            }
            else {
                # Supply silent stereo AAC when an input has no audio, ensuring
                # every normalized file has the same audio stream structure.
                $arguments += @("-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                    "-map", "0:v:0", "-map", "1:a:0", "-vf", $videoFilter,
                    "-c:v", "hevc_nvenc", "-preset", "medium", "-cq", "30",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", "-shortest", "-y", $normalizedPath)
            }

            & $FFmpegExe @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "FFmpeg failed while normalizing '$($sourceFiles[$index].Name)' with exit code $LASTEXITCODE."
            }
            $concatPaths += $normalizedPath
        }
    }

    # The concat demuxer reads one "file" directive per line. Escape embedded
    # single quotes so paths remain valid even when filenames contain them.
    $listLines = $concatPaths | ForEach-Object {
        $escapedPath = $_ -replace "'", "'\''"
        "file '$escapedPath'"
    }
    Set-Content -LiteralPath $concatList -Value $listLines -Encoding ASCII

    # The final pass creates the requested H.265 MKV. Audio is copied here
    # because it was already normalized when normalization was necessary.
    Write-Host "Combining $($sourceFiles.Count) video files into '$outputFile'..."
    & $FFmpegExe -hide_banner -loglevel error -f concat -safe 0 -i $concatList `
        -c:v hevc_nvenc -preset medium -cq 30 -rc-lookahead 10 -c:a copy -y $outputFile

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg failed with exit code $LASTEXITCODE."
    }

    Write-Host "Combined video saved to '$outputFile'." -ForegroundColor Green
}
finally {
    # Always remove temporary concat metadata and normalized media, including
    # when FFprobe or FFmpeg reports an error.
    if (Test-Path -LiteralPath $concatList) {
        Remove-Item -LiteralPath $concatList -Force
    }
    if (Test-Path -LiteralPath $normalizationFolder) {
        Remove-Item -LiteralPath $normalizationFolder -Recurse -Force
    }
}