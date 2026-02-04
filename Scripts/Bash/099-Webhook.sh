#!/bin/bash
#===============================================================================
# 010-WebhookSysinfo.sh
# Send system information webhook
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

Write-Log "INFO" "=== System Information Webhook ==="

#-------------------------------------------------------------------------------
# Webhook Configuration
#-------------------------------------------------------------------------------
WEBHOOK_URL="https://automation.example.com/webhook/YOUR_WEBHOOK_ID"
WEBHOOK_TOKEN="a996b3a1-b9ca-4a60-adcb-253a42777970"

#Gather network adapter information
Write-Log "INFO" "[GATHER] Network adapters"
NETWORK_ADAPTERS=$(ip -j addr show 2>/dev/null | jq '[.[] | select(.ifname != "lo") | {
    interface: .ifname,
    mac: .address,
    addresses: [.addr_info[] | select(.family == "inet") | {
        ip: .local,
        subnet_mask: (pow(2;32) - pow(2;(32-.prefixlen)) | floor | 
            "\(. / 16777216 | floor).\((. % 16777216) / 65536 | floor).\((. % 65536) / 256 | floor).\(. % 256)"),
        cidr: .prefixlen
    }]
}]' 2>/dev/null)

#Get public IP
Write-Log "INFO" "[GATHER] Public IP"
PUBLIC_IP=$(curl -fsS https://api.ipify.org 2>/dev/null || echo "unknown")

#Gather hard disk information
Write-Log "INFO" "[GATHER] Disk information"
HARD_DISKS=$(lsblk -J -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null | jq '[.blockdevices[] | select(.type == "disk") | {
    name: .name,
    size: .size,
    partitions: [.children[]? | {
        name: .name,
        size: .size,
        mountpoint: .mountpoint,
        fstype: .fstype
    }]
}]' 2>/dev/null)

#Get installed packages list
Write-Log "INFO" "[GATHER] Package list"
PACKAGE_LIST=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)

#Get OS information
OS_INFO=$(jq -n \
    --arg name "$NAME" \
    --arg version "$VERSION" \
    --arg version_id "$VERSION_ID" \
    --arg version_codename "$VERSION_CODENAME" \
    --arg kernel "$(uname -r)" \
    --arg arch "$(uname -m)" \
    '{
        name: $name,
        version: $version,
        version_id: $version_id,
        version_codename: $version_codename,
        kernel: $kernel,
        architecture: $arch
    }' 2>/dev/null)

#Get user accounts
USER_ACCOUNTS=$(getent passwd 2>/dev/null | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)

#Get DNS servers
DNS_SERVERS=$(resolvectl status 2>/dev/null | grep "DNS Servers" | awk '{for(i=3;i<=NF;i++) print $i}' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || \
    cat /etc/resolv.conf 2>/dev/null | grep "^nameserver" | awk '{print $2}' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)

#Build the full JSON payload
Write-Log "INFO" "[BUILD] Webhook payload"
WEBHOOK_PAYLOAD=$(jq -n \
    --arg hostname "$CLOUDINITHOSTNAMEUPPER" \
    --arg fqdn "$SERVER_FQDN" \
    --arg public_ip "$PUBLIC_IP" \
    --arg timezone "$SYSTEM_TIMEZONE" \
    --arg timestamp "$(date -Iseconds)" \
    --argjson network_adapters "${NETWORK_ADAPTERS:-[]}" \
    --argjson hard_disks "${HARD_DISKS:-[]}" \
    --argjson packages "${PACKAGE_LIST:-[]}" \
    --argjson os_info "${OS_INFO:-{}}" \
    --argjson user_accounts "${USER_ACCOUNTS:-[]}" \
    --argjson dns_servers "${DNS_SERVERS:-[]}" \
    '{
        hostname: $hostname,
        fqdn: $fqdn,
        public_ip: $public_ip,
        timezone: $timezone,
        timestamp: $timestamp,
        network_adapters: $network_adapters,
        hard_disks: $hard_disks,
        packages: $packages,
        os_info: $os_info,
        user_accounts: $user_accounts,
        dns_servers: $dns_servers
    }' 2>/dev/null)
    
echo "$WEBHOOK_PAYLOAD" | jq '.' 2>/dev/null

#Send the webhook
Write-Log "INFO" "[SEND] Webhook to ${WEBHOOK_URL}"
WEBHOOK_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${WEBHOOK_TOKEN}" \
    -d "$WEBHOOK_PAYLOAD" 2>/dev/null)
WEBHOOK_HTTP_CODE=$(echo "$WEBHOOK_RESPONSE" | tail -n1)

if [[ "$WEBHOOK_HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    Write-Log "INFO" "[OK] Webhook sent (HTTP $WEBHOOK_HTTP_CODE)"
else
    Write-Log "ERROR" "[FAIL] Webhook error (HTTP $WEBHOOK_HTTP_CODE)"
fi

Write-Log "INFO" "=== System Information Webhook Complete ==="

