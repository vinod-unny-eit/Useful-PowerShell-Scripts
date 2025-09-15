# Search for duplicate files in a specified directory and its subdirectories
param(
    [Parameter(Position = 0, HelpMessage = 'Path to search for duplicate files')]
    [string]
    $Path = ".",

    [Parameter(HelpMessage = 'If true, search subfolders recursively')]
    [bool]
    $Recurse = $true
)

if (-not (Test-Path -Path $Path)) {
    Write-Error "Path '$Path' not found or is not accessible."
    exit 1
}

$gciParams = @{ Path = $Path; File = $true }
if ($Recurse) { $gciParams.Recurse = $true }

Get-ChildItem @gciParams | 
    Group-Object Length | 
    Where-Object { $_.Count -gt 1 } | 
    ForEach-Object { $_.Group | Get-FileHash -Algorithm SHA256 } | 
    Group-Object Hash | 
    Where-Object { $_.Count -gt 1 } | 
    ForEach-Object {
        Write-Host "Duplicate files (hash: $($_.Name)):" -ForegroundColor Yellow
        $_.Group | ForEach-Object { Write-Host "  " $_.Path }
        Write-Host "---"
    }