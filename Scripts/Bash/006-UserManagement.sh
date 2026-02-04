#!/bin/bash
#===============================================================================
# 006-UserManagement.sh
# Description: Creates additional users, sets passwords, and adds to groups
#              - Idempotently creates users
#              - Sets passwords (plain text, hash, or auto-generated)
#              - Adds users to specified groups
#
# Usage:
#   Generate password hash: openssl passwd -6 'yourpassword'
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

Write-Log "INFO" "=== User Management ==="

#-------------------------------------------------------------------------------
# User Configuration (JSON format, parsed with jq)
# enabled: true/false - controls whether user is processed
# password: "" (none), "auto" (generate random), plain text, or hash
# groups: array of groups to add user to
# shell: user's login shell
# create_home: true/false - create home directory
# comment: user description (GECOS field)
#-------------------------------------------------------------------------------
USER_CONFIG_JSON='
{
	"admin": {
		"enabled": true,
		"password": "auto",
		"groups": ["sudo", "docker"],
		"shell": "/bin/bash",
		"create_home": true,
		"comment": "Admin User"
	},
	"deploy": {
		"enabled": true,
		"password": "auto",
		"groups": ["docker"],
		"shell": "/bin/bash",
		"create_home": true,
		"comment": "Deployment User"
	}
}
'

#-------------------------------------------------------------------------------
# Function: Generate-RandomPassword
# Generates a random password and returns it
#-------------------------------------------------------------------------------
Generate-RandomPassword() {
    local LENGTH="${1:-16}"
    # Generate random password using /dev/urandom
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$LENGTH"
}

#-------------------------------------------------------------------------------
# Function: Create-User
# Idempotently creates a user with specified configuration
# PASSWORD_MODE can be: "" (none), "auto" (generate), or a hash
#-------------------------------------------------------------------------------
Create-User() {
    local USERNAME="$1"
    local PASSWORD_MODE="$2"
    local SHELL="$3"
    local CREATE_HOME="$4"
    local COMMENT="$5"

    # Check if user already exists
    if id "$USERNAME" &>/dev/null; then
        Write-Log "INFO" "  [EXISTS] User '$USERNAME' already exists"
        return 0
    fi

    # Build useradd command
    local USERADD_OPTS=()

    if [[ "$CREATE_HOME" == "true" ]]; then
        USERADD_OPTS+=("-m")
    fi

    if [[ -n "$SHELL" ]]; then
        USERADD_OPTS+=("-s" "$SHELL")
    fi

    if [[ -n "$COMMENT" ]]; then
        USERADD_OPTS+=("-c" "$COMMENT")
    fi

    # Create user
    if useradd "${USERADD_OPTS[@]}" "$USERNAME"; then
        Write-Log "INFO" "  [CREATE] User '$USERNAME' created"

        # Handle password (no prompts)
        if [[ "$PASSWORD_MODE" == "auto" ]]; then
            # Generate random password
            local PLAIN_PASSWORD
            PLAIN_PASSWORD=$(Generate-RandomPassword 16)
            echo "${USERNAME}:${PLAIN_PASSWORD}" | chpasswd
            Write-Log "INFO" "  [PASSWORD] Auto-generated password for '$USERNAME': $PLAIN_PASSWORD"
        elif [[ -n "$PASSWORD_MODE" ]]; then
            # Check if it's a hash (starts with $1$, $5$, $6$, $y$, etc.)
            if [[ "$PASSWORD_MODE" =~ ^\$[0-9a-z]+\$ ]]; then
                # It's a hash - use chpasswd -e (encrypted)
                echo "${USERNAME}:${PASSWORD_MODE}" | chpasswd -e
                Write-Log "INFO" "  [PASSWORD] Password hash set for '$USERNAME'"
            else
                # Plain text password
                echo "${USERNAME}:${PASSWORD_MODE}" | chpasswd
                Write-Log "INFO" "  [PASSWORD] Password set for '$USERNAME'"
            fi
        fi

        return 0
    else
        Write-Log "ERROR" "  [FAILED] Could not create user '$USERNAME'"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Function: Add-UserToGroups
# Adds a user to specified groups (creates groups if they don't exist)
#-------------------------------------------------------------------------------
Add-UserToGroups() {
    local USERNAME="$1"
    shift
    local GROUPS=("$@")

    for GROUP in "${GROUPS[@]}"; do
        [[ -z "$GROUP" ]] && continue

        # Create group if it doesn't exist
        if ! getent group "$GROUP" &>/dev/null; then
            groupadd "$GROUP"
            Write-Log "INFO" "  [CREATE] Group '$GROUP' created"
        fi

        # Check if user is already in group
        if id -nG "$USERNAME" | grep -qw "$GROUP"; then
            Write-Log "INFO" "  [EXISTS] '$USERNAME' already in group '$GROUP'"
        else
            usermod -aG "$GROUP" "$USERNAME"
            Write-Log "INFO" "  [ADD] '$USERNAME' added to group '$GROUP'"
        fi
    done
}

#-------------------------------------------------------------------------------
# Process Users
#-------------------------------------------------------------------------------
Write-Log "INFO" "[USERS] Processing user configurations"

USERS_CREATED=0
USERS_SKIPPED=0

# Get list of users from JSON
USERNAMES=$(echo "$USER_CONFIG_JSON" | jq -r 'keys[]')

for USERNAME in $USERNAMES; do
    # Check if user is enabled
    ENABLED=$(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].enabled // true')

    if [[ "$ENABLED" != "true" ]]; then
        Write-Log "INFO" "  [SKIP] User '$USERNAME' is disabled"
        USERS_SKIPPED=$((USERS_SKIPPED + 1))
        continue
    fi

    Write-Log "INFO" "  Processing user: $USERNAME"

    # Extract user configuration
    PASSWORD_MODE=$(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].password // ""')
    SHELL=$(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].shell // "/bin/bash"')
    CREATE_HOME=$(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].create_home // true')
    COMMENT=$(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].comment // ""')

    # Create user
    if Create-User "$USERNAME" "$PASSWORD_MODE" "$SHELL" "$CREATE_HOME" "$COMMENT"; then
        USERS_CREATED=$((USERS_CREATED + 1))
    else
        USERS_SKIPPED=$((USERS_SKIPPED + 1))
    fi

    # Get groups array and add user to groups
    mapfile -t GROUPS < <(echo "$USER_CONFIG_JSON" | jq -r --arg user "$USERNAME" '.[$user].groups[]? // empty')

    if [[ ${#GROUPS[@]} -gt 0 ]]; then
        Add-UserToGroups "$USERNAME" "${GROUPS[@]}"
    fi
done

Write-Log "INFO" "[USERS] Users processed: $((USERS_CREATED + USERS_SKIPPED)), created/updated: $USERS_CREATED, skipped: $USERS_SKIPPED"

Write-Log "INFO" "=== User Management Complete ==="

