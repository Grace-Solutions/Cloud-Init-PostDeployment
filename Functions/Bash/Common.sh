#!/bin/bash
#===============================================================================
# Common.sh
# Shared functions for post-deployment scripts
#===============================================================================

#-------------------------------------------------------------------------------
# Function File Configuration
# ENABLED: "true" to load, "false" to skip
#-------------------------------------------------------------------------------
ENABLED="true"

#-------------------------------------------------------------------------------
# Install-Package: Idempotently install an apt package
# Usage: Install-Package "package-name"
#-------------------------------------------------------------------------------
Install-Package() {
    local PackageName="$1"
    
    if dpkg -l "$PackageName" 2>/dev/null | grep -q "^ii"; then
        echo "[SKIP] $PackageName (already installed)"
        return 0
    fi
    
    echo "[INSTALL] $PackageName"
    if apt-get install -y -qq "$PackageName" >/dev/null 2>&1; then
        echo "[OK] $PackageName"
        return 0
    else
        echo "[FAIL] $PackageName"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Remove-Package: Idempotently remove an apt package
# Usage: Remove-Package "package-name"
#-------------------------------------------------------------------------------
Remove-Package() {
    local PackageName="$1"
    
    if ! dpkg -l "$PackageName" 2>/dev/null | grep -q "^ii"; then
        echo "[SKIP] $PackageName (not installed)"
        return 0
    fi
    
    echo "[REMOVE] $PackageName"
    if apt-get remove -y -qq "$PackageName" >/dev/null 2>&1; then
        echo "[OK] $PackageName removed"
        return 0
    else
        echo "[FAIL] $PackageName removal failed"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Install-SnapPackage: Idempotently install a snap package
# Usage: Install-SnapPackage "package-name" ["--classic"]
#-------------------------------------------------------------------------------
Install-SnapPackage() {
    local PackageName="$1"
    local Flags="${2:-}"
    
    if snap list "$PackageName" >/dev/null 2>&1; then
        echo "[SKIP] $PackageName (already installed)"
        return 0
    fi
    
    echo "[INSTALL] $PackageName (snap)"
    if snap install "$PackageName" $Flags >/dev/null 2>&1; then
        echo "[OK] $PackageName"
        return 0
    else
        echo "[FAIL] $PackageName"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Create-Directory: Idempotently create a directory
# Usage: Create-Directory "/path/to/directory"
#-------------------------------------------------------------------------------
Create-Directory() {
    local DirectoryPath="$1"
    
    if [[ -d "$DirectoryPath" ]]; then
        echo "[SKIP] $DirectoryPath (exists)"
        return 0
    fi
    
    echo "[CREATE] $DirectoryPath"
    if mkdir -p "$DirectoryPath"; then
        echo "[OK] $DirectoryPath"
        return 0
    else
        echo "[FAIL] $DirectoryPath"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Test-HostnameMatch: Check if hostname matches exclusion pattern
# Returns 0 (true) if hostname DOES NOT match (should run)
# Returns 1 (false) if hostname matches (should skip)
# Usage: if Test-HostnameMatch "$ExclusionPattern"; then ... fi
#-------------------------------------------------------------------------------
Test-HostnameMatch() {
    local ExclusionPattern="$1"
    local Hostname="${CLOUDINITHOSTNAME:-$(hostname)}"
    
    if [[ "$Hostname" =~ $ExclusionPattern ]]; then
        return 1  # Matches exclusion - skip
    fi
    return 0  # Does not match exclusion - run
}

#-------------------------------------------------------------------------------
# Add-FirewallRule: Add UFW allow or deny rule idempotently
# Usage: Add-FirewallRule "allow" "22"
#        Add-FirewallRule "deny" "8443"
#-------------------------------------------------------------------------------
Add-FirewallRule() {
    local Action="$1"
    local Rule="$2"
    
    echo "[UFW] $Action $Rule"
    ufw "$Action" "$Rule" >/dev/null 2>&1 || true
}

#-------------------------------------------------------------------------------
# Add-CronJob: Add a cron job idempotently (checks if command already exists)
# Usage: Add-CronJob "0 21 * * 6" "command to run"
#-------------------------------------------------------------------------------
Add-CronJob() {
    local Schedule="$1"
    local Command="$2"
    local FullJob="$Schedule $Command"

    # Remove existing job with same command, then add new one
    (crontab -l 2>/dev/null | grep -Fv "$Command"; echo "$FullJob") | crontab - 2>/dev/null
    echo "[CRON] Added: $Schedule"
}

#-------------------------------------------------------------------------------
# Test-DockerInstalled: Check if Docker is installed
# Returns 0 (true) if installed, 1 (false) if not
# Usage: if Test-DockerInstalled; then ... fi
#-------------------------------------------------------------------------------
Test-DockerInstalled() {
    command -v docker >/dev/null 2>&1
}

#-------------------------------------------------------------------------------
# Test-DockerComposeInstalled: Check if Docker Compose is installed
# Returns 0 (true) if installed, 1 (false) if not
# Usage: if Test-DockerComposeInstalled; then ... fi
#-------------------------------------------------------------------------------
Test-DockerComposeInstalled() {
    # Check for docker compose plugin (v2)
    if docker compose version >/dev/null 2>&1; then
        return 0
    fi
    # Check for standalone docker-compose (v1)
    if command -v docker-compose >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

#-------------------------------------------------------------------------------
# Get-DockerStatus: Get Docker daemon status
# Returns: "running", "stopped", "not-installed"
# Usage: STATUS=$(Get-DockerStatus)
#-------------------------------------------------------------------------------
Get-DockerStatus() {
    if ! Test-DockerInstalled; then
        echo "not-installed"
        return 1
    fi

    if systemctl is-active docker >/dev/null 2>&1; then
        echo "running"
        return 0
    else
        echo "stopped"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Test-DockerContainerExists: Check if a container exists (any state)
# Returns 0 (true) if exists, 1 (false) if not
# Usage: if Test-DockerContainerExists "container-name"; then ... fi
#-------------------------------------------------------------------------------
Test-DockerContainerExists() {
    local ContainerName="$1"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${ContainerName}$"
}

#-------------------------------------------------------------------------------
# Test-DockerContainerRunning: Check if a container is running
# Returns 0 (true) if running, 1 (false) if not
# Usage: if Test-DockerContainerRunning "container-name"; then ... fi
#-------------------------------------------------------------------------------
Test-DockerContainerRunning() {
    local ContainerName="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ContainerName}$"
}

#-------------------------------------------------------------------------------
# Get-DockerContainerStatus: Get container status
# Returns: "running", "exited", "paused", "restarting", "created", "not-found"
# Usage: STATUS=$(Get-DockerContainerStatus "container-name")
#-------------------------------------------------------------------------------
Get-DockerContainerStatus() {
    local ContainerName="$1"
    local Status

    if ! Test-DockerContainerExists "$ContainerName"; then
        echo "not-found"
        return 1
    fi

    Status=$(docker inspect --format '{{.State.Status}}' "$ContainerName" 2>/dev/null)
    echo "${Status:-unknown}"
}

#-------------------------------------------------------------------------------
# Get-DockerContainerHealth: Get container health status
# Returns: "healthy", "unhealthy", "starting", "none", "not-found"
# Usage: HEALTH=$(Get-DockerContainerHealth "container-name")
#-------------------------------------------------------------------------------
Get-DockerContainerHealth() {
    local ContainerName="$1"
    local Health

    if ! Test-DockerContainerExists "$ContainerName"; then
        echo "not-found"
        return 1
    fi

    Health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ContainerName" 2>/dev/null)
    echo "${Health:-unknown}"
}

#-------------------------------------------------------------------------------
# Start-DockerContainer: Start a stopped container
# Usage: Start-DockerContainer "container-name"
#-------------------------------------------------------------------------------
Start-DockerContainer() {
    local ContainerName="$1"

    if ! Test-DockerContainerExists "$ContainerName"; then
        echo "[FAIL] Container '$ContainerName' not found"
        return 1
    fi

    if Test-DockerContainerRunning "$ContainerName"; then
        echo "[SKIP] $ContainerName (already running)"
        return 0
    fi

    echo "[START] $ContainerName"
    if docker start "$ContainerName" >/dev/null 2>&1; then
        echo "[OK] $ContainerName started"
        return 0
    else
        echo "[FAIL] $ContainerName failed to start"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Stop-DockerContainer: Stop a running container
# Usage: Stop-DockerContainer "container-name"
#-------------------------------------------------------------------------------
Stop-DockerContainer() {
    local ContainerName="$1"

    if ! Test-DockerContainerExists "$ContainerName"; then
        echo "[SKIP] Container '$ContainerName' not found"
        return 0
    fi

    if ! Test-DockerContainerRunning "$ContainerName"; then
        echo "[SKIP] $ContainerName (not running)"
        return 0
    fi

    echo "[STOP] $ContainerName"
    if docker stop "$ContainerName" >/dev/null 2>&1; then
        echo "[OK] $ContainerName stopped"
        return 0
    else
        echo "[FAIL] $ContainerName failed to stop"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Remove-DockerContainer: Remove a container (stops first if running)
# Usage: Remove-DockerContainer "container-name"
#-------------------------------------------------------------------------------
Remove-DockerContainer() {
    local ContainerName="$1"

    if ! Test-DockerContainerExists "$ContainerName"; then
        echo "[SKIP] Container '$ContainerName' not found"
        return 0
    fi

    echo "[REMOVE] $ContainerName"
    if docker rm -f "$ContainerName" >/dev/null 2>&1; then
        echo "[OK] $ContainerName removed"
        return 0
    else
        echo "[FAIL] $ContainerName failed to remove"
        return 1
    fi
}

