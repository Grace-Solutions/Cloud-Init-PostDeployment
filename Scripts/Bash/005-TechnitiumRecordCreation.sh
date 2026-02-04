#!/bin/bash
#===============================================================================
# 005-TechnitiumRecordCreation.sh
# Description: Registers local IP addresses as DNS records and DHCP reservations
#              in Technitium DNS Server
#              - Idempotent: Safe to run multiple times; updates existing records
#              - Auto-detects hostname, IP addresses, MAC addresses, and DHCP scopes
#              - Supports IPv4, IPv6, or both
#              - Separates physical IPs from VPN IPs (Tailscale/Netbird CGNAT)
#              - Physical IPs go into standard zones; VPN IPs only go into VPN zones
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

Write-Log "INFO" "=== Technitium DNS/DHCP Record Creation ==="

set -euo pipefail

#-------------------------------------------------------------------------------
# Technitium Configuration
# DEFAULT_TOKEN: API token for Technitium
# DEFAULT_BASE_URL: Base URL for Technitium API
# DEFAULT_ZONE: Default DNS zone
# DEFAULT_TTL: Default TTL for DNS records
# INSECURE_SSL: Set to "true" to skip SSL certificate verification (for self-signed certs)
#-------------------------------------------------------------------------------
readonly DEFAULT_TOKEN="YOUR_TECHNITIUM_API_TOKEN_HERE"
#readonly DEFAULT_BASE_URL="https://dns.example.com"
readonly DEFAULT_BASE_URL="https://dns.example.local:53443"
readonly DEFAULT_ZONE="example.local"
readonly DEFAULT_TTL="3600"
readonly INSECURE_SSL="true"
readonly USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Log file for Technitium-specific logging (in addition to Write-Log)
LOG_FILE="/var/log/Technitium/${SCRIPT_NAME}.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

#endregion Configuration and Defaults

#region Logging Functions
# These functions integrate with Write-Log from 001-Variables.sh
# and also write to the Technitium-specific log file

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S.%3N UTC')"
    local formatted="[${timestamp}] [${level}] ${message}"

    # Write to Technitium-specific log file
    echo "${formatted}" >> "${LOG_FILE}" 2>/dev/null || true

    # Also use Write-Log for bootstrap integration
    Write-Log "${level}" "${message}"
}

