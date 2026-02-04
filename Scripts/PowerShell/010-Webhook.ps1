#Requires -Version 5.1
#===============================================================================
# 010-Webhook.ps1
# Send system information webhook
#===============================================================================

#-------------------------------------------------------------------------------
# Script Configuration
#-------------------------------------------------------------------------------
$ScriptFileInfo = New-Object -TypeName 'System.IO.FileInfo' -ArgumentList $PSCommandPath
$ScriptName = $ScriptFileInfo.Name
$ScriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptFileInfo.Name)
$ScriptDirectory = $ScriptFileInfo.DirectoryName
$Enabled = $true
$ExcludePattern = '^$'

#-------------------------------------------------------------------------------
# Dot source functions from Functions/PowerShell folder
#-------------------------------------------------------------------------------
$FunctionsDirectory = [System.IO.Path]::Combine($ScriptDirectory, '..', '..', 'Functions', 'PowerShell')
$FunctionsDirectoryInfo = New-Object -TypeName 'System.IO.DirectoryInfo' -ArgumentList $FunctionsDirectory
if ($FunctionsDirectoryInfo.Exists) {
    $FunctionFiles = Get-ChildItem -Path $FunctionsDirectoryInfo.FullName -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($FunctionFile in $FunctionFiles) {
        . $FunctionFile.FullName
    }
}

#-------------------------------------------------------------------------------
# Transcript Configuration
#-------------------------------------------------------------------------------
$LogsDirectory = [System.IO.Path]::Combine($ScriptDirectory, 'Logs')
$LogsDirectoryInfo = New-Object -TypeName 'System.IO.DirectoryInfo' -ArgumentList $LogsDirectory
if (-not $LogsDirectoryInfo.Exists) {
    $LogsDirectoryInfo.Create()
}
$TranscriptPath = [System.IO.Path]::Combine($LogsDirectory, "$ScriptBaseName.log")
$Null = Start-Transcript -Path $TranscriptPath -Append -Force

#Check if script should run
if (-not $Enabled) {
    Write-Log "SKIP" "$ScriptName is disabled"
    $Null = Stop-Transcript
    exit 0
}

$Hostname = [System.Net.Dns]::GetHostName()
if ($Hostname -match $ExcludePattern) {
    Write-Log "SKIP" "$ScriptName - hostname '$Hostname' matches exclude pattern '$ExcludePattern'"
    $Null = Stop-Transcript
    exit 0
}

Write-Log "INFO" "=== System Information Webhook ==="

#-------------------------------------------------------------------------------
# Webhook Configuration
#-------------------------------------------------------------------------------
$WebhookUrl = "https://automation.example.com/webhook/YOUR_WEBHOOK_ID"
$WebhookToken = "YOUR_WEBHOOK_TOKEN_HERE"

#-------------------------------------------------------------------------------
# Gather System Information (Linux-compatible)
#-------------------------------------------------------------------------------

#Network adapters - parse ip addr output
Write-Log "INFO" "[GATHER] Network adapters"
$NetworkAdapters = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'

#Get default gateway per interface
$GatewayMap = @{}
$IpRouteOutput = & ip route show 2>/dev/null
foreach ($RouteLine in $IpRouteOutput -split "`n") {
    if ($RouteLine -match '^default via (\d+\.\d+\.\d+\.\d+) dev (\S+)') {
        $GatewayMap[$Matches[2]] = $Matches[1]
    }
}

#Get DNS servers from systemd-resolved
$DnsServersGlobal = New-Object -TypeName 'System.Collections.Generic.List[string]'
$ResolvPath = '/run/systemd/resolve/resolv.conf'
if (Test-Path $ResolvPath) {
    $ResolvContent = Get-Content $ResolvPath -ErrorAction SilentlyContinue
    foreach ($ResolvLine in $ResolvContent) {
        if ($ResolvLine -match '^nameserver\s+(\d+\.\d+\.\d+\.\d+)') {
            $DnsServer = $Matches[1]
            if (-not $DnsServersGlobal.Contains($DnsServer)) {
                $DnsServersGlobal.Add($DnsServer)
            }
        }
    }
}

