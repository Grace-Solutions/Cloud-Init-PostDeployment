#!/bin/bash
#===============================================================================
# bootstrap.sh
# Downloads and executes post-deployment scripts from private GitHub repository
# Uses Git sparse-checkout to clone only the required subfolder
#
# Usage: curl -fsSL <raw_url>/bootstrap.sh | bash
#    or: bash bootstrap.sh [--pattern "regex"] [--dest "/path"]
#===============================================================================

set -e

#Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-YOUR_GITHUB_TOKEN_HERE}"
GITHUB_REPO="${GITHUB_REPO:-Grace-Solutions/Cloud-Init-PostDeployment}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
REPO_PATH="${REPO_PATH:-.}"
DEST_DIR="${DEST_DIR:-/opt/Cloud-Init-PostDeployment/}"
BASH_PATTERN="${BASH_PATTERN:-^[0-9][0-9][0-9]-[A-Za-z]+\.sh$}"
POWERSHELL_PATTERN="${POWERSHELL_PATTERN:-^[0-9][0-9][0-9]-[A-Za-z]+\.ps1$}"

#Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bash-pattern)
            BASH_PATTERN="$2"
            shift 2
            ;;
        --ps-pattern)
            POWERSHELL_PATTERN="$2"
            shift 2
            ;;
        --dest)
            DEST_DIR="$2"
            shift 2
            ;;
        --token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        --repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        --branch)
            GITHUB_BRANCH="$2"
            shift 2
            ;;
        --path)
            REPO_PATH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Write-Log: Centralized logging function with UTC timestamp
# Usage: Write-Log "INFO" "Message here"
#-------------------------------------------------------------------------------
Write-Log() {
    local LogLevel="$1"
    local Message="$2"
    local Timestamp
    Timestamp=$(date -u +"%Y/%m/%d %H:%M:%S.%3N")
    echo "[$Timestamp] - [$LogLevel] -   $Message"
}

Write-Log "INFO" "=========================================="
Write-Log "INFO" "Post-Deployment Bootstrap (Sparse Checkout)"
Write-Log "INFO" "=========================================="
Write-Log "INFO" "Repository: $GITHUB_REPO"
Write-Log "INFO" "Branch: $GITHUB_BRANCH"
Write-Log "INFO" "Repo Path: $REPO_PATH"
Write-Log "INFO" "Destination: $DEST_DIR"
Write-Log "INFO" "Bash Pattern: $BASH_PATTERN"
Write-Log "INFO" "PowerShell Pattern: $POWERSHELL_PATTERN"
Write-Log "INFO" "=========================================="

#Build repository URL with token for authentication
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

#Clean and create destination directory
if [[ -d "$DEST_DIR" ]]; then
    Write-Log "INFO" "Cleaning existing destination directory..."
    rm -rf "$DEST_DIR"
fi
mkdir -p "$DEST_DIR"

#Clone using sparse-checkout
Write-Log "INFO" "Initializing sparse checkout..."
cd "$DEST_DIR"

git init -q
git sparse-checkout init --cone
git remote add origin "$REPO_URL"

Write-Log "INFO" "Setting sparse-checkout path: $REPO_PATH"
git sparse-checkout set "$REPO_PATH"

Write-Log "INFO" "Pulling from $GITHUB_BRANCH (shallow clone)..."
git pull --depth 1 -q origin "$GITHUB_BRANCH"

#Find the Scripts directory dynamically (handles sparse checkout nested paths)
Write-Log "INFO" "Locating Scripts directory..."
SCRIPTS_BASE_DIR=$(find "$DEST_DIR" -type d -name "Scripts" 2>/dev/null | head -n1)

if [[ -z "$SCRIPTS_BASE_DIR" ]]; then
    #Fallback: try direct path
    SCRIPTS_BASE_DIR="${DEST_DIR}${REPO_PATH}/Scripts"
fi

#Define Bash and PowerShell script directories
BASH_SCRIPTS_DIR="${SCRIPTS_BASE_DIR}/Bash"
POWERSHELL_SCRIPTS_DIR="${SCRIPTS_BASE_DIR}/PowerShell"

