#!/bin/bash
#===============================================================================
# 010-DNSResolverFix.sh
# Description: Keeps port 53 from being binded to we can deploy docker containers that might need port 53
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
# Note: Logging is handled by the bootstrapper (tee to Scripts/Bash/Logs/)
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

Write-Log "INFO" "=== Script Description Here ==="

#!/usr/bin/env bash
set -euo pipefail

echo "== Checking for systemd-resolved =="
if ! systemctl is-active --quiet systemd-resolved; then
  echo "systemd-resolved is not active. Nothing to do."
  exit 0
fi

echo "== Checking if port 53 is bound =="
if ss -lntup | grep -q ':53 '; then
  echo "Port 53 is currently in use."
else
  echo "Port 53 is already free."
  exit 0
fi

CONF="/etc/systemd/resolved.conf"

echo "== Updating $CONF =="

# Ensure config file exists
if [ ! -f "$CONF" ]; then
  echo "Creating $CONF"
  sudo touch "$CONF"
fi

# Remove existing DNSStubListener lines
sudo sed -i '/^DNSStubListener=/d' "$CONF"

# Ensure [Resolve] section exists
if ! grep -q '^\[Resolve\]' "$CONF"; then
  echo "[Resolve]" | sudo tee -a "$CONF" >/dev/null
fi

# Add DNSStubListener=no
sudo sed -i '/^\[Resolve\]/a DNSStubListener=no' "$CONF"

echo "== Fixing /etc/resolv.conf =="

if [ -L /etc/resolv.conf ]; then
  sudo rm -f /etc/resolv.conf
fi

sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo "== Restarting systemd-resolved =="
sudo systemctl restart systemd-resolved

echo "== Verifying port 53 =="
if ss -lntup | grep -q ':53 '; then
  echo "❌ Port 53 is STILL in use:"
  ss -lntup | grep ':53 '
  exit 1
else
  echo "✅ Port 53 is free. Docker can bind it."
fi

echo "== Done =="

Write-Log "INFO" "=== Script Description Complete ==="
