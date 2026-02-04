#!/bin/bash
#===============================================================================
# 000-Template.sh
# Description: Brief description of what this script does
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
# INCLUDE_PATTERN: Regex pattern - only run if hostname matches (use ".*" to include all)
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
# Note: Logging is handled by the bootstrapper (tee to Scripts/Bash/Logs/)
#-------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ENABLED="true"
INCLUDE_PATTERN=".*"
EXCLUDE_PATTERN="^$"

#Check if script should run
if [[ "$ENABLED" != "true" ]]; then
    Write-Log "SKIP" "$SCRIPT_NAME is disabled"
    exit 1000
fi

#Enable case-insensitive matching for hostname patterns
shopt -s nocasematch

if [[ ! "$CLOUDINITHOSTNAME" =~ $INCLUDE_PATTERN ]]; then
    Write-Log "SKIP" "$SCRIPT_NAME - hostname '$CLOUDINITHOSTNAME' does not match include pattern '$INCLUDE_PATTERN'"
    shopt -u nocasematch
    exit 1001
fi

if [[ "$CLOUDINITHOSTNAME" =~ $EXCLUDE_PATTERN ]]; then
    Write-Log "SKIP" "$SCRIPT_NAME - hostname '$CLOUDINITHOSTNAME' matches exclude pattern '$EXCLUDE_PATTERN'"
    shopt -u nocasematch
    exit 1002
fi

shopt -u nocasematch

#-------------------------------------------------------------------------------
# Optional: Add prerequisite checks here
# Example: Check if Docker is installed before running Docker-related tasks
#-------------------------------------------------------------------------------
# if ! Test-DockerInstalled; then
#     Write-Log "SKIP" "$SCRIPT_NAME - Docker is not installed"
#     exit 0
# fi

# if ! Test-DockerComposeInstalled; then
#     Write-Log "SKIP" "$SCRIPT_NAME - Docker Compose is not installed"
#     exit 0
# fi

Write-Log "INFO" "=== Script Description Here ==="

#-------------------------------------------------------------------------------
# Script Logic
# Add your implementation below
#-------------------------------------------------------------------------------

# Example: Define items to process
# ItemList=(
#     "item1"
#     "item2"
#     "item3"
# )

# Example: Loop through items
# for Item in "${ItemList[@]}"; do
#     Write-Log "INFO" "Processing: $Item"
# done

# Example: Use helper functions from Common.sh
# Create-Directory "/path/to/directory"
# Install-Package "package-name"
# Add-CronJob "0 21 * * 6" "/path/to/script.sh"
# Add-FirewallRule "allow" "22"

# Example: Docker helper functions
# if Test-DockerContainerRunning "container-name"; then
#     Write-Log "INFO" "Container is running"
# fi
# STATUS=$(Get-DockerContainerStatus "container-name")
# HEALTH=$(Get-DockerContainerHealth "container-name")

Write-Log "INFO" "=== Script Description Complete ==="

