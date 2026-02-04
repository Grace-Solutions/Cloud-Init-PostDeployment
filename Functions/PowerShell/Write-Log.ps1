#===============================================================================
# Write-Log.ps1
# Centralized logging function with UTC timestamp
#===============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$LogLevel,
        [Parameter(Mandatory)][string]$Message
    )
    $Timestamp = [DateTime]::UtcNow.ToString("yyyy/MM/dd HH:mm:ss.fff")
    Write-Host "[$Timestamp] - [$LogLevel] - $Message"
}