$IpAddrOutput = & ip -o addr show 2>/dev/null
foreach ($Line in $IpAddrOutput -split "`n") {
    if ($Line -match '^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)') {
        $InterfaceName = $Matches[1]
        $IpAddress = $Matches[2]
        $Cidr = $Matches[3]

        #Skip loopback
        if ($InterfaceName -eq 'lo') { continue }

        #Get MAC address (keep colons)
        $MacAddress = $null
        $MacPath = "/sys/class/net/$InterfaceName/address"
        if (Test-Path $MacPath) {
            $MacAddress = (Get-Content $MacPath -ErrorAction SilentlyContinue).Trim().ToUpper()
        }

        #Check if adapter already in list
        $ExistingAdapter = $NetworkAdapters | Where-Object { $_['interface'] -eq $InterfaceName }
        if ($ExistingAdapter) {
            $AddressInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $AddressInfo.Add('ip', $IpAddress)
            $AddressInfo.Add('subnetmaskbits', [int]$Cidr)
            $AddressInfo.Add('cidr', "$($AddressInfo.ip)/$($AddressInfo.subnetmaskbits)")
            $ExistingAdapter['addresses'].Add($AddressInfo)
        } else {
            $AdapterInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $AdapterInfo.Add('interface', $InterfaceName)
            $AdapterInfo.Add('mac', $MacAddress)

            $Addresses = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
            $AddressInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $AddressInfo.Add('ip', $IpAddress)
            $AddressInfo.Add('subnetmaskbits', [int]$Cidr)
            $AddressInfo.Add('cidr', "$($AddressInfo.ip)/$($AddressInfo.subnetmaskbits)")
            $Addresses.Add($AddressInfo)
            $AdapterInfo.Add('addresses', $Addresses)

            #Add gateway if available
            $Gateway = $GatewayMap[$InterfaceName]
            $AdapterInfo.Add('gateway', $Gateway)

            #Add DNS servers (from systemd-resolved)
            $AdapterInfo.Add('dns_servers', $DnsServersGlobal)

            $NetworkAdapters.Add($AdapterInfo)
        }
    }
}

#Public IP
Write-Log "INFO" "[GATHER] Public IP"
try {
    $PublicIp = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10 -ErrorAction Stop
} catch {
    $PublicIp = 'unknown'
}

#Hard disks - parse lsblk output
Write-Log "INFO" "[GATHER] Disk information"
$HardDisks = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
$LsblkOutput = & lsblk -J -b -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($LsblkOutput -and $LsblkOutput.blockdevices) {
    foreach ($Device in $LsblkOutput.blockdevices) {
        if ($Device.type -eq 'disk') {
            $DiskInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $DiskInfo.Add('name', $Device.name)
            $SizeGB = [math]::Round([double]$Device.size / 1073741824, 2)
            $DiskInfo.Add('size', "$SizeGB GB")

            $Partitions = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
            if ($Device.children) {
                foreach ($Child in $Device.children) {
                    $PartInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                    $PartInfo.Add('name', $Child.name)
                    $PartSizeGB = [math]::Round([double]$Child.size / 1073741824, 2)
                    $PartInfo.Add('size', "$PartSizeGB GB")
                    $PartInfo.Add('mountpoint', $Child.mountpoint)
                    $Partitions.Add($PartInfo)
                }
            }
            $DiskInfo.Add('partitions', $Partitions)
            $HardDisks.Add($DiskInfo)
        }
    }
}

