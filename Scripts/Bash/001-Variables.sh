#!/bin/bash
#===============================================================================
# 001-Variables.sh
# Shared variables sourced by all post-deployment scripts
# Runs after 000-Packages.sh ensures prerequisites (jq, awk, etc.) are installed
#===============================================================================

#Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTIONS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/Functions/Bash"

#-------------------------------------------------------------------------------
# Write-Log: Centralized logging function with UTC timestamp
# Usage: Write-Log "INFO" "Message here"
#        Write-Log "SOURCE" "Loading file..."
#-------------------------------------------------------------------------------
Write-Log() {
    local LogLevel="$1"
    local Message="$2"
    local Timestamp
    Timestamp=$(date -u +"%Y/%m/%d %H:%M:%S.%3N")
    echo "[$Timestamp] - [$LogLevel] -   $Message"
}

#Source all enabled function files from Functions directory
if [[ -d "$FUNCTIONS_DIR" ]]; then
    for FUNC_FILE in "$FUNCTIONS_DIR"/*.sh; do
        if [[ -f "$FUNC_FILE" ]]; then
            #Check if ENABLED is set to false in the function file
            FUNC_ENABLED=$(grep -m1 '^ENABLED=' "$FUNC_FILE" 2>/dev/null | cut -d'"' -f2)
            if [[ "$FUNC_ENABLED" == "false" ]]; then
                Write-Log "SKIP" "Function file disabled: '$FUNC_FILE'"
                continue
            fi
            Write-Log "SOURCE" "Loading functions from '$FUNC_FILE'. Please Wait..."
            source "$FUNC_FILE"
        fi
    done
fi

#Make prompts non-interactive
export DEBIAN_FRONTEND=noninteractive

#Enable case-insensitive matching
shopt -s nocasematch

#OS Information
source /etc/os-release 2>/dev/null

#System Information
HOSTNAME=$(hostname)
HOSTNAMEUPPER=$(echo "$HOSTNAME" | awk '{print toupper($0)}')
HOSTNAMEFQDN=$(host -TtA $(hostname -s) 2>/dev/null | grep "has address" | awk '{print $1}')
CLOUDINITHOSTNAME=$(awk 'BEGIN{IGNORECASE=1} /^hostname:/{sub(/^hostname:[[:space:]]*/, ""); print; exit}' '/var/lib/cloud/instance/cloud-config.txt' 2>/dev/null)
CLOUDINITHOSTNAMEUPPER=$(echo "$CLOUDINITHOSTNAME" | awk '{print toupper($0)}')
CLOUDINITSEARCHDOMAINPRIMARY=$(cat /var/lib/cloud/instance/network-config.json 2>/dev/null | jq -r '.config.[1].search[0]' | sed 's/"//g')
SYSTEM_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null)

#Determine FQDN if not already set
if [[ -z "${HOSTNAMEFQDN}" ]]; then
    HOSTNAMEFQDN=$(hostname --fqdn 2>/dev/null)
fi

#Server FQDN for registrations
SERVER_FQDN="${CLOUDINITHOSTNAME}.${CLOUDINITSEARCHDOMAINPRIMARY}"

#Directory paths
DOWNLOADSROOTDIRECTORY="/downloads"
ROOTDIRECTORYNAME="custom"

#Arrays for configuration
declare -a UFWDenyRuleList=()
declare -a UFWAllowRuleList=()
declare -a DirectoryCreationEntryList=()
declare -a PackageRemovalEntryList=()
declare -a PackageInstallationEntryList=()
declare -a SnapPackageInstallationEntryList=()
declare -A GithubDownloadList
declare -A CronJobList

