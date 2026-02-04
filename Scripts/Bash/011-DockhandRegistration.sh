#!/bin/bash
#===============================================================================
# 009-DockhandRegistration.sh
# Dockhand Hawser agent installation and API registration
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

#Check if Docker is installed
if ! Test-DockerInstalled; then
    Write-Log "SKIP" "$SCRIPT_NAME - Docker is not installed"
    exit 1003
fi

#Check if Docker Compose is installed
if ! Test-DockerComposeInstalled; then
    Write-Log "SKIP" "$SCRIPT_NAME - Docker Compose is not installed"
    exit 1004
fi

Write-Log "INFO" "=== Dockhand Registration ==="

#-------------------------------------------------------------------------------
# Dockhand Configuration
#-------------------------------------------------------------------------------
DOCKHAND_SCHEME="http"
DOCKHAND_URL="DOCKER-MANAGER-001"
DOCKHAND_PORT="3000"
DOCKHAND_TOKEN=""
HAWSER_TOKEN_FILE="/opt/docker/dockerhand-hawser-agent-token.txt"
HAWSER_AGENT_PORT="2376"

DOCKHAND_API_URL="${DOCKHAND_SCHEME}://${DOCKHAND_URL}:${DOCKHAND_PORT}/api"

#-------------------------------------------------------------------------------
# Check if environment already exists in Dockhand
#-------------------------------------------------------------------------------
Write-Log "INFO" "[CHECK] Existing environment"
ENVIRONMENTS_RESPONSE=$(curl -sS -w "\n%{http_code}" -X GET "${DOCKHAND_API_URL}/environments" 2>/dev/null)
ENVIRONMENTS_HTTP_CODE=$(echo "$ENVIRONMENTS_RESPONSE" | tail -n1)
ENVIRONMENTS_JSON=$(echo "$ENVIRONMENTS_RESPONSE" | sed '$d')

EXISTING_ENV=$(echo "$ENVIRONMENTS_JSON" | jq -r \
    --arg name "$CLOUDINITHOSTNAME" \
    --arg host "$SERVER_FQDN" \
    --arg publicIp "$SERVER_FQDN" \
    '.[] | select(.name == $name or .host == $host or .publicIp == $publicIp)' 2>/dev/null)

ENV_ID=$(echo "$EXISTING_ENV" | jq -r '.id' 2>/dev/null)
ENVIRONMENT_EXISTS="false"

if [[ -n "$ENV_ID" && "$ENV_ID" != "null" ]]; then
    ENVIRONMENT_EXISTS="true"
    Write-Log "INFO" "[EXISTS] Environment already registered (ID: $ENV_ID)"

    #Extract existing hawser token from environment
    EXISTING_HAWSER_TOKEN=$(echo "$EXISTING_ENV" | jq -r '.hawserToken' 2>/dev/null)

    if [[ -n "$EXISTING_HAWSER_TOKEN" && "$EXISTING_HAWSER_TOKEN" != "null" ]]; then
        HAWSER_TOKEN="$EXISTING_HAWSER_TOKEN"
        Write-Log "INFO" "[TOKEN] Using existing token from environment"

        #Save token to file if not already there
        if [[ ! -f "$HAWSER_TOKEN_FILE" ]]; then
            echo "$HAWSER_TOKEN" > "$HAWSER_TOKEN_FILE"
            Write-Log "INFO" "[TOKEN] Saved to $HAWSER_TOKEN_FILE"
        fi
    fi
else
    Write-Log "INFO" "[NEW] Environment does not exist"
fi

#-------------------------------------------------------------------------------
# Get or generate hawser token
#-------------------------------------------------------------------------------
if [[ -z "$HAWSER_TOKEN" ]]; then
    if [[ -f "$HAWSER_TOKEN_FILE" ]]; then
        HAWSER_TOKEN=$(cat "$HAWSER_TOKEN_FILE")
        Write-Log "INFO" "[TOKEN] Using existing token from file"
    else
        HAWSER_TOKEN=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-43)
        echo "$HAWSER_TOKEN" > "$HAWSER_TOKEN_FILE"
        Write-Log "INFO" "[TOKEN] Generated new token"
    fi
fi

