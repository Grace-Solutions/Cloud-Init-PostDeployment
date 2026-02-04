#!/bin/bash
#===============================================================================
# 006-CronJobs.sh
# Cron job configuration for automatic updates
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

Write-Log "INFO" "=== Cron Job Configuration ==="

#Define cron jobs using Add-CronJob function
#Format: Schedule, Command

Add-CronJob "$(shuf -i 0-59 -n 1) 21 * * 6" "mkdir -p /custom/cron/logs/ && yes | DEBIAN_FRONTEND=noninteractive apt-get update -y > /custom/cron/logs/PerformAutomaticPackageUpdates.log 2>&1"

Add-CronJob "$(shuf -i 0-30 -n 1) 22 * * 6" "mkdir -p /custom/cron/logs/ && yes | DEBIAN_FRONTEND=noninteractive apt-get upgrade -y > /custom/cron/logs/PerformAutomaticPackageUpgrades.log 2>&1"

Add-CronJob "$(shuf -i 0-30 -n 1) 22 * * 6" "mkdir -p /custom/cron/logs/ && snap refresh > /custom/cron/logs/PerformAutomaticSnapRefresh.log 2>&1"

Add-CronJob "$(shuf -i 31-59 -n 1) 22 * * 6" "mkdir -p /custom/cron/logs/ && yes | DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y > /custom/cron/logs/PerformAutomaticDistributionUpgrade.log 2>&1"

Add-CronJob "$(shuf -i 0-59 -n 1) 23 * * 6" "mkdir -p /custom/cron/logs/ && /sbin/shutdown -r | at now +1 minutes > /custom/cron/logs/PerformAutomaticPackageUpgradesReboot.log 2>&1"

Write-Log "INFO" "=== Cron Job Configuration Complete ==="

