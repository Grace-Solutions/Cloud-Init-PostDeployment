#!/bin/bash
#===============================================================================
# 003-VLANConfiguration.sh
# Description: Configure VLAN subinterfaces using netplan (systemd-networkd)
#              - Creates VLAN subinterfaces with DHCP
#              - Prevents VLAN interfaces from installing default routes
#              - Base interface retains default route ownership
#              - Persists across reboots via netplan configuration
#              - Configures Policy-Based Routing (PBR) for symmetric routing
#              - Traffic entering a VLAN exits via the same VLAN's gateway
#===============================================================================

#Source shared variables and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/001-Variables.sh"

#-------------------------------------------------------------------------------
# Script Configuration
# ENABLED: "true" to run, "false" to skip
# INCLUDE_PATTERN: Regex pattern - only run if hostname matches (use ".*" to include all)
# EXCLUDE_PATTERN: Regex pattern - skip if hostname matches (use "^$" to exclude nothing)
# Note: Logging is handled by the bootstrapper (tee to Scripts/Bash/Logs/)
#-------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ENABLED="true"
INCLUDE_PATTERN="^(Nothing|Never)"
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

Write-Log "INFO" "=== VLAN Configuration ==="

#-------------------------------------------------------------------------------
# VLAN Configuration
# BASE_INTERFACE: Set to specific interface (e.g., "eth0") or "auto" to detect
#-------------------------------------------------------------------------------
BASE_INTERFACE="auto"
VLAN_IDS="10,20,30,40,50,60,70,80,90,100,110"

#Resolve base interface if set to auto
if [[ "$BASE_INTERFACE" == "auto" ]]; then
    BASE_INTERFACE=$(ip route show default | awk '{print $5}' | head -1)
    if [[ -z "$BASE_INTERFACE" ]]; then
        Write-Log "ERROR" "$SCRIPT_NAME - Could not detect default route interface"
        exit 1
    fi
    Write-Log "INFO" "[DETECT] Auto-detected base interface: $BASE_INTERFACE"
fi

#Set netplan filename based on interface
NETPLAN_FILE="/etc/netplan/60-${BASE_INTERFACE}-vlans.yaml"

#Parse VLAN IDs into array
IFS=',' read -ra VLAN_ARRAY <<< "$VLAN_IDS"

Write-Log "INFO" "[CONFIG] Base interface: $BASE_INTERFACE"
Write-Log "INFO" "[CONFIG] VLAN IDs: ${VLAN_ARRAY[*]}"
Write-Log "INFO" "[CONFIG] Netplan file: $NETPLAN_FILE"

#-------------------------------------------------------------------------------
# Generate netplan YAML for VLANs
#-------------------------------------------------------------------------------
Write-Log "INFO" "[BUILD] Generating netplan configuration"

#Start YAML content
YAML_CONTENT="network:
  version: 2
  vlans:"

#Add each VLAN
for VLAN_ID in "${VLAN_ARRAY[@]}"; do
    VLAN_INTERFACE="${BASE_INTERFACE}.${VLAN_ID}"

    YAML_CONTENT="$YAML_CONTENT
    $VLAN_INTERFACE:
      id: $VLAN_ID
      link: $BASE_INTERFACE
      dhcp4: true
      dhcp4-overrides:
        use-routes: false"
done

#-------------------------------------------------------------------------------
# Check if configuration already exists and matches (idempotent)
#-------------------------------------------------------------------------------
if [[ -f "$NETPLAN_FILE" ]]; then
    EXISTING_CONTENT=$(cat "$NETPLAN_FILE")
    if [[ "$EXISTING_CONTENT" == "$YAML_CONTENT" ]]; then
        Write-Log "INFO" "[SKIP] Netplan configuration already exists and matches"

        #Verify all interfaces are up
        ALL_UP=true
        for VLAN_ID in "${VLAN_ARRAY[@]}"; do
            VLAN_INTERFACE="${BASE_INTERFACE}.${VLAN_ID}"
            if ! ip link show "$VLAN_INTERFACE" &>/dev/null; then
                ALL_UP=false
                break
            fi
        done

        if [[ "$ALL_UP" == "true" ]]; then
            Write-Log "INFO" "[OK] All VLAN interfaces already configured"
        else
            Write-Log "INFO" "[APPLY] Some interfaces missing, reapplying netplan"
            netplan apply 2>&1
            sleep 5
        fi
    else
        Write-Log "INFO" "[UPDATE] Netplan configuration changed, updating"
        echo "$YAML_CONTENT" > "$NETPLAN_FILE"
        chmod 600 "$NETPLAN_FILE"
        netplan apply 2>&1
        sleep 5
    fi
