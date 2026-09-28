function Initialize-VideoTools {

    Write-Host ""
    Write-Host "Checking required video tools..." -ForegroundColor Cyan

    # Determine drive
    $DriveRoot = if (Test-Path "D:\") { "D:" } else { "C:" }

    Write-Host "Using drive: $DriveRoot" -ForegroundColor Yellow

    $PortableRoot = Join-Path $DriveRoot "Portable"

    $FFmpegFolder = Join-Path $PortableRoot "FFMPEG"
    $YtDlpFolder  = Join-Path $PortableRoot "YT-DLP"

    if (-not (Test-Path $PortableRoot)) {
        New-Item -ItemType Directory -Path $PortableRoot -Force | Out-Null
    }

    #
    # Install FFmpeg if missing
    #
    if (-not (Test-Path $FFmpegFolder)) {

        Write-Host ""
        Write-Host "FFmpeg not found." -ForegroundColor Yellow
        Write-Host "Downloading and installing FFmpeg..." -ForegroundColor Cyan

        $ZipFile = Join-Path $env:TEMP "ffmpeg.zip"

        Invoke-WebRequest `
            -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" `
            -OutFile $ZipFile

        $TempExtract = Join-Path $env:TEMP "ffmpeg_extract"

        if (Test-Path $TempExtract) {
            Remove-Item $TempExtract -Recurse -Force
        }

        Expand-Archive $ZipFile $TempExtract

        $ExtractedFolder = Get-ChildItem $TempExtract -Directory |
                           Select-Object -First 1

        Move-Item $ExtractedFolder.FullName $FFmpegFolder

        Remove-Item $ZipFile -Force
        Remove-Item $TempExtract -Recurse -Force

        Write-Host "FFmpeg installation complete." -ForegroundColor Green
    }
    else {
        Write-Host "FFmpeg already installed." -ForegroundColor Green
    }

    #
    # Install yt-dlp if missing
    #
    if (-not (Test-Path $YtDlpFolder)) {

        Write-Host ""
        Write-Host "yt-dlp not found." -ForegroundColor Yellow
        Write-Host "Downloading and installing yt-dlp..." -ForegroundColor Cyan

        New-Item `
            -ItemType Directory `
            -Path $YtDlpFolder `
            -Force | Out-Null

        $YtDlpExe = Join-Path $YtDlpFolder "yt-dlp.exe"

        Invoke-WebRequest `
            -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
            -OutFile $YtDlpExe

        Write-Host "yt-dlp installation complete." -ForegroundColor Green
    }
    else {
        Write-Host "yt-dlp already installed." -ForegroundColor Green
    }

    #
    # Return base folders
    #
    $FFmpegBin = Join-Path $FFmpegFolder "bin"
    $YtDlpBin = $YtDlpFolder

    Write-Host ""
    Write-Host "All required tools are available." -ForegroundColor Green
    Write-Host ""

    return @{
        Drive  = $DriveRoot
        FFmpegBin = $FFmpegBin
        YtDlpBin  = $YtDlpBin
    }
}

function Show-Help {
    param([Parameter(Mandatory)][string]$ScriptPath)
    # Read the script file and print only the help block
    $lines = Get-Content -LiteralPath $ScriptPath
    $inHelp = $false
    foreach ($line in $lines) {
        if ($line -match '^<#$') { $inHelp = $true; continue }
        if ($line -match '^#>$') { $inHelp = $false; break }
        if ($inHelp) { Write-Host $line -ForegroundColor Cyan }
    }
}
Export-ModuleMember -Function Initialize-VideoTools
Export-ModuleMember -Function Show-Help