#-------------------------------------------------------------------------------
# Install Hawser agent (regardless of environment status)
#-------------------------------------------------------------------------------
if docker ps -a --format '{{.Image}}' | grep -q "ghcr.io/finsys/hawser"; then
    Write-Log "SKIP" "Dockhand Hawser agent container already exists"
else
    Write-Log "INFO" "[INSTALL] Dockhand Hawser agent"
    docker run -d \
        --name "DOCKHAND-HAWSER-AGENT" \
        --restart unless-stopped \
        --network host \
        -v /var/run/docker.sock:/var/run/docker.sock:rw \
        -v /custom/docker/stacks/stk-dockhand-hawser-agent/Application/Data:/data/stacks:rw \
        -e AGENT_NAME="${CLOUDINITHOSTNAME}" \
        -e PORT="${HAWSER_AGENT_PORT}" \
        -e TOKEN="${HAWSER_TOKEN}" \
        --health-cmd="wget -q --spider http://localhost:${HAWSER_AGENT_PORT}/_hawser/health || exit 1" \
        ghcr.io/finsys/hawser:latest >/dev/null 2>&1
    Write-Log "INFO" "[OK] Hawser agent installed"
fi

#-------------------------------------------------------------------------------
# Create environment if it doesn't exist
#-------------------------------------------------------------------------------
if [[ "$ENVIRONMENT_EXISTS" == "false" ]]; then
    CREATE_BODY=$(cat <<EOF
{
    "name": "${CLOUDINITHOSTNAME}",
    "host": "${SERVER_FQDN}",
    "port": ${HAWSER_AGENT_PORT},
    "protocol": "http",
    "tlsSkipVerify": false,
    "icon": "globe",
    "collectActivity": true,
    "collectMetrics": true,
    "highlightChanges": true,
    "labels": ["dockhand-agent-standard", "headquarters"],
    "connectionType": "hawser-standard",
    "hawserToken": "${HAWSER_TOKEN}",
    "publicIp": "${SERVER_FQDN}"
}
EOF
)

    Write-Log "INFO" "[REQUEST] POST ${DOCKHAND_API_URL}/environments"
    Write-Log "INFO" "[BODY] $CREATE_BODY"

    CREATE_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${DOCKHAND_API_URL}/environments" \
        -H "Content-Type: application/json" \
        -d "$CREATE_BODY" 2>/dev/null)
    CREATE_HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n1)
    CREATE_JSON=$(echo "$CREATE_RESPONSE" | sed '$d')

    ENV_ID=$(echo "$CREATE_JSON" | jq -r '.id' 2>/dev/null)
    Write-Log "INFO" "[OK] Environment created: $ENV_ID (HTTP $CREATE_HTTP_CODE)"
fi

#Set timezone
Write-Log "INFO" "[CONFIG] Timezone: ${SYSTEM_TIMEZONE}"
curl -sS -X PUT "${DOCKHAND_API_URL}/environments/${ENV_ID}/timezone" \
    -H "Content-Type: application/json" \
    -d "{\"timezone\": \"${SYSTEM_TIMEZONE}\"}" >/dev/null 2>&1

#Configure update check (random Saturday 6pm-10pm)
RANDOM_HOUR=$((RANDOM % 5 + 18))
RANDOM_MINUTE=$((RANDOM % 60))
UPDATE_CRON="${RANDOM_MINUTE} ${RANDOM_HOUR} * * 6"

Write-Log "INFO" "[CONFIG] Update schedule: ${UPDATE_CRON}"
curl -sS -X POST "${DOCKHAND_API_URL}/environments/${ENV_ID}/update-check" \
    -H "Content-Type: application/json" \
    -d "{\"enabled\": true, \"cron\": \"${UPDATE_CRON}\", \"autoUpdate\": false, \"vulnerabilityCriteria\": \"never\"}" >/dev/null 2>&1

#Configure scanner
Write-Log "INFO" "[CONFIG] Scanner"
curl -sS -X POST "${DOCKHAND_API_URL}/settings/scanner" \
    -H "Content-Type: application/json" \
    -d "{\"scanner\": \"both\", \"envId\": ${ENV_ID}}" >/dev/null 2>&1

Write-Log "INFO" "=== Dockhand Registration Complete ==="

