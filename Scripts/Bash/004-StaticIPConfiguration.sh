#!/bin/bash
#===============================================================================
# 004-StaticIPConfiguration.sh
# Description: Converts DHCP leases on RFC1918 interfaces to static IP config
#              - Loops through network interfaces with RFC1918 DHCP leases
#              - Sets static IP, gateway, DNS, and search domains from lease info
#              - Handles both base interfaces (ethernets) and VLAN subinterfaces (vlans)
#              - Uses netplan for persistent configuration
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
# INCLUDE_PATTERN: Regex pattern - only run if hostname matches (use ".*" to include all)
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
# INTERFACE_INCLUDE_PATTERN: Regex for interfaces to include (use ".*" to include all)
# INTERFACE_EXCLUDE_PATTERN: Regex for interfaces to exclude (use "^$" to exclude nothing)
# Note: Logging is handled by the bootstrapper (tee to Scripts/Bash/Logs/)
#-------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ENABLED="true"
INCLUDE_PATTERN="^(qdevice|technitium|dns|pve|omada|rvrsproxy|zoraxy|nginx|caddy|traefik|haproxy|bastion)"
EXCLUDE_PATTERN="^$"
INTERFACE_INCLUDE_PATTERN=".*"
INTERFACE_EXCLUDE_PATTERN="^$"

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

Write-Log "INFO" "=== Static IP Configuration from DHCP Leases ==="