log_info()  { log_message "INFO" "$1"; }
log_warn()  { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_debug() { [[ "${VERBOSE:-false}" == "true" ]] && log_message "DEBUG" "$1" || true; }

log_operation_start() {
    log_info "OPERATION START: $1"
}

log_operation_complete() {
    log_info "OPERATION COMPLETE: $1"
}

log_operation_error() {
    local operation="$1"
    local error_output="$2"
    log_error "OPERATION FAILED: ${operation}"
    log_error "Error details: ${error_output}"
}

#endregion Logging Functions

#region Package Management

check_and_install_package() {
    local package="$1"
    
    log_operation_start "Checking for package: ${package}"
    
    if command -v "${package}" &>/dev/null; then
        log_operation_complete "Package '${package}' is already installed"
        return 0
    fi
    
    log_warn "Package '${package}' not found. Attempting to install..."
    
    local install_cmd=""
    if command -v apt-get &>/dev/null; then
        install_cmd="apt-get update && apt-get install -y ${package}"
    elif command -v yum &>/dev/null; then
        install_cmd="yum install -y ${package}"
    elif command -v dnf &>/dev/null; then
        install_cmd="dnf install -y ${package}"
    elif command -v pacman &>/dev/null; then
        install_cmd="pacman -S --noconfirm ${package}"
    elif command -v apk &>/dev/null; then
        install_cmd="apk add ${package}"
    elif command -v zypper &>/dev/null; then
        install_cmd="zypper install -y ${package}"
    else
        log_error "No supported package manager found. Please install '${package}' manually."
        return 1
    fi
    
    log_info "Running: ${install_cmd}"
    
    local error_output
    if error_output=$(eval "sudo ${install_cmd}" 2>&1); then
        log_operation_complete "Package '${package}' installed successfully"
        return 0
    else
        log_operation_error "Installing package '${package}'" "${error_output}"
        return 1
    fi
}

install_required_packages() {
    log_operation_start "Installing required packages"
    
    local packages=("jq" "curl")
    local total=${#packages[@]}
    local current=0
    
    for package in "${packages[@]}"; do
        ((current++)) || true
        local percent=$((current * 100 / total))
        log_info "Installing packages: ${current}/${total} (${percent}%) - ${package}"
        
        if ! check_and_install_package "${package}"; then
            log_error "Failed to install required package: ${package}"
            return 1
        fi
    done
    
    log_operation_complete "All required packages installed"
    return 0
}

#endregion Package Management

#region URL Encoding

urlencode() {
    local string="$1"
    local encoded=""
    local i char
    
    for ((i = 0; i < ${#string}; i++)); do
        char="${string:i:1}"
        case "${char}" in
            [a-zA-Z0-9.~_-])
                encoded+="${char}"
                ;;
            *)
                encoded+=$(printf '%%%02X' "'${char}")
                ;;
        esac
    done
    
    echo "${encoded}"
}

#endregion URL Encoding

#region IP Address Discovery

# Check if an interface should be excluded (Docker, Podman, virtual, etc.)
is_excluded_interface() {
    local ifname="$1"

    # Docker interfaces: docker0, br-*, veth*
    # Podman interfaces: podman*, cni-*, veth*
    # Other virtual: virbr*, lxcbr*, lxdbr*
    case "${ifname}" in
        docker*|br-*|veth*|podman*|cni-*|virbr*|lxcbr*|lxdbr*)
            return 0  # Excluded
            ;;
        *)
            return 1  # Not excluded
            ;;
    esac
}

# Check if an IP should be excluded (loopback, APIPA, link-local)
is_excluded_ip() {
    local ip="$1"
    local family="$2"  # inet or inet6

    if [[ "${family}" == "inet" ]]; then
        # IPv4: Skip loopback (127.x.x.x) and APIPA (169.254.x.x)
        if [[ "${ip}" =~ ^127\. || "${ip}" =~ ^169\.254\. ]]; then
            return 0  # Excluded
        fi
    elif [[ "${family}" == "inet6" ]]; then
        # IPv6: Skip loopback (::1) and link-local (fe80::)
        if [[ "${ip}" == "::1" || "${ip}" =~ ^fe80: ]]; then
            return 0  # Excluded
        fi
    fi

    return 1  # Not excluded
}

get_local_ip_addresses() {
    local ip_version="$1"  # 4, 6, or both
    local addresses=()

    log_operation_start "Discovering local IP addresses (version: ${ip_version})"

    # Use JSON output from ip command for reliable parsing with interface names
    local ip_json
    if ! ip_json=$(ip -j addr show 2>/dev/null); then
        # Fallback to non-JSON if -j not supported
        log_debug "JSON output not supported, using text parsing"
        ip_json=""
    fi

    if [[ -n "${ip_json}" ]]; then
        # Parse JSON output - gives us interface name and IP together
        while IFS='|' read -r ifname family ip_addr; do
            [[ -z "${ip_addr}" ]] && continue

            # Check interface exclusions (Docker, Podman, etc.)
            if is_excluded_interface "${ifname}"; then
                log_debug "Skipping excluded interface: ${ifname} (${ip_addr})"
                continue
            fi

            # Check IP exclusions (loopback, APIPA, link-local)
            if is_excluded_ip "${ip_addr}" "${family}"; then
                log_debug "Skipping excluded IP: ${ip_addr}"
                continue
            fi

            # Filter by requested IP version
            if [[ "${family}" == "inet" ]]; then
                if [[ "${ip_version}" == "4" || "${ip_version}" == "both" ]]; then
                    addresses+=("${ip_addr}|A")
                fi
            elif [[ "${family}" == "inet6" ]]; then
                if [[ "${ip_version}" == "6" || "${ip_version}" == "both" ]]; then
                    addresses+=("${ip_addr}|AAAA")
                fi
            fi
        done < <(echo "${ip_json}" | jq -r '.[] | .ifname as $if | .addr_info[]? | "\($if)|\(.family)|\(.local)"' 2>/dev/null)
    else
        # Fallback: text parsing (less reliable, no interface filtering)
        log_warn "Using fallback IP parsing - Docker/Podman filtering may not work"

        local ip_output
        local ip_cmd_args=""
        case "${ip_version}" in
            4) ip_cmd_args="-4" ;;
            6) ip_cmd_args="-6" ;;
            both) ip_cmd_args="" ;;
        esac

        if ip_output=$(ip ${ip_cmd_args} addr show 2>&1); then
            # Parse IPv4
            if [[ "${ip_version}" == "4" || "${ip_version}" == "both" ]]; then
                while IFS= read -r line; do
                    if [[ -n "${line}" ]]; then
                        local ip="${line%%/*}"
                        if ! is_excluded_ip "${ip}" "inet"; then
                            addresses+=("${ip}|A")
                        fi
                    fi
                done < <(echo "${ip_output}" | grep -oP 'inet \K[0-9.]+/[0-9]+' 2>/dev/null || true)
            fi

            # Parse IPv6
            if [[ "${ip_version}" == "6" || "${ip_version}" == "both" ]]; then
                while IFS= read -r line; do
                    if [[ -n "${line}" ]]; then
                        local ip="${line%%/*}"
                        if ! is_excluded_ip "${ip}" "inet6"; then
                            addresses+=("${ip}|AAAA")
                        fi
                    fi
                done < <(echo "${ip_output}" | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+' 2>/dev/null || true)
            fi
        fi
    fi

    log_operation_complete "Found ${#addresses[@]} IP addresses"

    printf '%s\n' "${addresses[@]}"
}

get_mac_address_for_ip() {
    local ip_address="$1"
    local mac=""

    log_debug "Getting MAC address for IP: ${ip_address}"

    # Find the interface for this IP
    local interface
    interface=$(ip addr show | grep -B2 "inet[6]* ${ip_address}" | grep -oP '^\d+: \K[^:@]+' | head -1)

    if [[ -n "${interface}" ]]; then
        mac=$(ip link show "${interface}" | grep -oP 'link/ether \K[0-9a-f:]+' | head -1)
        # Convert to uppercase with dashes
        mac=$(echo "${mac}" | tr ':' '-' | tr '[:lower:]' '[:upper:]')
    fi

    echo "${mac}"
}

