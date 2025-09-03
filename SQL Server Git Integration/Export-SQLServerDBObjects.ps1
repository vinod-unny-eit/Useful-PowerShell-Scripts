param (
    [string]$ServerName = "localhost",
    [string]$DatabaseName,
    [string]$CommitMessage
)

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Validate inputs
if (-not $DatabaseName) {

    # Get list of user databases
    $databases = Invoke-Sqlcmd -ServerInstance $serverName -Database "master" -Query "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name" -TrustServerCertificate

    # Create form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select Database"
    $form.Size = New-Object System.Drawing.Size(300,150)
    $form.StartPosition = "CenterScreen"

    # Label
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose a database:"
    $label.Location = New-Object System.Drawing.Point(10,20)
    $label.Size = New-Object System.Drawing.Size(260,20)
    $form.Controls.Add($label)

    # Dropdown
    $dropdown = New-Object System.Windows.Forms.ComboBox
    $dropdown.Location = New-Object System.Drawing.Point(10,50)
    $dropdown.Size = New-Object System.Drawing.Size(260,20)
    $dropdown.DropDownStyle = "DropDownList"
    $databases | ForEach-Object { [void]$dropdown.Items.Add($_.name) }
    $dropdown.SelectedIndex = 0
    $form.Controls.Add($dropdown)

    # OK Button
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(100,80)
    $okButton.Size = New-Object System.Drawing.Size(75,23)
    $okButton.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $form.Controls.Add($okButton)

    # Show form and get selection
    $form.Topmost = $true
    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $DatabaseName = $dropdown.SelectedItem
        Write-Host "✅ Selected database: $DatabaseName"
    }
    else {
        Write-Host "❌ No database selected. Exiting."
        exit
    }
}

if (-not $CommitMessage) {
	$CommitMessage = [Microsoft.VisualBasic.Interaction]::InputBox(
 	   "Enter your Git commit message:",
	    "Commit Message",
	    "Updated schema"
	)
}

# Load SqlServer module and SMO types
Import-Module SqlServer -ErrorAction Stop
Add-Type -AssemblyName "Microsoft.SqlServer.Smo"

$OutputRoot = "D:\Projects\Databases\Git\$DatabaseName"

# Connect to SQL Server
$server = New-Object Microsoft.SqlServer.Management.Smo.Server($ServerName)
$database = $server.Databases[$DatabaseName]

if (-not $database) {
    Write-Error "❌ Database '$DatabaseName' not found on server '$ServerName'."
    return
}

# Create scripting options for tables with dependencies
$scriptingOptions = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
$scriptingOptions.IncludeIfNotExists = $true
$scriptingOptions.ClusteredIndexes = $true
$scriptingOptions.NonClusteredIndexes = $true
$scriptingOptions.DriAll = $true
$scriptingOptions.Triggers = $true
$scriptingOptions.Indexes = $true
$scriptingOptions.ScriptDrops = $false
$scriptingOptions.WithDependencies = $false

# Export tables with full structure
function Export-TablesWithDependencies {
    param (
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        [string]$OutputFolder,
        [Microsoft.SqlServer.Management.Smo.ScriptingOptions]$Options
    )

    $folderPath = Join-Path $OutputFolder "Tables"
    if (!(Test-Path $folderPath)) {
        New-Item -Path $folderPath -ItemType Directory | Out-Null
    }

    foreach ($table in $Database.Tables) {
        if ($table.IsSystemObject -eq $false) {
            # Generate script from table with options
            $script = ($table.Script($Options)-join "`r`n").Trim()           
            $safeName = "$($table.Schema)_$($table.Name).sql"
            $filePath = Join-Path $folderPath $safeName
            # Check if file exists and content is different before writing - useful for git tracking
            if (Test-Path $filePath) {
                # Read existing file as array of lines so that it's easier to compare with script output
                $existingLines = Get-Content $filePath
                # Join lines with CRLF to match SMO output
                $existingContent = ($existingLines -join "`r`n").Trim()
                if ($existingContent -ne $script) {
                    Set-Content -Path $filePath -Value $script -Encoding UTF8
                }
                else {
                    Write-Host "No changes for $safeName, skipping write."
                }
            } else {
                Set-Content -Path $filePath -Value $script -Encoding UTF8
            }
        }
    }
}

# Generic export function for other object types
function Export-DbObjects {
    param (
        [System.Collections.IEnumerable]$Objects,
        [string]$Subfolder
    )

    $folderPath = Join-Path $OutputRoot $Subfolder
    if (!(Test-Path $folderPath)) {
        New-Item -Path $folderPath -ItemType Directory | Out-Null
    }

    foreach ($obj in $Objects) {
        if ($obj.IsSystemObject -eq $false) {
            $script = ($obj.Script() -join "`r`n").Trim().Trim('"')
            $safeName = "$($obj.Schema)_$($obj.Name).sql"
            $filePath = Join-Path $folderPath $safeName
            # Check if file exists and content is different before writing - useful for git tracking
            if (Test-Path $filePath) {
                # Read existing file as array of lines so that it's easier to compare with script output
                $existingLines = Get-Content $filePath
                # Join lines with CRLF to match SMO output
                $existingContent = ($existingLines -join "`r`n").Trim()
                if ($existingContent -ne $script) {
                    Set-Content -Path $filePath -Value $script -Encoding UTF8
                }
                else {
                    Write-Host "No changes for $safeName, skipping write."
                }
            } else {
                Set-Content -Path $filePath -Value $script -Encoding UTF8
            }        }
    }
}

# Run exports
Export-TablesWithDependencies -Database $database -OutputFolder $OutputRoot -Options $scriptingOptions
Export-DbObjects $database.Views                "Views"
Export-DbObjects $database.StoredProcedures     "StoredProcedures"
Export-DbObjects $database.UserDefinedFunctions "Functions"
Export-DbObjects $database.Triggers             "Triggers"
Export-DbObjects $database.Schemas              "Schemas"


Write-Host "✅ Export complete. Files saved to $OutputRoot"

# Commit changes to Git
Set-Location $OutputRoot
git add .
git commit -m $CommitMessage
git push

Write-Host "✅ Changes committed to Git with message: '$CommitMessage'"