#Derive Functions directories
POST_DEPLOYMENT_DIR="$(dirname "$SCRIPTS_BASE_DIR")"
FUNCTIONS_BASE_DIR="${POST_DEPLOYMENT_DIR}/Functions"
BASH_FUNCTIONS_DIR="${FUNCTIONS_BASE_DIR}/Bash"
POWERSHELL_FUNCTIONS_DIR="${FUNCTIONS_BASE_DIR}/PowerShell"

#-------------------------------------------------------------------------------
# Logging Configuration
# Logs directory in same location as bootstrapper (PostDeployment/Logs/)
#-------------------------------------------------------------------------------
BOOTSTRAP_LOG_DIR="${POST_DEPLOYMENT_DIR}/Logs"
BOOTSTRAP_LOG_FILE="${BOOTSTRAP_LOG_DIR}/PostDeploymentBootstrapper.log"
mkdir -p "$BOOTSTRAP_LOG_DIR"

#Redirect all output to log file while also displaying to console
exec > >(tee -a "$BOOTSTRAP_LOG_FILE") 2>&1

Write-Log "INFO" "Log File: $BOOTSTRAP_LOG_FILE"
Write-Log "INFO" "Bash Scripts: $BASH_SCRIPTS_DIR"
Write-Log "INFO" "PowerShell Scripts: $POWERSHELL_SCRIPTS_DIR"
Write-Log "INFO" "Bash Functions: $BASH_FUNCTIONS_DIR"
Write-Log "INFO" "PowerShell Functions: $POWERSHELL_FUNCTIONS_DIR"