#-------------------------------------------------------------------------------
# RFC1918 Check Function
# Returns 0 if IP is RFC1918 private address, 1 otherwise
#-------------------------------------------------------------------------------
Is-RFC1918() {
    local IP="$1"
    if [[ "$IP" =~ ^10\. ]] || \
       [[ "$IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
       [[ "$IP" =~ ^192\.168\. ]]; then
        return 0
    fi
    return 1
}

#-------------------------------------------------------------------------------
# Get gateway for interface from DHCP lease
# systemd-networkd stores leases by interface index in /run/systemd/netif/leases/
#-------------------------------------------------------------------------------
Get-InterfaceGateway() {
    local IFACE="$1"
    local GATEWAY=""

    #Get interface index
    local IFACE_INDEX=$(cat /sys/class/net/"$IFACE"/ifindex 2>/dev/null)

    #Try systemd-networkd lease file (named by interface index)
    if [[ -n "$IFACE_INDEX" && -f "/run/systemd/netif/leases/${IFACE_INDEX}" ]]; then
        GATEWAY=$(grep "^ROUTER=" "/run/systemd/netif/leases/${IFACE_INDEX}" 2>/dev/null | cut -d'=' -f2)
    fi

    #Try dhclient lease files
    if [[ -z "$GATEWAY" ]]; then
        local DHCLIENT_LEASE="/var/lib/dhcp/dhclient.${IFACE}.leases"
        if [[ -f "$DHCLIENT_LEASE" ]]; then
            GATEWAY=$(grep -oP 'option routers \K[0-9.]+' "$DHCLIENT_LEASE" 2>/dev/null | tail -1)
        fi
    fi

    #Try routing table
    if [[ -z "$GATEWAY" ]]; then
        GATEWAY=$(ip route show dev "$IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -1)
    fi
    if [[ -z "$GATEWAY" ]]; then
        GATEWAY=$(ip route show 2>/dev/null | awk "/default.*$IFACE/ {print \$3}" | head -1)
    fi

    #Fallback: derive gateway from IP (assume .1 on the subnet)
    if [[ -z "$GATEWAY" ]]; then
        local IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        if [[ -n "$IP" ]]; then
            local IP_ONLY="${IP%/*}"
            local IFS='.'
            read -r o1 o2 o3 o4 <<< "$IP_ONLY"
            GATEWAY="${o1}.${o2}.${o3}.1"
        fi
    fi

    echo "$GATEWAY"
}

#-------------------------------------------------------------------------------
# Check if interface is a VLAN subinterface
#-------------------------------------------------------------------------------
Is-VLANInterface() {
    local IFACE="$1"
    [[ "$IFACE" == *.* ]]
}

#-------------------------------------------------------------------------------
# Main Processing Loop
#-------------------------------------------------------------------------------
NETPLAN_FILE="/etc/netplan/70-StaticIPConfiguration.yaml"
INTERFACES_PROCESSED=0
INTERFACES_CONFIGURED=0
INTERFACES_SKIPPED=0
INTERFACES_FAILED=0
ETHERNETS_CONFIGURED=0
VLANS_CONFIGURED=0

Write-Log "INFO" "[CONFIG] Interface include pattern: $INTERFACE_INCLUDE_PATTERN"
Write-Log "INFO" "[CONFIG] Interface exclude pattern: $INTERFACE_EXCLUDE_PATTERN"

#Build YAML sections separately
YAML_ETHERNETS=""
YAML_VLANS=""

#Get all network interfaces (excluding lo, docker, veth, br-, virbr)
INTERFACE_LIST=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|virbr)')

for IFACE in $INTERFACE_LIST; do
    INTERFACES_PROCESSED=$((INTERFACES_PROCESSED + 1))

    #Determine interface type
    if Is-VLANInterface "$IFACE"; then
        IFACE_TYPE="VLAN"
        BASE_IFACE="${IFACE%.*}"
        VLAN_ID="${IFACE##*.}"
    else
        IFACE_TYPE="ethernet"
        BASE_IFACE=""
        VLAN_ID=""
    fi

    Write-Log "INFO" "[PROCESS] ($INTERFACES_PROCESSED) Checking $IFACE_TYPE interface: $IFACE"

    #Enable case-insensitive matching for interface patterns
    shopt -s nocasematch

    #Check interface include pattern
    if [[ ! "$IFACE" =~ $INTERFACE_INCLUDE_PATTERN ]]; then
        Write-Log "SKIP" "  Interface '$IFACE' does not match include pattern"
        shopt -u nocasematch
        INTERFACES_SKIPPED=$((INTERFACES_SKIPPED + 1))
        continue
    fi

    #Check interface exclude pattern
    if [[ "$IFACE" =~ $INTERFACE_EXCLUDE_PATTERN ]]; then
        Write-Log "SKIP" "  Interface '$IFACE' matches exclude pattern"
        shopt -u nocasematch
        INTERFACES_SKIPPED=$((INTERFACES_SKIPPED + 1))
        continue
    fi

    shopt -u nocasematch

    #Get current IP address
    CURRENT_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)

    if [[ -z "$CURRENT_IP" ]]; then
        Write-Log "SKIP" "  Interface '$IFACE' has no IPv4 address"
        INTERFACES_SKIPPED=$((INTERFACES_SKIPPED + 1))
        continue
    fi

    #Extract IP without CIDR
    IP_ONLY="${CURRENT_IP%/*}"
    CIDR="${CURRENT_IP#*/}"

    #Check if RFC1918
    if ! Is-RFC1918 "$IP_ONLY"; then
        Write-Log "SKIP" "  Interface '$IFACE' IP '$IP_ONLY' is not RFC1918"
        INTERFACES_SKIPPED=$((INTERFACES_SKIPPED + 1))
        continue
    fi

    Write-Log "INFO" "  [RFC1918] Interface '$IFACE' has private IP: $CURRENT_IP"

    #Get gateway for this interface
    GATEWAY=$(Get-InterfaceGateway "$IFACE")

    #Get DNS servers from systemd-resolved or resolvconf
    DNS_SERVERS=""
    if command -v resolvectl &>/dev/null; then
        DNS_SERVERS=$(resolvectl dns "$IFACE" 2>/dev/null | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}' | xargs)
    fi
    if [[ -z "$DNS_SERVERS" ]]; then
        DNS_SERVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | head -3 | xargs)
    fi

    #Get search domains
    SEARCH_DOMAINS=""
    if command -v resolvectl &>/dev/null; then
        SEARCH_DOMAINS=$(resolvectl domain "$IFACE" 2>/dev/null | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}' | xargs)
    fi
    if [[ -z "$SEARCH_DOMAINS" ]]; then
        SEARCH_DOMAINS=$(awk '/^search/ {for(i=2;i<=NF;i++) printf "%s ", $i}' /etc/resolv.conf 2>/dev/null | xargs)
    fi

    Write-Log "INFO" "  [LEASE] Gateway: ${GATEWAY:-none}"
    Write-Log "INFO" "  [LEASE] DNS: ${DNS_SERVERS:-none}"
    Write-Log "INFO" "  [LEASE] Search: ${SEARCH_DOMAINS:-none}"

    #Build YAML based on interface type
    if [[ "$IFACE_TYPE" == "VLAN" ]]; then
        #VLAN subinterface - goes in vlans: section
        YAML_VLANS="$YAML_VLANS
    $IFACE:
      id: $VLAN_ID
      link: $BASE_IFACE
      dhcp4: false
      addresses:
        - $CURRENT_IP"

        #VLANs typically don't get default routes (handled by base interface)
        #But add route if gateway exists and is on this subnet
        if [[ -n "$GATEWAY" ]]; then
            YAML_VLANS="$YAML_VLANS
      routes:
        - to: default
          via: $GATEWAY"
        fi

        if [[ -n "$DNS_SERVERS" ]]; then
            YAML_VLANS="$YAML_VLANS
      nameservers:
        addresses:"
            for DNS in $DNS_SERVERS; do
                YAML_VLANS="$YAML_VLANS
          - $DNS"
            done

            if [[ -n "$SEARCH_DOMAINS" ]]; then
                YAML_VLANS="$YAML_VLANS
        search:"
                for DOMAIN in $SEARCH_DOMAINS; do
                    YAML_VLANS="$YAML_VLANS
          - $DOMAIN"
                done
            fi
        fi

        VLANS_CONFIGURED=$((VLANS_CONFIGURED + 1))
    else
        #Base ethernet interface - goes in ethernets: section
        YAML_ETHERNETS="$YAML_ETHERNETS
    $IFACE:
      dhcp4: false
      addresses:
        - $CURRENT_IP"

        if [[ -n "$GATEWAY" ]]; then
            YAML_ETHERNETS="$YAML_ETHERNETS
      routes:
        - to: default
          via: $GATEWAY"
        fi

        if [[ -n "$DNS_SERVERS" ]]; then
            YAML_ETHERNETS="$YAML_ETHERNETS
      nameservers:
        addresses:"
            for DNS in $DNS_SERVERS; do
                YAML_ETHERNETS="$YAML_ETHERNETS
          - $DNS"
            done

            if [[ -n "$SEARCH_DOMAINS" ]]; then
                YAML_ETHERNETS="$YAML_ETHERNETS
        search:"
                for DOMAIN in $SEARCH_DOMAINS; do
                    YAML_ETHERNETS="$YAML_ETHERNETS
          - $DOMAIN"
                done
            fi
        fi

        ETHERNETS_CONFIGURED=$((ETHERNETS_CONFIGURED + 1))
    fi

    INTERFACES_CONFIGURED=$((INTERFACES_CONFIGURED + 1))
    Write-Log "INFO" "  [OK] $IFACE_TYPE interface '$IFACE' prepared for static configuration"
