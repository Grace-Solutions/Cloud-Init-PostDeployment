#!/bin/bash
#===============================================================================
# 002-Directories.sh
# Directory creation
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
# INCLUDE_PATTERN: Regex pattern - only run if hostname matches (use ".*" to include all)
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
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

if [[ ! "$CLOUDINITHOSTNAME" =~ $INCLUDE_PATTERN ]]; then
    Write-Log "SKIP" "$SCRIPT_NAME - hostname '$CLOUDINITHOSTNAME' does not match include pattern '$INCLUDE_PATTERN'"
    exit 1001
fi

if [[ "$CLOUDINITHOSTNAME" =~ $EXCLUDE_PATTERN ]]; then
    Write-Log "SKIP" "$SCRIPT_NAME - hostname '$CLOUDINITHOSTNAME' matches exclude pattern '$EXCLUDE_PATTERN'"
    exit 1002
fi

Write-Log "INFO" "=== Directory Creation ==="

#Define directories to create
DirectoryCreationEntryList+=(
    "/$ROOTDIRECTORYNAME/cron/logs"
    "/$ROOTDIRECTORYNAME/docker/containers"
    "/$ROOTDIRECTORYNAME/docker/stacks"
    "/$ROOTDIRECTORYNAME/ssh"
    "/opt/docker"
)

#Create directories using function from Common.sh
for Directory in "${DirectoryCreationEntryList[@]}"; do
    Create-Directory "$Directory"
done

Write-Log "INFO" "=== Directory Creation Complete ==="