# Check if an IPv4 address is in the CGNAT range (100.64.0.0/10)
# Used by Tailscale and Netbird for overlay network IPs
is_cgnat_ip() {
    local ip="$1"

    # Only check IPv4
    [[ "${ip}" == *:* ]] && return 1

    # CGNAT range: 100.64.0.0 - 100.127.255.255 (100.64.0.0/10)
    if [[ "${ip}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
        return 0
    fi

    return 1
}

# Check if an IPv6 address is a Tailscale address (fd7a:115c:a1e0::/48)
is_tailscale_ipv6() {
    local ip="$1"

    # Only check IPv6
    [[ "${ip}" != *:* ]] && return 1

    # Tailscale IPv6 prefix
    if [[ "${ip}" =~ ^fd7a:115c:a1e0: ]]; then
        return 0
    fi

    return 1
}

#endregion IP Address Discovery

#region Technitium API Functions

invoke_technitium_api() {
    local endpoint="$1"
    local params="$2"
    local token="$3"
    local base_url="$4"

    local full_url="${base_url}/${endpoint}?token=${token}&${params}"

    log_debug "API Request: ${endpoint}"
    log_operation_start "Calling Technitium API: ${endpoint}"

    local response
    local http_code
    local curl_output
    local curl_opts="-s -w \n%{http_code} -X GET -A ${USER_AGENT}"

    # Add insecure flag if configured (for self-signed certs)
    if [[ "${INSECURE_SSL}" == "true" ]]; then
        curl_opts="${curl_opts} -k"
    fi

    # Use curl with separate status code capture and User-Agent to avoid crawler blocking
    curl_output=$(curl ${curl_opts} "${full_url}" 2>&1)
    http_code=$(echo "${curl_output}" | tail -n1)
    response=$(echo "${curl_output}" | sed '$d')

    # Check HTTP status code
    if [[ "${http_code}" != "200" ]]; then
        log_operation_error "API call to ${endpoint}" "HTTP ${http_code}: ${response}"
        echo "${response}"
        return 1
    fi

    # Check API status in response
    local api_status
    api_status=$(echo "${response}" | jq -r '.status // "unknown"' 2>/dev/null || echo "parse_error")

    if [[ "${api_status}" != "ok" ]]; then
        local error_msg
        error_msg=$(echo "${response}" | jq -r '.errorMessage // "Unknown error"' 2>/dev/null || echo "Unknown error")
        log_operation_error "API call to ${endpoint}" "API Status: ${api_status}, Error: ${error_msg}"
        echo "${response}"
        return 1
    fi

    log_operation_complete "API call to ${endpoint} succeeded"
    echo "${response}"
    return 0
}

add_dns_record() {
    local base_url="$1"
    local token="$2"
    local zone="$3"
    local hostname="$4"
    local record_type="$5"
    local ip_address="$6"
    local ttl="$7"
    local comment="$8"

    local fqdn="${hostname}.${zone}"

    log_operation_start "Adding DNS record: ${fqdn} (${record_type}) -> ${ip_address}"

    # Build URL-encoded parameters
    local params=""
    params+="zone=$(urlencode "${zone}")"
    params+="&domain=$(urlencode "${fqdn}")"
    params+="&type=$(urlencode "${record_type}")"
    params+="&ttl=$(urlencode "${ttl}")"
    params+="&overwrite=true"
    params+="&comments=$(urlencode "${comment}")"
    params+="&ptr=true"
    params+="&createPtrZone=true"
    params+="&updateSvcbHints=false"

    # Add IP address parameter based on record type
    if [[ "${record_type}" == "A" ]]; then
        params+="&ipAddress=$(urlencode "${ip_address}")"
    elif [[ "${record_type}" == "AAAA" ]]; then
        params+="&ipAddress=$(urlencode "${ip_address}")"
    fi

    local response
    if response=$(invoke_technitium_api "api/zones/records/add" "${params}" "${token}" "${base_url}"); then
        log_operation_complete "DNS record created: ${fqdn} -> ${ip_address}"
        echo "${response}"
        return 0
    else
        log_operation_error "Creating DNS record ${fqdn}" "${response}"
        echo "${response}"
        return 1
    fi
}

remove_dhcp_reservation() {
    local base_url="$1"
    local token="$2"
    local scope_name="$3"
    local mac_address="$4"

    log_debug "Removing existing DHCP reservation for MAC: ${mac_address} from scope: ${scope_name}"

    # Build URL-encoded parameters
    local params=""
    params+="name=$(urlencode "${scope_name}")"
    params+="&hardwareAddress=$(urlencode "${mac_address}")"

    local response
    # We don't treat failure as an error - the reservation may not exist
    if response=$(invoke_technitium_api "api/dhcp/scopes/removeReservedLease" "${params}" "${token}" "${base_url}"); then
        log_debug "Existing DHCP reservation removed for MAC: ${mac_address}"
        return 0
    else
        # If removal fails, it's likely because the reservation doesn't exist - that's OK
        log_debug "No existing DHCP reservation found for MAC: ${mac_address} (or removal failed)"
        return 0
    fi
}

add_dhcp_reservation() {
    local base_url="$1"
    local token="$2"
    local scope_name="$3"
    local mac_address="$4"
    local ip_address="$5"
    local hostname="$6"
    local comment="$7"

    log_operation_start "Adding DHCP reservation: ${hostname} (${mac_address}) -> ${ip_address}"

    # First, remove any existing reservation for this MAC address (for idempotency)
    # This ensures we can update an existing reservation without errors
    remove_dhcp_reservation "${base_url}" "${token}" "${scope_name}" "${mac_address}"

    # Build URL-encoded parameters
    local params=""
    params+="name=$(urlencode "${scope_name}")"
    params+="&hardwareAddress=$(urlencode "${mac_address}")"
    params+="&ipAddress=$(urlencode "${ip_address}")"
    params+="&hostName=$(urlencode "${hostname}")"
    params+="&comments=$(urlencode "${comment}")"

    local response
    if response=$(invoke_technitium_api "api/dhcp/scopes/addReservedLease" "${params}" "${token}" "${base_url}"); then
        log_operation_complete "DHCP reservation created: ${hostname} -> ${ip_address}"
        echo "${response}"
        return 0
    else
        log_operation_error "Creating DHCP reservation ${hostname}" "${response}"
        echo "${response}"
        return 1
    fi
}

#endregion Technitium API Functions

#region DHCP Scope Detection

# Global scope cache to avoid repeated API calls
declare -a SCOPE_CACHE_NAMES=()
declare -A SCOPE_CACHE_START=()
declare -A SCOPE_CACHE_END=()
SCOPE_CACHE_LOADED="false"

# Convert IPv4 address to integer for range comparison
ip_to_int() {
    local ip="$1"
    local a b c d

    IFS='.' read -r a b c d <<< "${ip}"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# List all DHCP scopes
list_dhcp_scopes() {
    local base_url="$1"
    local token="$2"

    log_debug "Listing DHCP scopes"

    local response
    if response=$(invoke_technitium_api "api/dhcp/scopes/list" "" "${token}" "${base_url}"); then
        # Extract scope names from response
        echo "${response}" | jq -r '.response.scopes[].name // empty' 2>/dev/null
        return 0
    else
        log_warn "Failed to list DHCP scopes"
        return 1
    fi
}

# Get DHCP scope details (start/end addresses)
get_dhcp_scope_details() {
    local base_url="$1"
    local token="$2"
    local scope_name="$3"

    log_debug "Getting details for DHCP scope: ${scope_name}"

    local params="name=$(urlencode "${scope_name}")"

    local response
    if response=$(invoke_technitium_api "api/dhcp/scopes/get" "${params}" "${token}" "${base_url}"); then
        local start_addr end_addr
        start_addr=$(echo "${response}" | jq -r '.response.startingAddress // empty' 2>/dev/null)
        end_addr=$(echo "${response}" | jq -r '.response.endingAddress // empty' 2>/dev/null)

        if [[ -n "${start_addr}" && -n "${end_addr}" ]]; then
            echo "${start_addr}|${end_addr}"
            return 0
        else
            log_warn "Scope ${scope_name} has no valid address range"
            return 1
        fi
    else
        log_warn "Failed to get details for scope: ${scope_name}"
        return 1
    fi
}

# Load all scopes into cache (single API call - list returns all needed data)
load_scope_cache() {
    local base_url="$1"
    local token="$2"

    if [[ "${SCOPE_CACHE_LOADED}" == "true" ]]; then
        log_debug "Scope cache already loaded"
        return 0
    fi

    log_operation_start "Loading DHCP scope cache"

    local response
    if ! response=$(invoke_technitium_api "api/dhcp/scopes/list" "" "${token}" "${base_url}"); then
        log_warn "Could not load DHCP scopes - auto-detection will not work"
        SCOPE_CACHE_LOADED="true"
        return 1
    fi

    # Parse all scopes from the single list response (no need for individual get calls)
    local count=0
    while IFS='|' read -r scope_name start_addr end_addr; do
        if [[ -z "${scope_name}" ]]; then
            continue
        fi

        SCOPE_CACHE_NAMES+=("${scope_name}")
        SCOPE_CACHE_START["${scope_name}"]="${start_addr}"
        SCOPE_CACHE_END["${scope_name}"]="${end_addr}"

        log_debug "Cached scope: ${scope_name} (${start_addr} - ${end_addr})"
        ((count++)) || true
    done < <(echo "${response}" | jq -r '.response.scopes[] | "\(.name)|\(.startingAddress)|\(.endingAddress)"' 2>/dev/null)

    SCOPE_CACHE_LOADED="true"
    log_operation_complete "Loaded ${count} DHCP scopes into cache"
    return 0
}

# Find the scope that contains the given IP address
# Sets FOUND_SCOPE variable with the result (avoids subshell issues with caching)
find_scope_for_ip() {
    local ip_address="$1"

    # Clear previous result
    FOUND_SCOPE=""

    local ip_int
    ip_int=$(ip_to_int "${ip_address}")

    log_debug "Finding scope for IP: ${ip_address} (int: ${ip_int})"

    for scope_name in "${SCOPE_CACHE_NAMES[@]}"; do
        local start_addr="${SCOPE_CACHE_START[${scope_name}]}"
        local end_addr="${SCOPE_CACHE_END[${scope_name}]}"

        local start_int end_int
        start_int=$(ip_to_int "${start_addr}")
        end_int=$(ip_to_int "${end_addr}")

        if (( ip_int >= start_int && ip_int <= end_int )); then
            log_debug "IP ${ip_address} matches scope: ${scope_name} (${start_addr} - ${end_addr})"
            FOUND_SCOPE="${scope_name}"
            return 0
        fi
    done

    log_debug "No scope found for IP: ${ip_address}"
    return 1
}

# Global variable for scope detection result
FOUND_SCOPE=""

#endregion DHCP Scope Detection

#region Zone Detection

# Check if a zone exists in Technitium
zone_exists() {
    local base_url="$1"
    local token="$2"
    local zone_name="$3"

    log_debug "Checking if zone exists: ${zone_name}"

    local response
    if response=$(invoke_technitium_api "api/zones/list" "" "${token}" "${base_url}" 2>/dev/null); then
        # Check if zone name is in the list
        if echo "${response}" | jq -e --arg zone "${zone_name}" '.response.zones[] | select(.name == $zone)' >/dev/null 2>&1; then
            log_debug "Zone exists: ${zone_name}"
            return 0
        fi
    fi

    log_debug "Zone does not exist: ${zone_name}"
    return 1
}

# Create a new primary zone in Technitium
create_zone() {
    local base_url="$1"
    local token="$2"
    local zone_name="$3"

    log_operation_start "Creating zone: ${zone_name}"

    local params="zone=$(urlencode "${zone_name}")&type=Primary"

    local response
    if response=$(invoke_technitium_api "api/zones/create" "${params}" "${token}" "${base_url}" 2>/dev/null); then
        log_operation_complete "Zone created: ${zone_name}"
        return 0
    else
        log_error "Failed to create zone: ${zone_name}"
        return 1
    fi
}

# Ensure a zone exists, creating it if necessary (only for explicit zones, not auto-detected)
# Sets global ZONE_WAS_CREATED to "true" if zone was created, "false" otherwise
ensure_zone_exists() {
    local base_url="$1"
    local token="$2"
    local zone_name="$3"
    local auto_create="$4"  # "true" or "false"

    ZONE_WAS_CREATED="false"

    if zone_exists "${base_url}" "${token}" "${zone_name}"; then
        return 0
    fi

    if [[ "${auto_create}" == "true" ]]; then
        log_info "Zone does not exist: ${zone_name} - creating it"
        if create_zone "${base_url}" "${token}" "${zone_name}"; then
            ZONE_WAS_CREATED="true"
            return 0
        else
            return 1
        fi
    else
        log_warn "Zone does not exist: ${zone_name} - skipping (use --auto-create-zones to create missing zones)"
        return 1
    fi
}

#endregion Zone Detection

#region VPN Detection (Tailscale/Netbird)

# Detect if Tailscale is installed and get its info
# Sets global variables: TAILSCALE_SUFFIX, TAILSCALE_IPS, TAILSCALE_HOSTNAME
get_tailscale_info() {
    TAILSCALE_SUFFIX=""
    TAILSCALE_IPS=()
    TAILSCALE_HOSTNAME=""

    if ! command -v tailscale &>/dev/null; then
        log_debug "Tailscale not installed"
        return 1
    fi

    log_operation_start "Detecting Tailscale configuration"

    local status_json
    if ! status_json=$(tailscale status --json 2>/dev/null); then
        log_warn "Failed to get Tailscale status"
        return 1
    fi

    # Extract MagicDNSSuffix
    TAILSCALE_SUFFIX=$(echo "${status_json}" | jq -r '.MagicDNSSuffix // .CurrentTailnet.MagicDNSSuffix // empty' 2>/dev/null)

    # Extract TailscaleIPs array
    local ips_json
    ips_json=$(echo "${status_json}" | jq -r '.TailscaleIPs[]? // empty' 2>/dev/null)
    while IFS= read -r ip; do
        [[ -n "${ip}" ]] && TAILSCALE_IPS+=("${ip}")
    done <<< "${ips_json}"

    # Extract hostname
    TAILSCALE_HOSTNAME=$(echo "${status_json}" | jq -r '.Self.HostName // empty' 2>/dev/null)

    if [[ -n "${TAILSCALE_SUFFIX}" && ${#TAILSCALE_IPS[@]} -gt 0 ]]; then
        log_operation_complete "Tailscale detected: suffix=${TAILSCALE_SUFFIX}, IPs=${TAILSCALE_IPS[*]}, hostname=${TAILSCALE_HOSTNAME}"
        return 0
    else
        log_debug "Tailscale installed but no valid configuration found"
        return 1
    fi
}

# Detect if Netbird is installed and get its info
# Sets global variables: NETBIRD_SUFFIX, NETBIRD_IPS, NETBIRD_HOSTNAME
get_netbird_info() {
    NETBIRD_SUFFIX=""
    NETBIRD_IPS=()
    NETBIRD_HOSTNAME=""

    if ! command -v netbird &>/dev/null; then
        log_debug "Netbird not installed"
        return 1
    fi

    log_operation_start "Detecting Netbird configuration"

    local status_json
    if ! status_json=$(netbird status --json 2>/dev/null); then
        log_warn "Failed to get Netbird status"
        return 1
    fi

    # Extract DNS suffix from fqdn (hostname.suffix format) or dnsSuffix field
    NETBIRD_SUFFIX=$(echo "${status_json}" | jq -r '.dnsSuffix // empty' 2>/dev/null)

    # If no dnsSuffix, try to extract from fqdn
    if [[ -z "${NETBIRD_SUFFIX}" ]]; then
        local fqdn
        fqdn=$(echo "${status_json}" | jq -r '.fqdn // empty' 2>/dev/null)
        if [[ -n "${fqdn}" && "${fqdn}" == *.* ]]; then
            NETBIRD_SUFFIX="${fqdn#*.}"
        fi
    fi

    # Extract IPs
    local ips_json
    ips_json=$(echo "${status_json}" | jq -r '.ips[]? // .ip // empty' 2>/dev/null)
    while IFS= read -r ip; do
        [[ -n "${ip}" ]] && NETBIRD_IPS+=("${ip}")
    done <<< "${ips_json}"

    # Extract hostname
    NETBIRD_HOSTNAME=$(echo "${status_json}" | jq -r '.hostname // empty' 2>/dev/null)

    if [[ -n "${NETBIRD_SUFFIX}" && ${#NETBIRD_IPS[@]} -gt 0 ]]; then
        log_operation_complete "Netbird detected: suffix=${NETBIRD_SUFFIX}, IPs=${NETBIRD_IPS[*]}, hostname=${NETBIRD_HOSTNAME}"
        return 0
    else
        log_debug "Netbird installed but no valid configuration found"
        return 1
    fi
}

#endregion VPN Detection (Tailscale/Netbird)

#region Connection DNS Suffix Detection

# Get DNS search domains from system configuration
# Sets global variable: DNS_SEARCH_DOMAINS
get_dns_search_domains() {
    DNS_SEARCH_DOMAINS=()

    log_operation_start "Detecting DNS search domains"

    # Try resolvectl first (systemd-resolved)
    if command -v resolvectl &>/dev/null; then
        local domains
        domains=$(resolvectl status 2>/dev/null | grep -i "DNS Domain" | sed 's/.*: //' | tr ' ' '\n' | grep -v '^$' | sort -u)
        while IFS= read -r domain; do
            [[ -n "${domain}" && "${domain}" != "~." ]] && DNS_SEARCH_DOMAINS+=("${domain}")
        done <<< "${domains}"
    fi

    # Fall back to /etc/resolv.conf
    if [[ ${#DNS_SEARCH_DOMAINS[@]} -eq 0 && -f /etc/resolv.conf ]]; then
        local domains
        domains=$(grep -E '^(search|domain)' /etc/resolv.conf 2>/dev/null | sed 's/^[^ ]* //' | tr ' ' '\n' | grep -v '^$' | sort -u)
        while IFS= read -r domain; do
            [[ -n "${domain}" ]] && DNS_SEARCH_DOMAINS+=("${domain}")
        done <<< "${domains}"
    fi

    if [[ ${#DNS_SEARCH_DOMAINS[@]} -gt 0 ]]; then
        log_operation_complete "Found DNS search domains: ${DNS_SEARCH_DOMAINS[*]}"
        return 0
    else
        log_debug "No DNS search domains found"
        return 1
    fi
}

#endregion Connection DNS Suffix Detection

#region Usage and Argument Parsing

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Registers local IP addresses as DNS records and DHCP reservations in Technitium.

ZONE AUTO-DETECTION:
    If --zone is "auto" (default), zones are auto-detected from:
    - Connection DNS search domains (from /etc/resolv.conf or resolvectl)
    - Tailscale MagicDNS suffix (if Tailscale is installed)
    - Netbird DNS suffix (if Netbird is installed)
    Only zones that exist in Technitium will have records created.

DHCP SCOPE AUTO-DETECTION:
    If --scope is not provided, the script will automatically query all DHCP scopes
    from Technitium and determine which scope contains each IP address based on the
    scope's address range (startingAddress to endingAddress). If no matching scope
    is found, the DHCP reservation is skipped with a warning.

OPTIONS:
    -t, --token TOKEN       API token for Technitium (default: from config)
    -u, --url URL           Base URL for Technitium API (default: ${DEFAULT_BASE_URL})
    -z, --zone ZONE         DNS zone(s) - "auto" for auto-detection, or comma-separated
                            list of zones (default: auto)
    -H, --hostname NAME     Hostname to register (default: system hostname)
    -i, --ip-version VER    IP version to process: 4, 6, or both (default: 4)
    -s, --scope SCOPE       DHCP scope name (optional - auto-detected if not specified)
    --ttl TTL               TTL for DNS records (default: ${DEFAULT_TTL})
    --skip-dns              Skip DNS record creation
    --skip-dhcp             Skip DHCP reservation creation
    --auto-create-zones     Create zones if they don't exist (default: skip missing zones)
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

EXAMPLES:
    ${SCRIPT_NAME}                                    # Auto-detect zones
    ${SCRIPT_NAME} --zone auto                        # Explicit auto-detection
    ${SCRIPT_NAME} --zone example.com                 # Single zone
    ${SCRIPT_NAME} --zone "example.com,internal.lan"  # Multiple zones
    ${SCRIPT_NAME} --hostname "my-server" --scope "LAN"

EOF
}

parse_arguments() {
    # Defaults - use CLOUDINITHOSTNAME from bootstrap if available
    API_TOKEN="${DEFAULT_TOKEN}"
    BASE_URL="${DEFAULT_BASE_URL}"
    ZONE="auto"
    HOSTNAME="${CLOUDINITHOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
    IP_VERSION="4"
    DHCP_SCOPE=""
    TTL="${DEFAULT_TTL}"
    SKIP_DNS="true"
    SKIP_DHCP="false"
    AUTO_CREATE_ZONES="false"
    VERBOSE="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--token)
                API_TOKEN="$2"
                shift 2
                ;;
            -u|--url)
                BASE_URL="$2"
                shift 2
                ;;
            -z|--zone)
                ZONE="$2"
                shift 2
                ;;
            -H|--hostname)
                HOSTNAME="$2"
                shift 2
                ;;
            -i|--ip-version)
                IP_VERSION="$2"
                shift 2
                ;;
            -s|--scope)
                DHCP_SCOPE="$2"
                shift 2
                ;;
            --ttl)
                TTL="$2"
                shift 2
                ;;
            --skip-dns)
                SKIP_DNS="true"
                shift
                ;;
            --skip-dhcp)
                SKIP_DHCP="true"
                shift
                ;;
            --auto-create-zones)
                AUTO_CREATE_ZONES="true"
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate IP version
    if [[ ! "${IP_VERSION}" =~ ^(4|6|both)$ ]]; then
        log_error "Invalid IP version: ${IP_VERSION}. Must be 4, 6, or both."
        exit 1
    fi
}

#endregion Usage and Argument Parsing

#region Main Function

main() {
    local exit_code=0

    log_info "=========================================="
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Log file: ${LOG_FILE}"
    log_info "=========================================="

    # Install required packages first
    if ! install_required_packages; then
        log_error "Failed to install required packages. Exiting."
        return 1
    fi

    # Get local IP addresses
    local ip_addresses
    mapfile -t ip_addresses < <(get_local_ip_addresses "${IP_VERSION}")

    if [[ ${#ip_addresses[@]} -eq 0 ]]; then
        log_warn "No IP addresses found for version: ${IP_VERSION}"
        return 0
    fi

    # Separate physical IPs from VPN IPs
    local physical_ips=()
    local vpn_ips=()
    for entry in "${ip_addresses[@]}"; do
        local ip_address="${entry%%|*}"
        if is_cgnat_ip "${ip_address}" || is_tailscale_ipv6 "${ip_address}"; then
            vpn_ips+=("${entry}")
        else
            physical_ips+=("${entry}")
        fi
    done

    # Log discovered IPs
    log_info "Found ${#physical_ips[@]} physical IPs and ${#vpn_ips[@]} VPN IPs"
    if [[ ${#physical_ips[@]} -gt 0 ]]; then
        for entry in "${physical_ips[@]}"; do
            local ip="${entry%%|*}"
            local type="${entry##*|}"
            log_info "  Physical: ${ip} (${type})"
        done
    fi
    if [[ ${#vpn_ips[@]} -gt 0 ]]; then
        for entry in "${vpn_ips[@]}"; do
            local ip="${entry%%|*}"
            local type="${entry##*|}"
            log_info "  VPN: ${ip} (${type})"
        done
    fi

    # Detect VPN configurations early (needed for zone building)
    get_tailscale_info || true
    get_netbird_info || true

    # Build list of zones to process
    local zones_to_process=()
    if [[ "${ZONE}" == "auto" ]]; then
        log_info "Auto-detecting zones from connection DNS suffixes"
        get_dns_search_domains || true
        for domain in "${DNS_SEARCH_DOMAINS[@]}"; do
            # Skip VPN zones - they're handled separately with VPN-specific IPs
            [[ -n "${TAILSCALE_SUFFIX:-}" && "${domain}" == "${TAILSCALE_SUFFIX}" ]] && continue
            [[ -n "${NETBIRD_SUFFIX:-}" && "${domain}" == "${NETBIRD_SUFFIX}" ]] && continue
            zones_to_process+=("${domain}")
        done
    else
        # Parse comma-separated zone list
        IFS=',' read -ra zones_to_process <<< "${ZONE}"
    fi

    if [[ ${#zones_to_process[@]} -eq 0 && -z "${TAILSCALE_SUFFIX:-}" && -z "${NETBIRD_SUFFIX:-}" ]]; then
        log_warn "No zones to process. Use --zone to specify zones or ensure DNS search domains are configured."
        return 0
    fi

    log_info "Zones to process: ${zones_to_process[*]:-none}"
    [[ -n "${TAILSCALE_SUFFIX:-}" ]] && log_info "Tailscale zone: ${TAILSCALE_SUFFIX}"
    [[ -n "${NETBIRD_SUFFIX:-}" ]] && log_info "Netbird zone: ${NETBIRD_SUFFIX}"

    local dns_success=0
    local dns_failed=0
    local dhcp_success=0
    local dhcp_failed=0
    local dhcp_auto_detected=0
    local dhcp_no_scope=0
    local vpn_dns_success=0
    local vpn_dns_failed=0
    local zones_processed=0
    local zones_skipped=0

    log_info "Processing ${#physical_ips[@]} physical IP addresses for hostname: ${HOSTNAME}"

    # Preload DHCP scope cache if auto-detection might be needed
    if [[ "${SKIP_DHCP}" != "true" && -z "${DHCP_SCOPE}" ]]; then
        load_scope_cache "${BASE_URL}" "${API_TOKEN}"
    fi

    # Track zones created
    local zones_created=0

    # Process each zone with physical IPs
    for zone in "${zones_to_process[@]}"; do
        # Check if zone exists, create if needed (only if --auto-create-zones is set)
        if ! ensure_zone_exists "${BASE_URL}" "${API_TOKEN}" "${zone}" "${AUTO_CREATE_ZONES}"; then
            ((zones_skipped++)) || true
            continue
        fi

        # Check if zone was just created (for summary)
        if [[ "${ZONE_WAS_CREATED}" == "true" ]]; then
            ((zones_created++)) || true
        fi

        log_info "Processing zone: ${zone}"
        ((zones_processed++)) || true

        for entry in "${physical_ips[@]}"; do
            local ip_address="${entry%%|*}"
            local record_type="${entry##*|}"

            log_info "Processing IP: ${ip_address} (${record_type}) for zone: ${zone}"

            # Create DNS record
            if [[ "${SKIP_DNS}" != "true" ]]; then
                local comment="Automatically created via ${SCRIPT_NAME} on $(date -u '+%Y-%m-%d %H:%M:%S UTC') from ${HOSTNAME^^}"

                if add_dns_record "${BASE_URL}" "${API_TOKEN}" "${zone}" "${HOSTNAME}" "${record_type}" "${ip_address}" "${TTL}" "${comment}" >/dev/null; then
                    ((dns_success++)) || true
                    log_info "DNS record created/updated: ${HOSTNAME}.${zone} -> ${ip_address}"
                else
                    ((dns_failed++)) || true
                    exit_code=1
                fi
            fi

            # Create DHCP reservation (only for IPv4, only for first zone to avoid duplicates)
            if [[ "${SKIP_DHCP}" != "true" && "${record_type}" == "A" && "${zones_processed}" -eq 1 ]]; then
                local scope_to_use="${DHCP_SCOPE}"

                if [[ -z "${scope_to_use}" ]]; then
                    if find_scope_for_ip "${ip_address}"; then
                        scope_to_use="${FOUND_SCOPE}"
                        log_info "Auto-detected DHCP scope: ${scope_to_use} for IP: ${ip_address}"
                        ((dhcp_auto_detected++)) || true
                    else
                        log_warn "No DHCP scope found for IP: ${ip_address} - skipping DHCP reservation"
                        ((dhcp_no_scope++)) || true
                        continue
                    fi
                fi

                local mac_address
                mac_address=$(get_mac_address_for_ip "${ip_address}")

                if [[ -n "${mac_address}" ]]; then
                    local dhcp_comment="Automatically created via ${SCRIPT_NAME} on $(date -u '+%Y-%m-%d %H:%M:%S UTC') from ${HOSTNAME^^}"

                    if add_dhcp_reservation "${BASE_URL}" "${API_TOKEN}" "${scope_to_use}" "${mac_address}" "${ip_address}" "${HOSTNAME}" "${dhcp_comment}" >/dev/null; then
                        ((dhcp_success++)) || true
                    else
                        ((dhcp_failed++)) || true
                        exit_code=1
                    fi
                else
                    log_warn "Could not determine MAC address for IP: ${ip_address}"
                fi
            fi
        done
    done

    # Process Tailscale zone with Tailscale IPs
    if [[ "${SKIP_DNS}" != "true" && -n "${TAILSCALE_SUFFIX:-}" ]]; then
        if zone_exists "${BASE_URL}" "${API_TOKEN}" "${TAILSCALE_SUFFIX}"; then
            log_info "Processing Tailscale zone: ${TAILSCALE_SUFFIX}"
            local ts_hostname="${TAILSCALE_HOSTNAME:-${HOSTNAME}}"
            local comment="Automatically created via ${SCRIPT_NAME} on $(date -u '+%Y-%m-%d %H:%M:%S UTC') from ${HOSTNAME^^}"

            for ts_ip in "${TAILSCALE_IPS[@]}"; do
                local record_type="A"
                [[ "${ts_ip}" == *:* ]] && record_type="AAAA"

                if add_dns_record "${BASE_URL}" "${API_TOKEN}" "${TAILSCALE_SUFFIX}" "${ts_hostname}" "${record_type}" "${ts_ip}" "${TTL}" "${comment}" >/dev/null; then
                    ((vpn_dns_success++)) || true
                    log_info "Tailscale DNS record created: ${ts_hostname}.${TAILSCALE_SUFFIX} -> ${ts_ip}"
                else
                    ((vpn_dns_failed++)) || true
                fi
            done
        else
            log_info "Tailscale zone not found in Technitium: ${TAILSCALE_SUFFIX} - skipping"
        fi
    fi

    # Process Netbird zone with Netbird IPs
    if [[ "${SKIP_DNS}" != "true" && -n "${NETBIRD_SUFFIX:-}" ]]; then
        if zone_exists "${BASE_URL}" "${API_TOKEN}" "${NETBIRD_SUFFIX}"; then
            log_info "Processing Netbird zone: ${NETBIRD_SUFFIX}"
            local nb_hostname="${NETBIRD_HOSTNAME:-${HOSTNAME}}"
            local comment="Automatically created via ${SCRIPT_NAME} on $(date -u '+%Y-%m-%d %H:%M:%S UTC') from ${HOSTNAME^^}"

            for nb_ip in "${NETBIRD_IPS[@]}"; do
                local record_type="A"
                [[ "${nb_ip}" == *:* ]] && record_type="AAAA"

                if add_dns_record "${BASE_URL}" "${API_TOKEN}" "${NETBIRD_SUFFIX}" "${nb_hostname}" "${record_type}" "${nb_ip}" "${TTL}" "${comment}" >/dev/null; then
                    ((vpn_dns_success++)) || true
                    log_info "Netbird DNS record created/updated: ${nb_hostname}.${NETBIRD_SUFFIX} -> ${nb_ip}"
                else
                    ((vpn_dns_failed++)) || true
                fi
            done
        else
            log_info "Netbird zone not found in Technitium: ${NETBIRD_SUFFIX} - skipping"
        fi
    fi

    # Summary
    log_info "=========================================="
    log_info "Summary:"
    if [[ ${zones_created} -gt 0 ]]; then
        log_info "  Zones processed: ${zones_processed}, created: ${zones_created}, skipped: ${zones_skipped}"
    else
        log_info "  Zones processed: ${zones_processed}, skipped: ${zones_skipped}"
    fi
    log_info "  Physical IPs: ${#physical_ips[@]}, VPN IPs: ${#vpn_ips[@]}"
    if [[ "${SKIP_DNS}" != "true" ]]; then
        log_info "  DNS records created/updated: ${dns_success}"
        log_info "  DNS records failed: ${dns_failed}"
    fi
    if [[ "${SKIP_DHCP}" != "true" ]]; then
        log_info "  DHCP reservations created: ${dhcp_success}"
        log_info "  DHCP reservations failed: ${dhcp_failed}"
        if [[ ${dhcp_auto_detected} -gt 0 ]]; then
            log_info "    DHCP scopes auto-detected: ${dhcp_auto_detected}"
        fi
        if [[ ${dhcp_no_scope} -gt 0 ]]; then
            log_info "    DHCP skipped (no matching scope): ${dhcp_no_scope}"
        fi
    fi
    if [[ ${vpn_dns_success} -gt 0 || ${vpn_dns_failed} -gt 0 ]]; then
        log_info "  VPN zones (Tailscale/Netbird):"
        log_info "    DNS records created/updated: ${vpn_dns_success}"
        log_info "    DNS records failed: ${vpn_dns_failed}"
    fi
    log_info "=========================================="
    log_info "${SCRIPT_NAME} completed"

    return ${exit_code}
}

#endregion Main Function

#region Script Entry Point

# Parse command line arguments (no args when run from bootstrap)
parse_arguments "$@"

# Run main function
main
exit_code=$?

Write-Log "INFO" "=== Technitium DNS/DHCP Record Creation Complete ==="

exit ${exit_code}

#endregion Script Entry Point
