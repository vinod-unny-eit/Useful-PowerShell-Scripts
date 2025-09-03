# Export-SQLServerDBObjects.ps1

## Purpose
- Export SQL Server database objects to filesystem files formatted for source control (Git).
- Exports schema and object definitions (tables, views, stored procedures, functions, triggers, roles, users, etc.) into a logical folder structure.
- Integrates into SQL Server Management Studio (SSMS) using a wrapper .CMD script.

## Requirements
- PowerShell 5.1 or later (PowerShell 7+ recommended).
- SqlServer PowerShell module (Install-Module SqlServer).
- Appropriate permissions on the target SQL Server (VIEW DEFINITION or equivalent).
- Network access to the SQL Server instance.

## Features
- Export specific object types (tables, views, procedures, functions, triggers, roles, users).
- Files saved by schema and/or object name pattern.
- Only new or changed objects are saved into the folder which makes it better for Git tracking.
- Create a directory structure that is Git-friendly: <OutputRoot>/<Database>/<ObjectType>/<Schema>_<ObjectName>.sql.
- Designed to be used in automated workflows (CI/CD, scheduled exports).

## Setup
- Install PowerShell module SqlServer.
- Create a base output folder manually or by cloning a Git repo (Recommended).
- Update the script to change the $OutputRoot variable with the above folder.
- (Optional) Create a new "External Tool" in SQL Server that simply points to the .CMD file in the same folder as this script.

## Usage (Command Line)
- Export-SQLServerDBObjects.ps1 -ServerName "SERVER\INSTANCE" -DatabaseName "MyDb" -CommitMessage "My commit message"

## Usage (SSMS)
- Add the .CMD script as an External Tool, enable Show Output Window if you wish to see the messages from the script.
- Click the name of the tool in the Tools menu. 
- Select the name of the database to commit from the popup of a list of databases in the default SQL Server instance.
- Add the Commit message you wish to push.
- Watch the Output window for messages.

## Output layout
- Root Git folder/
    - DatabaseName/
        - Tables/
        - Views/
        - StoredProcedures/
        - Functions/
        - Triggers/
        - Schemas/

## Notes & Limitations
- The script exports DDL (definitions). Data export is not included unless explicitly implemented.
- Complex dependency ordering may not be perfect for very large schemas; review and adjust in CI workflows.
- Object-level permissions and database-level objects (jobs, server-level logins) may require separate handling.