#OS information - read /etc/os-release
Write-Log "INFO" "[GATHER] OS information"
$OsInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$OsReleasePath = '/etc/os-release'
if (Test-Path $OsReleasePath) {
    $OsReleaseContent = Get-Content $OsReleasePath -ErrorAction SilentlyContinue
    $OsRelease = @{}
    foreach ($Line in $OsReleaseContent) {
        if ($Line -match '^(\w+)=(.*)$') {
            $Key = $Matches[1]
            $Value = $Matches[2].Trim('"')
            $OsRelease[$Key] = $Value
        }
    }
    $OsInfo.Add('name', $OsRelease['PRETTY_NAME'])
    $OsInfo.Add('version', $OsRelease['VERSION'])
    $OsInfo.Add('version_id', $OsRelease['VERSION_ID'])

    #Get architecture
    $Arch = & uname -m 2>/dev/null
    $OsInfo.Add('architecture', $Arch.Trim())
}

#User accounts - parse /etc/passwd for users with login shells
Write-Log "INFO" "[GATHER] User accounts"
$UserAccounts = New-Object -TypeName 'System.Collections.Generic.List[string]'
$PasswdPath = '/etc/passwd'
if (Test-Path $PasswdPath) {
    $PasswdContent = Get-Content $PasswdPath -ErrorAction SilentlyContinue
    foreach ($Line in $PasswdContent) {
        $Fields = $Line -split ':'
        if ($Fields.Count -ge 7) {
            $Username = $Fields[0]
            $Uid = [int]$Fields[2]
            $Shell = $Fields[6]

            #Include users with UID >= 1000 or root, with valid login shells
            if (($Uid -ge 1000 -or $Uid -eq 0) -and $Shell -notmatch '(nologin|false)$') {
                $UserAccounts.Add($Username)
            }
        }
    }
}

#Timezone - read from timedatectl or /etc/timezone
$Timezone = $null
$TimedatectlOutput = & timedatectl show --property=Timezone --value 2>/dev/null
if ($TimedatectlOutput) {
    $Timezone = $TimedatectlOutput.Trim()
} elseif (Test-Path '/etc/timezone') {
    $Timezone = (Get-Content '/etc/timezone' -ErrorAction SilentlyContinue).Trim()
} else {
    $Timezone = [System.TimeZoneInfo]::Local.Id
}

#CPU information
Write-Log "INFO" "[GATHER] CPU information"
$CpuInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$CpuInfoPath = '/proc/cpuinfo'
if (Test-Path $CpuInfoPath) {
    $CpuContent = Get-Content $CpuInfoPath -ErrorAction SilentlyContinue
    $CpuModel = ($CpuContent | Where-Object { $_ -match '^model name' } | Select-Object -First 1) -replace '^model name\s*:\s*', ''
    $CpuCores = ($CpuContent | Where-Object { $_ -match '^processor' }).Count
    $CpuInfo.Add('model', $CpuModel)
    $CpuInfo.Add('cores', $CpuCores)
}

#Memory information
Write-Log "INFO" "[GATHER] Memory information"
$MemInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$MemInfoPath = '/proc/meminfo'
if (Test-Path $MemInfoPath) {
    $MemContent = Get-Content $MemInfoPath -ErrorAction SilentlyContinue
    $MemTotalKb = [long](($MemContent | Where-Object { $_ -match '^MemTotal:' }) -replace '[^0-9]', '')
    $MemAvailKb = [long](($MemContent | Where-Object { $_ -match '^MemAvailable:' }) -replace '[^0-9]', '')
    $MemInfo.Add('total_gb', [math]::Round($MemTotalKb / 1048576, 2))
    $MemInfo.Add('available_gb', [math]::Round($MemAvailKb / 1048576, 2))
    $MemInfo.Add('used_gb', [math]::Round(($MemTotalKb - $MemAvailKb) / 1048576, 2))
}

#Kernel version
Write-Log "INFO" "[GATHER] Kernel version"
$KernelVersion = (& uname -r 2>/dev/null).Trim()

#Uptime
Write-Log "INFO" "[GATHER] System uptime"
$UptimeSeconds = $null
$UptimePath = '/proc/uptime'
if (Test-Path $UptimePath) {
    $UptimeContent = (Get-Content $UptimePath -ErrorAction SilentlyContinue).Trim()
    $UptimeSeconds = [math]::Floor([double]($UptimeContent -split '\s+')[0])
}

