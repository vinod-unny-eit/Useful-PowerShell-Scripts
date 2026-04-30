param (
    [string]$SqlServer = "localhost",
    [string]$DatabaseName,
    [string]$ScriptsFolderPath
)

# Load SMO
Add-Type -AssemblyName "Microsoft.SqlServer.SMO"

# Connect to SQL Server
$server = New-Object Microsoft.SqlServer.Management.Smo.Server $SqlServer
$database = $server.Databases[$DatabaseName]
if (-not $database) {
    Write-Error "Database '$DatabaseName' does not exist."
    exit
}

# Function to synchronize table
function Sync-Table {
    param ($script, $schema, $tableName)

    $table = $database.Tables[$tableName, $schema]
    if (-not $table) {
        Write-Host "Table '$schema.$tableName' does not exist. Executing full CREATE TABLE script..."
        Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
        return
    }

    # Parse columns from CREATE TABLE script
    $columnPattern = "\[(\w+)\]\s+([\w\(\)]+)"
    $matches = [regex]::Matches($script, $columnPattern)
    $columnsFromScript = @{}
    foreach ($match in $matches) {
        $colName = $match.Groups[1].Value
        $colType = $match.Groups[2].Value
        $columnsFromScript[$colName] = $colType
    }

    # Generate ALTER statements
    $alterStatements = @()

    # Columns: Add or modify
    foreach ($col in $columnsFromScript.Keys) {
        if ($table.Columns.Contains($col)) {
            $existingType = $table.Columns[$col].DataType.Name
            if ($existingType -ne $columnsFromScript[$col]) {
                $alterStatements += "ALTER TABLE [$schema].[$tableName] ALTER COLUMN [$col] $($columnsFromScript[$col]);"
            }
        } else {
            $alterStatements += "ALTER TABLE [$schema].[$tableName] ADD [$col] $($columnsFromScript[$col]);"
        }
    }

    # Columns: Drop unused
    foreach ($col in $table.Columns) {
        if (-not $columnsFromScript.ContainsKey($col.Name)) {
            $alterStatements += "ALTER TABLE [$schema].[$tableName] DROP COLUMN [$($col.Name)];"
        }
    }

    # Primary Key
    $pkScriptMatch = $script -match "CONSTRAINT\s+\[(\w+)\]\s+PRIMARY\s+KEY\s+\(([^\)]+)\)"
    if ($pkScriptMatch) {
        $pkName = $matches[1]
        $pkCols = $matches[2].Split(",") | ForEach-Object { $_.Trim() }
        $existingPK = $table.Indexes | Where-Object { $_.IndexKeyType -eq "DriPrimaryKey" }
        if ($existingPK) {
            $alterStatements += "ALTER TABLE [$schema].[$tableName] DROP CONSTRAINT [$($existingPK.Name)];"
        }
        $alterStatements += "ALTER TABLE [$schema].[$tableName] ADD CONSTRAINT [$pkName] PRIMARY KEY ($($pkCols -join ","));"
    }

    # Indexes
    $indexMatches = [regex]::Matches($script, "CREATE\s+INDEX\s+\[(\w+)\]\s+ON\s+\[\w+\]\.\[\w+\]\s+\(([^\)]+)\)")
    foreach ($match in $indexMatches) {
        $indexName = $match.Groups[1].Value
        $indexCols = $match.Groups[2].Value
        $existingIndex = $table.Indexes[$indexName]
        if ($existingIndex) {
            $alterStatements += "DROP INDEX [$indexName] ON [$schema].[$tableName];"
        }
        $alterStatements += "CREATE INDEX [$indexName] ON [$schema].[$tableName] ($indexCols);"
    }

    # Foreign Keys
    $fkMatches = [regex]::Matches($script, "CONSTRAINT\s+\[(\w+)\]\s+FOREIGN\s+KEY\s+\(([^\)]+)\)\s+REFERENCES\s+\[(\w+)\]\.\[(\w+)\]\s+\(([^\)]+)\)")
    foreach ($match in $fkMatches) {
        $fkName = $match.Groups[1].Value
        $fkCols = $match.Groups[2].Value
        $refSchema = $match.Groups[3].Value
        $refTable = $match.Groups[4].Value
        $refCols = $match.Groups[5].Value
        $existingFK = $table.ForeignKeys[$fkName]
        if ($existingFK) {
            $alterStatements += "ALTER TABLE [$schema].[$tableName] DROP CONSTRAINT [$fkName];"
        }
        $alterStatements += "ALTER TABLE [$schema].[$tableName] ADD CONSTRAINT [$fkName] FOREIGN KEY ($fkCols) REFERENCES [$refSchema].[$refTable] ($refCols);"
    }

    # Execute ALTER statements
    foreach ($stmt in $alterStatements) {
        Write-Host "Executing: $stmt"
        Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $stmt
    }
}

