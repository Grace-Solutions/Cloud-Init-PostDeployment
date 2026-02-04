#!/bin/bash
#===============================================================================
# 011-SSHConfiguration.sh
# Description: Configures SSH for key-based authentication
#              - Disables password authentication
#              - Enables public key authentication
#              - Idempotently installs SSH public keys for specified users
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

Write-Log "INFO" "=== SSH Configuration ==="

#-------------------------------------------------------------------------------
# SSH Configuration Settings
#-------------------------------------------------------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"

#-------------------------------------------------------------------------------
# User-to-Key Mappings (JSON format, parsed with jq)
# Each user has an array of SSH public keys
#-------------------------------------------------------------------------------
SSH_USER_KEYS_JSON='
{
	"root": [
		        "ssh-ed25519 YOUR_PUBLIC_KEY_HERE user@example.com"
	        ],
	"admin": [
                        
             ],
	"deploy": [
                    
              ]
}
'

#-------------------------------------------------------------------------------
# Function: Set-SSHDConfig
# Idempotently sets a configuration option in sshd_config
#-------------------------------------------------------------------------------
Set-SSHDConfig() {
    local OPTION="$1"
    local VALUE="$2"
    local CONFIG_FILE="${3:-$SSHD_CONFIG}"

    # Check if option exists (commented or uncommented)
    if grep -qE "^#?${OPTION}\s" "$CONFIG_FILE" 2>/dev/null; then
        # Replace existing line (commented or not)
        sed -i "s/^#*${OPTION}\s.*/${OPTION} ${VALUE}/" "$CONFIG_FILE"
        Write-Log "INFO" "  [UPDATE] ${OPTION} ${VALUE}"
    else
        # Append new option
        echo "${OPTION} ${VALUE}" >> "$CONFIG_FILE"
        Write-Log "INFO" "  [ADD] ${OPTION} ${VALUE}"
    fi
}

#-------------------------------------------------------------------------------
# Function: Install-SSHKey
# Idempotently installs an SSH public key for a user
#-------------------------------------------------------------------------------
Install-SSHKey() {
    local USER="$1"
    local PUBLIC_KEY="$2"

    # Get user's home directory
    local HOME_DIR
    HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)

    if [[ -z "$HOME_DIR" ]]; then
        Write-Log "WARN" "  User '$USER' not found, skipping"
        return 1
    fi

    local SSH_DIR="${HOME_DIR}/.ssh"
    local AUTH_KEYS="${SSH_DIR}/authorized_keys"

    # Create .ssh directory if it doesn't exist
    if [[ ! -d "$SSH_DIR" ]]; then
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown "$USER:$USER" "$SSH_DIR" 2>/dev/null || chown "$USER" "$SSH_DIR"
        Write-Log "INFO" "  [CREATE] ${SSH_DIR}"
    fi

    # Extract key fingerprint for comparison (use the key type and key data)
    local KEY_DATA
    KEY_DATA=$(echo "$PUBLIC_KEY" | awk '{print $1" "$2}')

    # Check if key already exists
    if [[ -f "$AUTH_KEYS" ]] && grep -qF "$KEY_DATA" "$AUTH_KEYS" 2>/dev/null; then
        Write-Log "INFO" "  [EXISTS] Key already installed for $USER"
        return 0
    fi

    # Append key
    echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown "$USER:$USER" "$AUTH_KEYS" 2>/dev/null || chown "$USER" "$AUTH_KEYS"
    Write-Log "INFO" "  [INSTALL] Key installed for $USER"
    return 0
}

#-------------------------------------------------------------------------------
# Configure SSHD
#-------------------------------------------------------------------------------
Write-Log "INFO" "[CONFIG] Configuring SSH daemon"

# Backup original config if not already backed up
if [[ ! -f "${SSHD_CONFIG}.original" ]]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.original"
    Write-Log "INFO" "  [BACKUP] Original config saved to ${SSHD_CONFIG}.original"
fi

# Configure SSH settings
Set-SSHDConfig "PubkeyAuthentication" "yes"
Set-SSHDConfig "PasswordAuthentication" "no"
Set-SSHDConfig "ChallengeResponseAuthentication" "no"
Set-SSHDConfig "UsePAM" "yes"
Set-SSHDConfig "PermitRootLogin" "prohibit-password"

# Check for drop-in config directory overrides (Ubuntu 22.04+)
if [[ -d "$SSHD_CONFIG_DIR" ]]; then
    # Disable any cloud-init password auth overrides
    for DROPIN in "$SSHD_CONFIG_DIR"/*.conf; do
        if [[ -f "$DROPIN" ]] && grep -q "PasswordAuthentication yes" "$DROPIN" 2>/dev/null; then
            sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' "$DROPIN"
            Write-Log "INFO" "  [UPDATE] Disabled password auth in $(basename "$DROPIN")"
        fi
    done
fi

#-------------------------------------------------------------------------------
# Install SSH Keys
#-------------------------------------------------------------------------------
Write-Log "INFO" "[KEYS] Installing SSH public keys"

KEYS_INSTALLED=0
KEYS_SKIPPED=0

# Get list of users from JSON
USERS=$(echo "$SSH_USER_KEYS_JSON" | jq -r 'keys[]')

for USER in $USERS; do
    Write-Log "INFO" "  Processing user: $USER"

    # Get keys for this user (each key on its own line)
    while IFS= read -r KEY; do
        [[ -z "$KEY" ]] && continue

        if Install-SSHKey "$USER" "$KEY"; then
            KEYS_INSTALLED=$((KEYS_INSTALLED + 1))
        else
            KEYS_SKIPPED=$((KEYS_SKIPPED + 1))
        fi
    done < <(echo "$SSH_USER_KEYS_JSON" | jq -r --arg user "$USER" '.[$user][]')
done

Write-Log "INFO" "[KEYS] Keys processed: $((KEYS_INSTALLED + KEYS_SKIPPED)), installed/updated: $KEYS_INSTALLED, skipped: $KEYS_SKIPPED"

#-------------------------------------------------------------------------------
# Validate and Restart SSH
#-------------------------------------------------------------------------------
Write-Log "INFO" "[VALIDATE] Testing SSH configuration"

if sshd -t 2>/dev/null; then
    Write-Log "INFO" "  SSH configuration is valid"

    # Restart SSH service
    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd
        Write-Log "INFO" "  [RESTART] sshd service restarted"
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh
        Write-Log "INFO" "  [RESTART] ssh service restarted"
    else
        Write-Log "WARN" "  SSH service not found or not running"
    fi
else
    Write-Log "ERROR" "  SSH configuration test failed!"
    Write-Log "ERROR" "  Restoring original configuration"
    cp "${SSHD_CONFIG}.original" "$SSHD_CONFIG"
    exit 1
fi

Write-Log "INFO" "=== SSH Configuration Complete ==="