#Docker information
Write-Log "INFO" "[GATHER] Docker information"
$DockerInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$DockerVersion = (& docker --version 2>/dev/null)
if ($DockerVersion) {
    $DockerInfo.Add('version', ($DockerVersion -replace 'Docker version ', '' -replace ',.*', '').Trim())
    $RunningContainers = (& docker ps -q 2>/dev/null | Measure-Object -Line).Lines
    $TotalContainers = (& docker ps -a -q 2>/dev/null | Measure-Object -Line).Lines
    $DockerInfo.Add('running_containers', $RunningContainers)
    $DockerInfo.Add('total_containers', $TotalContainers)

    #Get container details
    Write-Log "INFO" "[GATHER] Docker container details"
    $Containers = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
    $DockerPsJson = & docker ps -a --format '{{json .}}' 2>/dev/null
    if ($DockerPsJson) {
        foreach ($ContainerJson in $DockerPsJson -split "`n") {
            if ([string]::IsNullOrWhiteSpace($ContainerJson)) { continue }
            try {
                $Container = $ContainerJson | ConvertFrom-Json -ErrorAction Stop
                $ContainerInfo = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                $ContainerInfo.Add('id', $Container.ID)
                $ContainerInfo.Add('name', $Container.Names)
                $ContainerInfo.Add('image', $Container.Image)
                $ContainerInfo.Add('status', $Container.Status)
                $ContainerInfo.Add('state', $Container.State)
                $ContainerInfo.Add('ports', $Container.Ports)
                $ContainerInfo.Add('networks', $Container.Networks)
                $ContainerInfo.Add('created', $Container.CreatedAt)
                $Containers.Add($ContainerInfo)
            } catch {
                #Skip malformed JSON
            }
        }
    }
    $DockerInfo.Add('containers', $Containers)
} else {
    $DockerInfo.Add('installed', $false)
}

#-------------------------------------------------------------------------------
# Build Webhook Payload
#-------------------------------------------------------------------------------
Write-Log "INFO" "[BUILD] Webhook payload"

$WebhookPayload = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$WebhookPayload.Add('hostname', $Hostname.ToUpper())
$WebhookPayload.Add('fqdn', [System.Net.Dns]::GetHostEntry($Hostname).HostName)
$WebhookPayload.Add('public_ip', $PublicIp)
$WebhookPayload.Add('timezone', $Timezone)
$WebhookPayload.Add('timestamp', [DateTime]::UtcNow.ToString('o'))
$WebhookPayload.Add('kernel_version', $KernelVersion)
$WebhookPayload.Add('uptime_seconds', $UptimeSeconds)
$WebhookPayload.Add('cpu_info', $CpuInfo)
$WebhookPayload.Add('memory_info', $MemInfo)
$WebhookPayload.Add('network_adapters', $NetworkAdapters)
$WebhookPayload.Add('hard_disks', $HardDisks)
$WebhookPayload.Add('os_info', $OsInfo)
$WebhookPayload.Add('docker_info', $DockerInfo)
$WebhookPayload.Add('user_accounts', $UserAccounts)
$WebhookPayload.Add('dns_servers', $DnsServersGlobal)

$JsonPayload = $WebhookPayload | ConvertTo-Json -Depth 10 -Compress
Write-Host $JsonPayload

#-------------------------------------------------------------------------------
# Send Webhook
#-------------------------------------------------------------------------------
Write-Log "INFO" "[SEND] Webhook to $WebhookUrl"

$Headers = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
$Headers.Add('Content-Type', 'application/json')
$Headers.Add('Authorization', $WebhookToken)

try {
    $Response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers $Headers -Body $JsonPayload -TimeoutSec 30 -ErrorAction Stop
    Write-Log "INFO" "[OK] Webhook sent successfully"
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    Write-Log "ERROR" "[FAIL] Webhook error (HTTP $StatusCode): $($_.Exception.Message)"
}

Write-Log "INFO" "=== System Information Webhook Complete ==="

$Null = Stop-Transcript

