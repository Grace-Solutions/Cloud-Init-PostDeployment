#!/bin/bash
#===============================================================================
# 007-Webmin.sh
# Webmin web-based administration tool installation
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
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

Write-Log "INFO" "=== Webmin Installation ==="

#Setup directories
WEBMINDOWNLOADDIRECTORY="$DOWNLOADSROOTDIRECTORY/webmin"
WEBMINSCRIPTURL="https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh"
WEBMINSCRIPTFILENAME=$(basename "$WEBMINSCRIPTURL")
WEBMINSCRIPTFILEPATH="$WEBMINDOWNLOADDIRECTORY/$WEBMINSCRIPTFILENAME"
WEBMINSCRIPTLOGPATH="$WEBMINDOWNLOADDIRECTORY/$WEBMINSCRIPTFILENAME.log"

#Download and install Webmin
Write-Log "INFO" "[DOWNLOAD] Webmin setup script"
mkdir -p "$WEBMINDOWNLOADDIRECTORY"
wget -q -O "$WEBMINSCRIPTFILEPATH" "$WEBMINSCRIPTURL"

Write-Log "INFO" "[INSTALL] Webmin repository"
echo "y" | bash "$WEBMINSCRIPTFILEPATH" > "$WEBMINSCRIPTLOGPATH" 2>&1

Write-Log "INFO" "[INSTALL] Webmin package"
apt-get install -y -qq --install-recommends webmin >/dev/null 2>&1

Write-Log "INFO" "=== Webmin Installation Complete ==="

