#!/bin/bash
#===============================================================================
# 000-Packages.sh
# Idempotent package installation and removal
# Runs FIRST to ensure prerequisites are installed
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

#OS Information (needed for OS-specific packages)
source /etc/os-release 2>/dev/null

echo "=== Package Management ==="

#-------------------------------------------------------------------------------
# Arrays
#-------------------------------------------------------------------------------
declare -a PackageRemovalEntryList=()
declare -a PackageInstallationEntryList=()
declare -a SnapPackageInstallationEntryList=()

#-------------------------------------------------------------------------------
# Packages to Remove
#-------------------------------------------------------------------------------
PackageRemovalEntryList+=(
    #"openssh-server"
)

#-------------------------------------------------------------------------------
# APT Packages to Install
#-------------------------------------------------------------------------------
PackageInstallationEntryList+=(
    "qemu-guest-agent"
    "curl"
    "wget"
    "snapd"
    "net-tools"
    "lsb-release"
    "spice-webdavd"
    "openssl"
    "cifs-utils"
    "nfs-common"
    "whois"
    "traceroute"
    "cloud-guest-utils"
    "unattended-upgrades"
    "python3"
    "at"
    "make"
    "jq"
    "ipcalc"
    "sipcalc"
    "libcairo2"
    "libjpeg-turbo8"
    "libpng16-16"
    "libfontconfig1"
    "libfreetype6"
    "libfreerdp-client2-2"
    "libssh2-1"
    "libwebp6"
)

#OS-specific packages
if [[ "$NAME" =~ (.*Debian.*) ]]; then
    PackageInstallationEntryList+=(
        "software-properties-common"
        "ufw"
    )
elif [[ "$NAME" =~ (.*Ubuntu.*) ]]; then
    PackageInstallationEntryList+=(
        "btrfs-progs"
        "zfsutils-linux"
    )
fi

#-------------------------------------------------------------------------------
# Snap Packages to Install
#-------------------------------------------------------------------------------
SnapPackageInstallationEntryList+=(
    "powershell"
)

#-------------------------------------------------------------------------------
# Remove Packages
#-------------------------------------------------------------------------------
if [[ ${#PackageRemovalEntryList[@]} -gt 0 ]]; then
    echo "Removing packages..."
    for Package in "${PackageRemovalEntryList[@]}"; do
        Remove-Package "$Package"
    done
fi

#-------------------------------------------------------------------------------
# Update Package Lists
#-------------------------------------------------------------------------------
echo "Updating package lists..."
apt-get update -y -qq >/dev/null 2>&1

#-------------------------------------------------------------------------------
# Install APT Packages
#-------------------------------------------------------------------------------
echo "Installing APT packages..."
for Package in "${PackageInstallationEntryList[@]}"; do
    Install-Package "$Package"
    
    #Enable and start services that need it
    if [[ "$Package" == "at" ]]; then
        systemctl enable atd >/dev/null 2>&1
        systemctl start atd >/dev/null 2>&1
    fi
done

#-------------------------------------------------------------------------------
# Install Snap Packages
#-------------------------------------------------------------------------------
echo "Installing Snap packages..."
for Package in "${SnapPackageInstallationEntryList[@]}"; do
    Install-SnapPackage "$Package" "--classic"
done

echo "=== Package Management Complete ==="

