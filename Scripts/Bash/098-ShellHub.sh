#!/bin/bash
#===============================================================================
# 009-ShellHub.sh
# ShellHub server configuration
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

Write-Log "INFO" "=== ShellHub Server Configuration ==="

#Reconfigure SSH to use port 2222
Write-Log "INFO" "[CONFIG] SSH port to 2222"
sed -i 's/\Port 22/Port 2222/' "/etc/hpnssh/sshd_config" 2>/dev/null
systemctl restart hpnssh 2>/dev/null

#Clone and setup ShellHub
Write-Log "INFO" "[CLONE] ShellHub repository"
git clone https://github.com/shellhub-io/shellhub.git >/dev/null 2>&1
cd ./shellhub || exit 1

Write-Log "INFO" "[KEYGEN] Generating keys"
make keygen >/dev/null 2>&1

Write-Log "INFO" "[START] ShellHub"
make start >/dev/null 2>&1

#Create admin user
Write-Log "INFO" "[CREATE] Admin user"
./bin/cli user create 'admin' 'YOUR_PASSWORD_HERE' 'admin@example.com' >/dev/null 2>&1

Write-Log "INFO" "=== ShellHub Server Configuration Complete ==="