# Get all .sql files
$sqlFiles = Get-ChildItem -Path $ScriptsFolderPath -Filter *.sql

# Define order of object types to handle dependencies
$typeOrder = @("SCHEMA", "TABLE", "VIEW", "FUNCTION", "PROCEDURE")

# Group files by type
$filesByType = @{}
foreach ($file in $sqlFiles) {
    $script = Get-Content $file.FullName -Raw
    if ($script -match "^CREATE\s+(\w+)") {
        $type = $matches[1].ToUpper()
        if (-not $filesByType.ContainsKey($type)) { $filesByType[$type] = @() }
        $filesByType[$type] += @{File=$file; Script=$script}
    }
}

# Process in order
foreach ($type in $typeOrder) {
    if ($filesByType.ContainsKey($type)) {
        foreach ($item in $filesByType[$type]) {
            $script = $item.Script
            $file = $item.File
            Write-Host "Processing $($file.Name) - $type"
            if ($type -eq "TABLE") {
                # Extract schema and table name
                if ($script -match "CREATE\s+TABLE\s+\[?(\w+)\]?\.\[?(\w+)\]?") {
                    $schema = $matches[1]
                    $tableName = $matches[2]
                    Sync-Table -script $script -schema $schema -tableName $tableName
                } else {
                    Write-Error "Could not parse table name from $($file.Name)"
                }
            } elseif ($type -eq "SCHEMA") {
                if ($script -match "CREATE\s+SCHEMA\s+\[?(\w+)\]?") {
                    $schemaName = $matches[1]
                    if ($database.Schemas.Contains($schemaName)) {
                        $database.Schemas[$schemaName].Drop()
                    }
                    Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
                } else {
                    Write-Error "Could not parse schema name from $($file.Name)"
                }
            } elseif ($type -eq "PROCEDURE") {
                if ($script -match "CREATE\s+PROCEDURE\s+\[?(\w+)\]?\.\[?(\w+)\]?") {
                    $schema = $matches[1]
                    $procName = $matches[2]
                    if ($database.StoredProcedures.Contains($procName, $schema)) {
                        $database.StoredProcedures[$procName, $schema].Drop()
                    }
                    Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
                } else {
                    Write-Error "Could not parse procedure name from $($file.Name)"
                }
            } elseif ($type -eq "VIEW") {
                if ($script -match "CREATE\s+VIEW\s+\[?(\w+)\]?\.\[?(\w+)\]?") {
                    $schema = $matches[1]
                    $viewName = $matches[2]
                    if ($database.Views.Contains($viewName, $schema)) {
                        $database.Views[$viewName, $schema].Drop()
                    }
                    Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
                } else {
                    Write-Error "Could not parse view name from $($file.Name)"
                }
            } elseif ($type -eq "FUNCTION") {
                if ($script -match "CREATE\s+FUNCTION\s+\[?(\w+)\]?\.\[?(\w+)\]?") {
                    $schema = $matches[1]
                    $funcName = $matches[2]
                    if ($database.UserDefinedFunctions.Contains($funcName, $schema)) {
                        $database.UserDefinedFunctions[$funcName, $schema].Drop()
                    }
                    Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
                } else {
                    Write-Error "Could not parse function name from $($file.Name)"
                }
            } else {
                # For other CREATE statements, just execute
                Invoke-Sqlcmd -ServerInstance $SqlServer -Database $DatabaseName -Query $script
            }
        }
    }
}

Write-Host "Import complete."