else
    Write-Log "INFO" "[CREATE] Writing new netplan configuration"
    echo "$YAML_CONTENT" > "$NETPLAN_FILE"
    chmod 600 "$NETPLAN_FILE"
    Write-Log "INFO" "[APPLY] Applying netplan configuration"
    netplan apply 2>&1
    sleep 5
fi

#-------------------------------------------------------------------------------
# Wait for DHCP leases on all VLAN interfaces
# DHCP may take a few seconds after interface comes up
#-------------------------------------------------------------------------------
Write-Log "INFO" "=== Waiting for DHCP Leases ==="

DHCP_WAIT_MAX=30
DHCP_WAIT_INTERVAL=2
DHCP_WAIT_ELAPSED=0

while [[ $DHCP_WAIT_ELAPSED -lt $DHCP_WAIT_MAX ]]; do
    VLANS_WITH_IP=0
    VLANS_WITHOUT_IP=0

    for VLAN_ID in "${VLAN_ARRAY[@]}"; do
        VLAN_INTERFACE="${BASE_INTERFACE}.${VLAN_ID}"
        if ip -4 addr show "$VLAN_INTERFACE" 2>/dev/null | grep -q 'inet '; then
            VLANS_WITH_IP=$((VLANS_WITH_IP + 1))
        else
            VLANS_WITHOUT_IP=$((VLANS_WITHOUT_IP + 1))
        fi
    done

    if [[ $VLANS_WITHOUT_IP -eq 0 ]]; then
        Write-Log "INFO" "[DHCP] All ${#VLAN_ARRAY[@]} VLAN interfaces have IP addresses"
        break
    fi

    Write-Log "INFO" "[DHCP] Waiting... ($VLANS_WITH_IP/${#VLAN_ARRAY[@]} have IPs, ${DHCP_WAIT_ELAPSED}s elapsed)"
    sleep $DHCP_WAIT_INTERVAL
    DHCP_WAIT_ELAPSED=$((DHCP_WAIT_ELAPSED + DHCP_WAIT_INTERVAL))
done

if [[ $VLANS_WITHOUT_IP -gt 0 ]]; then
    Write-Log "WARN" "[DHCP] Timeout: $VLANS_WITHOUT_IP interfaces still without IP after ${DHCP_WAIT_MAX}s"
fi

#-------------------------------------------------------------------------------
# Policy-Based Routing (PBR) Configuration
# Ensures traffic entering a VLAN interface exits via the same interface
# Uses iproute2 routing tables and ip rules
#-------------------------------------------------------------------------------
Write-Log "INFO" "=== Policy-Based Routing Configuration ==="

#PBR Configuration
PBR_ENABLED="true"
PBR_TABLE_BASE=100
PBR_RULE_PRIORITY_BASE=100
PBR_SCRIPT="/etc/network/if-up.d/vlan-pbr"
PBR_RT_TABLES="/etc/iproute2/rt_tables"

#-------------------------------------------------------------------------------
# Calculate network CIDR from IP and prefix length
# Usage: Get-NetworkCIDR "192.168.1.100/24" -> "192.168.1.0/24"
#-------------------------------------------------------------------------------
Get-NetworkCIDR() {
    local IP_CIDR="$1"
    local IP="${IP_CIDR%/*}"
    local PREFIX="${IP_CIDR#*/}"

    #Convert IP to integer
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$IP"
    local IP_INT=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))

    #Calculate netmask
    local NETMASK=$(( 0xFFFFFFFF << (32 - PREFIX) & 0xFFFFFFFF ))

    #Calculate network address
    local NET_INT=$(( IP_INT & NETMASK ))

    #Convert back to dotted notation
    local NET_O1=$(( (NET_INT >> 24) & 255 ))
    local NET_O2=$(( (NET_INT >> 16) & 255 ))
    local NET_O3=$(( (NET_INT >> 8) & 255 ))
    local NET_O4=$(( NET_INT & 255 ))

    echo "${NET_O1}.${NET_O2}.${NET_O3}.${NET_O4}/${PREFIX}"
}

#-------------------------------------------------------------------------------
# Get gateway for interface from DHCP lease or routing table
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

