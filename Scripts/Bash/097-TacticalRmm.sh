#!/bin/bash
#===============================================================================
# 008-TacticalRmm.sh
# Tactical RMM server configuration
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
ENABLED="false"
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

Write-Log "INFO" "=== Tactical RMM Configuration ==="

TARGETUSER="tactical"

#Create tactical user
Write-Log "INFO" "[CREATE] Tactical user"
useradd -m -G sudo -s /bin/bash "$TARGETUSER" 2>/dev/null
echo "$TARGETUSER:$TARGETUSER" | chpasswd

#Future: Uncomment to complete Tactical RMM setup
#ufw default deny incoming
#ufw default allow outgoing
#ufw allow http
#ufw allow https
#ufw allow ssh
#ufw enable
#ufw reload

#SSHKEYFOLDER="/home/$TARGETUSER/.ssh"
#SSHKEYFILE="$SSHKEYFOLDER/authorized_keys"
#mkdir -p "$SSHKEYFOLDER"
#cat "/root/.ssh/authorized_keys" >> "$SSHKEYFILE"

#wget "https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh"
#chmod +x install.sh
#./install.sh --insecure

Write-Log "INFO" "=== Tactical RMM Configuration Complete ==="