#Make bash scripts and functions executable
chmod +x "$BASH_SCRIPTS_DIR"/*.sh 2>/dev/null || true
chmod +x "$BASH_FUNCTIONS_DIR"/*.sh 2>/dev/null || true

#-------------------------------------------------------------------------------
# Execute Bash Scripts
# Bootstrapper handles logging to Scripts/Bash/Logs/
#-------------------------------------------------------------------------------
Write-Log "INFO" "=========================================="
Write-Log "INFO" "Executing Bash Scripts"
Write-Log "INFO" "=========================================="

BASH_LOGS_DIR="${BASH_SCRIPTS_DIR}/Logs"
mkdir -p "$BASH_LOGS_DIR"

if [[ -d "$BASH_SCRIPTS_DIR" ]]; then
    BASH_SCRIPTS=$(find "$BASH_SCRIPTS_DIR" -maxdepth 1 -type f -name "*.sh" -printf "%f\n" 2>/dev/null | grep -E "$BASH_PATTERN" | sort)

    if [[ -z "$BASH_SCRIPTS" ]]; then
        Write-Log "WARN" "No Bash scripts found matching pattern: $BASH_PATTERN"
    else
        for SCRIPT in $BASH_SCRIPTS; do
            SCRIPT_PATH_FULL="${BASH_SCRIPTS_DIR}/${SCRIPT}"
            SCRIPT_BASENAME="${SCRIPT%.sh}"
            LOG_FILE="${BASH_LOGS_DIR}/${SCRIPT_BASENAME}.log"

            #Skip 001-Variables.sh (it's sourced, not executed directly)
            if [[ "$SCRIPT" == "001-Variables.sh" ]]; then
                Write-Log "SKIP" "$SCRIPT (sourced by other scripts)"
                continue
            fi

            Write-Log "INFO" ">>> Executing: $SCRIPT"
            Write-Log "INFO" "    Log: $LOG_FILE"

            bash "$SCRIPT_PATH_FULL" 2>&1 | tee -a "$LOG_FILE"
            EXIT_CODE=${PIPESTATUS[0]}

            if [[ $EXIT_CODE -eq 0 ]]; then
                Write-Log "INFO" "<<< Completed: $SCRIPT (exit code: $EXIT_CODE)"
            else
                Write-Log "INFO" "<<< Exited: $SCRIPT (exit code: $EXIT_CODE)"
            fi
        done
    fi
else
    Write-Log "WARN" "Bash scripts directory not found: $BASH_SCRIPTS_DIR"
fi

#-------------------------------------------------------------------------------
# Execute PowerShell Scripts
# PowerShell scripts handle their own logging via Start-Transcript
#-------------------------------------------------------------------------------
Write-Log "INFO" "=========================================="
Write-Log "INFO" "Executing PowerShell Scripts"
Write-Log "INFO" "=========================================="

#Check if PowerShell is available
if command -v pwsh >/dev/null 2>&1; then
    PWSH_CMD="pwsh"
elif command -v powershell >/dev/null 2>&1; then
    PWSH_CMD="powershell"
else
    Write-Log "WARN" "PowerShell not installed - skipping PowerShell scripts"
    PWSH_CMD=""
fi

if [[ -n "$PWSH_CMD" && -d "$POWERSHELL_SCRIPTS_DIR" ]]; then
    POWERSHELL_SCRIPTS=$(find "$POWERSHELL_SCRIPTS_DIR" -maxdepth 1 -type f -name "*.ps1" -printf "%f\n" 2>/dev/null | grep -E "$POWERSHELL_PATTERN" | sort)

    if [[ -z "$POWERSHELL_SCRIPTS" ]]; then
        Write-Log "WARN" "No PowerShell scripts found matching pattern: $POWERSHELL_PATTERN"
    else
        for SCRIPT in $POWERSHELL_SCRIPTS; do
            SCRIPT_PATH_FULL="${POWERSHELL_SCRIPTS_DIR}/${SCRIPT}"

            Write-Log "INFO" ">>> Executing: $SCRIPT"

            $PWSH_CMD -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$SCRIPT_PATH_FULL"
            EXIT_CODE=$?

            if [[ $EXIT_CODE -eq 0 ]]; then
                Write-Log "INFO" "<<< Completed: $SCRIPT (exit code: $EXIT_CODE)"
            else
                Write-Log "ERROR" "<<< Failed: $SCRIPT (exit code: $EXIT_CODE)"
            fi
        done
    fi
elif [[ -n "$PWSH_CMD" ]]; then
    Write-Log "WARN" "PowerShell scripts directory not found: $POWERSHELL_SCRIPTS_DIR"
fi

Write-Log "INFO" "=========================================="
Write-Log "INFO" "Post-Deployment Complete"
Write-Log "INFO" "=========================================="

#-------------------------------------------------------------------------------
# Post-Deployment Reboot Configuration
# REBOOT_ENABLED: "true" to reboot after deployment, "false" to skip
# REBOOT_EXCLUDE_PATTERN: Regex pattern - skip reboot if hostname matches
# REBOOT_DELAY_SECONDS: Delay before reboot (allows script to exit cleanly)
#-------------------------------------------------------------------------------
REBOOT_ENABLED="true"
REBOOT_EXCLUDE_PATTERN="^$"
REBOOT_DELAY_SECONDS=30

#Get current hostname for exclusion check
CURRENT_HOSTNAME=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")

if [[ "$REBOOT_ENABLED" != "true" ]]; then
    Write-Log "SKIP" "Post-deployment reboot is disabled"
elif [[ "$CURRENT_HOSTNAME" =~ $REBOOT_EXCLUDE_PATTERN ]]; then
    Write-Log "SKIP" "Post-deployment reboot - hostname '$CURRENT_HOSTNAME' matches exclude pattern '$REBOOT_EXCLUDE_PATTERN'"
else
    Write-Log "INFO" "=========================================="
    Write-Log "INFO" "Scheduling Post-Deployment Reboot"
    Write-Log "INFO" "=========================================="
    Write-Log "INFO" "Reboot scheduled in ${REBOOT_DELAY_SECONDS} seconds..."

    #Schedule reboot using nohup to allow script to exit cleanly
    #The reboot runs in a detached process after the specified delay
    nohup bash -c "sleep ${REBOOT_DELAY_SECONDS} && /sbin/shutdown -r now 'Post-deployment reboot'" >/dev/null 2>&1 &
    disown

    Write-Log "INFO" "Reboot process detached (PID: $!)"
fi