if [[ "$PBR_ENABLED" == "true" ]]; then
    Write-Log "INFO" "[PBR] Configuring policy-based routing for VLAN interfaces"

    #Ensure iproute2 rt_tables exists
    if [[ ! -f "$PBR_RT_TABLES" ]]; then
        Write-Log "WARN" "[PBR] $PBR_RT_TABLES not found, creating"
        mkdir -p "$(dirname "$PBR_RT_TABLES")"
        echo "# Reserved routing tables" > "$PBR_RT_TABLES"
        echo "255     local" >> "$PBR_RT_TABLES"
        echo "254     main" >> "$PBR_RT_TABLES"
        echo "253     default" >> "$PBR_RT_TABLES"
        echo "0       unspec" >> "$PBR_RT_TABLES"
    fi

    #Counters
    PBR_CONFIGURED=0
    PBR_SKIPPED=0
    PBR_FAILED=0

    #Configure PBR for each VLAN
    TABLE_NUM=$PBR_TABLE_BASE
    RULE_PRIORITY=$PBR_RULE_PRIORITY_BASE

    for VLAN_ID in "${VLAN_ARRAY[@]}"; do
        VLAN_INTERFACE="${BASE_INTERFACE}.${VLAN_ID}"
        TABLE_NAME="vlan${VLAN_ID}"

        Write-Log "INFO" "[PBR] Processing VLAN $VLAN_ID (table: $TABLE_NAME, id: $TABLE_NUM)"

        #Get interface IP
        VLAN_IP=$(ip -4 addr show "$VLAN_INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)

        if [[ -z "$VLAN_IP" ]]; then
            Write-Log "SKIP" "[PBR]   Interface $VLAN_INTERFACE has no IP yet"
            PBR_SKIPPED=$((PBR_SKIPPED + 1))
            TABLE_NUM=$((TABLE_NUM + 1))
            RULE_PRIORITY=$((RULE_PRIORITY + 1))
            continue
        fi

        #Calculate network CIDR
        VLAN_NETWORK=$(Get-NetworkCIDR "$VLAN_IP")
        VLAN_IP_ONLY="${VLAN_IP%/*}"

        #Get gateway
        VLAN_GATEWAY=$(Get-InterfaceGateway "$VLAN_INTERFACE")

        if [[ -z "$VLAN_GATEWAY" ]]; then
            Write-Log "WARN" "[PBR]   Could not determine gateway for $VLAN_INTERFACE"
            PBR_FAILED=$((PBR_FAILED + 1))
            TABLE_NUM=$((TABLE_NUM + 1))
            RULE_PRIORITY=$((RULE_PRIORITY + 1))
            continue
        fi

        Write-Log "INFO" "[PBR]   IP: $VLAN_IP, Network: $VLAN_NETWORK, Gateway: $VLAN_GATEWAY"

        #Add routing table entry if not exists
        if ! grep -q "^${TABLE_NUM}[[:space:]]" "$PBR_RT_TABLES" 2>/dev/null; then
            echo "${TABLE_NUM}     ${TABLE_NAME}" >> "$PBR_RT_TABLES"
            Write-Log "INFO" "[PBR]   Added routing table: $TABLE_NUM $TABLE_NAME"
        fi

        #Flush existing routes in this table
        ip route flush table "$TABLE_NAME" 2>/dev/null

        #Add routes to the custom table
        ip route add "$VLAN_NETWORK" dev "$VLAN_INTERFACE" src "$VLAN_IP_ONLY" table "$TABLE_NAME" 2>/dev/null
        ip route add default via "$VLAN_GATEWAY" dev "$VLAN_INTERFACE" table "$TABLE_NAME" 2>/dev/null

        #Add ip rule for traffic from this interface's IP
        if ! ip rule show | grep -q "from ${VLAN_IP_ONLY} lookup ${TABLE_NAME}"; then
            ip rule add from "$VLAN_IP_ONLY" table "$TABLE_NAME" priority "$RULE_PRIORITY" 2>/dev/null
            Write-Log "INFO" "[PBR]   Added rule: from $VLAN_IP_ONLY lookup $TABLE_NAME (priority $RULE_PRIORITY)"
        else
            Write-Log "INFO" "[PBR]   Rule already exists: from $VLAN_IP_ONLY lookup $TABLE_NAME"
        fi

        PBR_CONFIGURED=$((PBR_CONFIGURED + 1))
        TABLE_NUM=$((TABLE_NUM + 1))
        RULE_PRIORITY=$((RULE_PRIORITY + 1))
    done

    Write-Log "INFO" "[PBR] Configured: $PBR_CONFIGURED, Skipped: $PBR_SKIPPED, Failed: $PBR_FAILED"

    #-------------------------------------------------------------------------------
    # Create persistent PBR script for if-up.d
    #-------------------------------------------------------------------------------
    Write-Log "INFO" "[PBR] Creating persistent PBR script"

    mkdir -p "$(dirname "$PBR_SCRIPT")"

    cat > "$PBR_SCRIPT" << 'PBREOF'
#!/bin/bash
#===============================================================================
# vlan-pbr - Policy-Based Routing for VLAN interfaces
# Auto-generated by 009-VLANConfiguration.sh
# Runs on interface up to configure PBR rules
#===============================================================================

RT_TABLES="/etc/iproute2/rt_tables"

#Only process VLAN interfaces (contain a dot)
[[ "$IFACE" != *.* ]] && exit 0

#Extract VLAN ID from interface name
VLAN_ID="${IFACE##*.}"
TABLE_NAME="vlan${VLAN_ID}"

#Check if table exists in rt_tables first
if ! grep -q "[[:space:]]${TABLE_NAME}$" "$RT_TABLES" 2>/dev/null; then
    exit 0
fi

#Get interface IP
IP_CIDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
[[ -z "$IP_CIDR" ]] && exit 0

IP_ONLY="${IP_CIDR%/*}"
PREFIX="${IP_CIDR#*/}"

#Calculate network address
IFS='.' read -r o1 o2 o3 o4 <<< "$IP_ONLY"
IP_INT=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
NETMASK=$(( 0xFFFFFFFF << (32 - PREFIX) & 0xFFFFFFFF ))
NET_INT=$(( IP_INT & NETMASK ))
NET_O1=$(( (NET_INT >> 24) & 255 ))
NET_O2=$(( (NET_INT >> 16) & 255 ))
NET_O3=$(( (NET_INT >> 8) & 255 ))
NET_O4=$(( NET_INT & 255 ))
NETWORK="${NET_O1}.${NET_O2}.${NET_O3}.${NET_O4}/${PREFIX}"

#Get gateway from DHCP lease
GATEWAY=""

#Try systemd-networkd lease (by interface index)
IFACE_INDEX=$(cat /sys/class/net/"$IFACE"/ifindex 2>/dev/null)
if [[ -n "$IFACE_INDEX" && -f "/run/systemd/netif/leases/${IFACE_INDEX}" ]]; then
    GATEWAY=$(grep "^ROUTER=" "/run/systemd/netif/leases/${IFACE_INDEX}" 2>/dev/null | cut -d'=' -f2)
fi

#Fallback: derive gateway from IP (assume .1)
if [[ -z "$GATEWAY" ]]; then
    GATEWAY="${o1}.${o2}.${o3}.1"
fi

#Flush and configure routes
ip route flush table "$TABLE_NAME" 2>/dev/null
ip route add "$NETWORK" dev "$IFACE" src "$IP_ONLY" table "$TABLE_NAME" 2>/dev/null
ip route add default via "$GATEWAY" dev "$IFACE" table "$TABLE_NAME" 2>/dev/null

#Add rule if not exists
if ! ip rule show | grep -q "from ${IP_ONLY} lookup ${TABLE_NAME}"; then
    PRIORITY=$((100 + VLAN_ID))
    ip rule add from "$IP_ONLY" table "$TABLE_NAME" priority "$PRIORITY" 2>/dev/null
fi

exit 0
PBREOF

    chmod +x "$PBR_SCRIPT"
    Write-Log "INFO" "[PBR] Created $PBR_SCRIPT"

else
    Write-Log "INFO" "[PBR] Policy-based routing is disabled"
fi

Write-Log "INFO" "=== Policy-Based Routing Complete ==="

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
Write-Log "INFO" "=== Network Summary ==="

#Function to get interface info
Get-InterfaceInfo() {
    local IFACE="$1"
    local VLAN="$2"
    local PARENT_IFACE="$3"
    local MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/link\/ether/ {print $2}')

    #Fall back to parent interface MAC for VLAN subinterfaces
    if [[ -z "$MAC" && -n "$PARENT_IFACE" ]]; then
        MAC=$(ip link show "$PARENT_IFACE" 2>/dev/null | awk '/link\/ether/ {print $2}')
    fi

    local IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)

    if [[ -n "$VLAN" ]]; then
        printf "  %-15s  %-17s  VLAN %-3s  %s\n" "$IFACE" "${MAC:-N/A}" "$VLAN" "${IP:-N/A}"
    else
        printf "  %-15s  %-17s  %-9s  %s\n" "$IFACE" "${MAC:-N/A}" "(base)" "${IP:-N/A}"
    fi
}

Write-Log "INFO" "  Interface        MAC                Type       IP"
Write-Log "INFO" "  --------------- -----------------  ---------  ---------------"

#Show base interface
Get-InterfaceInfo "$BASE_INTERFACE" "" "" | while read -r line; do Write-Log "INFO" "$line"; done

#Show VLAN subinterfaces
for VLAN_ID in "${VLAN_ARRAY[@]}"; do
    VLAN_INTERFACE="${BASE_INTERFACE}.${VLAN_ID}"
    Get-InterfaceInfo "$VLAN_INTERFACE" "$VLAN_ID" "$BASE_INTERFACE" | while read -r line; do Write-Log "INFO" "$line"; done
done

Write-Log "INFO" "=== VLAN Configuration Complete ==="