done

#-------------------------------------------------------------------------------
# Apply Configuration
#-------------------------------------------------------------------------------
Write-Log "INFO" "=== Configuration Summary ==="
Write-Log "INFO" "[STATS] Interfaces processed: $INTERFACES_PROCESSED"
Write-Log "INFO" "[STATS] Interfaces configured: $INTERFACES_CONFIGURED (ethernets: $ETHERNETS_CONFIGURED, vlans: $VLANS_CONFIGURED)"
Write-Log "INFO" "[STATS] Interfaces skipped: $INTERFACES_SKIPPED"
Write-Log "INFO" "[STATS] Interfaces failed: $INTERFACES_FAILED"

if [[ $INTERFACES_CONFIGURED -eq 0 ]]; then
    Write-Log "INFO" "[SKIP] No interfaces to configure"
    Write-Log "INFO" "=== Static IP Configuration Complete ==="
    exit 0
fi

#Build complete YAML content
YAML_CONTENT="network:
  version: 2"

#Add ethernets section if we have any
if [[ $ETHERNETS_CONFIGURED -gt 0 ]]; then
    YAML_CONTENT="${YAML_CONTENT}
  ethernets:${YAML_ETHERNETS}"
fi

#Add vlans section if we have any
if [[ $VLANS_CONFIGURED -gt 0 ]]; then
    YAML_CONTENT="${YAML_CONTENT}
  vlans:${YAML_VLANS}"
fi

#Check if configuration already exists and matches
if [[ -f "$NETPLAN_FILE" ]]; then
    EXISTING_CONTENT=$(cat "$NETPLAN_FILE")
    if [[ "$EXISTING_CONTENT" == "$YAML_CONTENT" ]]; then
        Write-Log "INFO" "[SKIP] Netplan configuration already exists and matches"
        Write-Log "INFO" "=== Static IP Configuration Complete ==="
        exit 0
    else
        Write-Log "INFO" "[UPDATE] Netplan configuration changed, updating"
    fi
else
    Write-Log "INFO" "[CREATE] Writing new netplan configuration"
fi

#Write configuration
echo "$YAML_CONTENT" > "$NETPLAN_FILE"
chmod 600 "$NETPLAN_FILE"

Write-Log "INFO" "[APPLY] Applying netplan configuration"
if netplan apply 2>&1; then
    Write-Log "INFO" "[OK] Netplan configuration applied successfully"
else
    Write-Log "ERROR" "[FAIL] Netplan apply failed"
    exit 1
fi

Write-Log "INFO" "=== Static IP Configuration Complete ==="
