#!/bin/bash
#===============================================================================
# 008-DockerConfiguration.sh
# Docker installation
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

Write-Log "INFO" "=== Docker Installation ==="

#Install prerequisites
Write-Log "INFO" "[INSTALL] Docker prerequisites"
apt-get update -y -qq >/dev/null 2>&1
apt-get install -y -qq ca-certificates gnupg lsb-release >/dev/null 2>&1

#Setup Docker GPG key
Write-Log "INFO" "[CONFIG] Docker repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg 2>/dev/null | gpg --dearmor --yes -o "/etc/apt/keyrings/docker.gpg" 2>/dev/null
chmod a+r "/etc/apt/keyrings/docker.gpg"

#Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

#Create docker user and group
Write-Log "INFO" "[CREATE] Docker user and group"
addgroup --system docker >/dev/null 2>&1
adduser --system --no-create-home --ingroup docker docker >/dev/null 2>&1
mkdir -p /opt/docker
chown -R docker:docker /opt/docker

#Install Docker
Write-Log "INFO" "[INSTALL] Docker packages"
apt-get update -y -qq >/dev/null 2>&1
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose docker-compose-plugin >/dev/null 2>&1

Write-Log "INFO" "=== Docker Installation Complete ==="

