#Requires -Version 5.1
#===============================================================================
# 000-Template.ps1
# Description: Brief description of what this script does
#===============================================================================

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: $true to run, $false to skip
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
#-------------------------------------------------------------------------------
$ScriptFileInfo = New-Object -TypeName 'System.IO.FileInfo' -ArgumentList $PSCommandPath
$ScriptName = $ScriptFileInfo.Name
$ScriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptFileInfo.Name)
$ScriptDirectory = $ScriptFileInfo.DirectoryName
$Enabled = $true
$ExcludePattern = '^$'

#-------------------------------------------------------------------------------
# Transcript Configuration
# Logs directory in same location as script
#-------------------------------------------------------------------------------
$LogsDirectory = [System.IO.Path]::Combine($ScriptDirectory, 'Logs')
$LogsDirectoryInfo = New-Object -TypeName 'System.IO.DirectoryInfo' -ArgumentList $LogsDirectory
if (-not $LogsDirectoryInfo.Exists) {
    $LogsDirectoryInfo.Create()
}
$TranscriptPath = [System.IO.Path]::Combine($LogsDirectory, "$ScriptBaseName.log")
$Null = Start-Transcript -Path $TranscriptPath -Append -Force

#-------------------------------------------------------------------------------
# Write-Log: Centralized logging function with UTC timestamp
#-------------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$LogLevel,
        [Parameter(Mandatory)][string]$Message
    )
    $Timestamp = [DateTime]::UtcNow.ToString("yyyy/MM/dd HH:mm:ss.fff")
    Write-Host "[$Timestamp] - [$LogLevel] - $Message"
}

#Check if script should run
if (-not $Enabled) {
    Write-Log "SKIP" "$ScriptName is disabled"
    $Null = Stop-Transcript
    exit 0
}

$Hostname = [System.Net.Dns]::GetHostName()
if ($Hostname -match $ExcludePattern) {
    Write-Log "SKIP" "$ScriptName - hostname '$Hostname' matches exclude pattern '$ExcludePattern'"
    $Null = Stop-Transcript
    exit 0
}

#-------------------------------------------------------------------------------
# Optional: Add prerequisite checks here
#-------------------------------------------------------------------------------
# Example: Check if a command exists
# if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
#     Write-Log "SKIP" "$ScriptName - Docker is not installed"
#     $Null = Stop-Transcript
#     exit 0
# }

Write-Log "INFO" "=== Script Description Here ==="

#-------------------------------------------------------------------------------
# Script Logic
# Add your implementation below
#-------------------------------------------------------------------------------

# Example: Define a typed list and use .Add() method
# $ItemList = New-Object -TypeName 'System.Collections.Generic.List[string]'
# $ItemList.Add('item1')
# $ItemList.Add('item2')
# $ItemList.Add('item3')

# Example: Loop through items
# foreach ($Item in $ItemList) {
#     Write-Log "INFO" "Processing: $Item"
# }

# Example: Create an ordered dictionary
# $Config = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
# $Config.Add('key1', 'value1')
# $Config.Add('key2', 'value2')

# Example: Create directory using System.IO.DirectoryInfo
# $DirectoryPath = [System.IO.Path]::Combine($env:USERPROFILE, 'MyApp', 'Data')
# $DirectoryInfo = New-Object -TypeName 'System.IO.DirectoryInfo' -ArgumentList $DirectoryPath
# if (-not $DirectoryInfo.Exists) {
#     $DirectoryInfo.Create()
#     Write-Log "INFO" "[CREATE] $($DirectoryInfo.FullName)"
# } else {
#     Write-Log "SKIP" "$($DirectoryInfo.FullName) (exists)"
# }

# Example: Check file using System.IO.FileInfo
# $FilePath = [System.IO.Path]::Combine($env:USERPROFILE, 'MyApp', 'config.json')
# $FileInfo = New-Object -TypeName 'System.IO.FileInfo' -ArgumentList $FilePath
# if ($FileInfo.Exists) {
#     Write-Log "INFO" "File size: $($FileInfo.Length) bytes"
# }

# Example: Make web request
# try {
#     $Response = Invoke-RestMethod -Uri 'https://api.example.com/endpoint' -Method Post -Body $Body
#     Write-Log "INFO" "[OK] Request completed"
# } catch {
#     Write-Log "ERROR" "[FAIL] Request failed: $($_.Exception.Message)"
# }

Write-Log "INFO" "=== Script Description Complete ==="

$Null = Stop-Transcript

