@echo off
REM change to the script directory and restore it afterwards
pushd "%~dp0"
pwsh -ExecutionPolicy Bypass -File "Export-SQLServerDBObjects.ps1"
popd
