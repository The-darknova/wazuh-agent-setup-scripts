<#
.SYNOPSIS
    Windows Unified Security Installer (Wazuh + Sysmon)
.DESCRIPTION
    Installs Wazuh Agent and Sysmon on a Windows Server idempotently.
    Designed for single-pipe execution (iwr | iex).
#>

# Force TLS 1.2 for secure downloads (Critical for older Windows Servers)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# 1. Configuration Block (The Variables)
$ManagerIP = "[IP/DNS]"
$RegPassword = "[PASSWORD]"

# Reverted to your internal infrastructure to avoid internet dependency and supply chain attacks
$WazuhMSI = "http://[IP/DNS]/windows/wazuh-agent.msi"
$SysmonEXE = "http://[IP/DNS]/windows/Sysmon64.exe"
$SysmonConfig = "http://[IP/DNS]/windows/sysmonconfig-export.xml"

# Workspace
$InstallDir = "C:\windows\temp\security-install"
$WazuhMSIPath = "$InstallDir\wazuh-agent.msi"
$SysmonEXEPath = "$InstallDir\Sysmon64.exe"
$SysmonConfigPath = "$InstallDir\sysmonconfig.xml"
$InstallDir_Wazuh = "C:\Program Files (x86)\ossec-agent"

# 2. Cleanup Phase (Ensure a Clean Slate)
If (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

try {
    # Sysmon Cleanup: Check if running, if so, download the exe just to run the uninstaller
    $sysmonSvc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    if ($sysmonSvc) {
        Write-Output "Existing Sysmon found. Uninstalling..."
        Invoke-WebRequest -Uri $SysmonEXE -OutFile $SysmonEXEPath -UseBasicParsing
        
        # Fixed: Removed the dash from force and split the arguments into an array
        $p = Start-Process -FilePath $SysmonEXEPath -ArgumentList @("-u", "force") -Wait -PassThru -WindowStyle Hidden
        
        # Critical: Give Windows time to unregister the driver and service
        Start-Sleep -Seconds 3 
    }

    # Wazuh Cleanup: Find via Registry and uninstall
    # Enhanced Wazuh Cleanup
    $wazuhSvc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    if ($wazuhSvc) {
        Write-Output "Stopping existing Wazuh service..."
        Stop-Service -Name "WazuhSvc" -Force -ErrorAction SilentlyContinue
    }

    # 1. Try generic MSI uninstall via WMI (Catches all versions)
    $wazuhApp = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -match "Wazuh Agent" }
    if ($wazuhApp) {
        Write-Output "Uninstalling Wazuh via WMI..."
        $wazuhApp.Uninstall() | Out-Null
    }

    # 2. Force purge the specific known Product Code just in case WMI misses it
    Write-Output "Purging known Wazuh GUIDs..."
    $pArgs = "/x `"{6B0320B5-3B7E-448E-BF58-9C95D34C14FC}`" /qn /norestart"
    Start-Process "msiexec.exe" -ArgumentList $pArgs -Wait -NoNewWindow

    # 3. Nuke the service definition
    sc.exe delete "WazuhSvc" | Out-Null

    # Critical: Give Windows a moment to release file locks and flush the MSI cache
    Start-Sleep -Seconds 5
    Remove-Item -Path $InstallDir_Wazuh -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Could not perform total clean-up. Proceeding to installation: $($_.Exception.Message)"
}

# 3. Wazuh Deployment Logic
try {
    Write-Output "Downloading and installing Wazuh Agent..."
    Invoke-WebRequest -Uri $WazuhMSI -OutFile $WazuhMSIPath -UseBasicParsing
    
    # Passing arguments as an array prevents PowerShell quote-mangling
    $wazuhArgs = @(
        "/i", $WazuhMSIPath,
        "/qn",
        "WAZUH_MANAGER=$ManagerIP"
    )
    $pWazuh = Start-Process -FilePath "msiexec.exe" -ArgumentList $wazuhArgs -Wait -PassThru -WindowStyle Hidden
    
    if ($pWazuh.ExitCode -notin @(0, 3010)) {
        throw "MSI Installer returned exit code $($pWazuh.ExitCode)"
    }

    Write-Output "Enrolling agent with Wazuh Manager..."
    # Explicitly run the enrollment tool with the password
    $AgentAuth = "C:\Program Files (x86)\ossec-agent\agent-auth.exe"
    
    # Wait for the executable to be available on disk
    while (-not (Test-Path $AgentAuth)) { Start-Sleep -Seconds 1 }

    $authArgs = @("-m", $ManagerIP, "-P", $RegPassword)
    $pAuth = Start-Process -FilePath $AgentAuth -ArgumentList $authArgs -Wait -PassThru -WindowStyle Hidden
    
    if ($pAuth.ExitCode -ne 0) {
        Write-Warning "agent-auth.exe returned exit code: $($pAuth.ExitCode). Registration may have failed."
    }
}
catch {
    Write-Error "Wazuh Deployment Failed: $($_.Exception.Message)"
    exit 1
}

# 4. Sysmon Deployment Logic
try {
    Write-Output "Downloading and installing Sysmon..."
    if (-not (Test-Path $SysmonEXEPath)) {
        Invoke-WebRequest -Uri $SysmonEXE -OutFile $SysmonEXEPath -UseBasicParsing
    }
    Invoke-WebRequest -Uri $SysmonConfig -OutFile $SysmonConfigPath -UseBasicParsing
    
    $sysmonArgs = @("-i", "$SysmonConfigPath", "-accepteula")
    $pSysmon = Start-Process -FilePath $SysmonEXEPath -ArgumentList $sysmonArgs -Wait -PassThru -WindowStyle Hidden
    
    if ($pSysmon.ExitCode -ne 0) {
        throw "Sysmon Installer returned exit code $($pSysmon.ExitCode)"
    }
}
catch {
    Write-Error "Sysmon Deployment Failed: $($_.Exception.Message)"
    exit 1
}

# 5. Validation & Telemetry
$ErrorActionPreference = "Continue"

Write-Output "Enforcing English locale for Wazuh Agent..."
$wazuhSvcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WazuhSvc"
if (Test-Path $wazuhSvcRegPath) {
    Stop-Service -Name "WazuhSvc" -Force -ErrorAction SilentlyContinue
    New-ItemProperty -Path $wazuhSvcRegPath -Name "Environment" -Value @("LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8") -PropertyType MultiString -Force | Out-Null
}

Write-Output "Validating Services..."
Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
Start-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

# Basic connectivity test (Port 1514 or 1515)
$conn = Test-NetConnection -ComputerName $ManagerIP -Port 1514 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $conn) {
    $conn = Test-NetConnection -ComputerName $ManagerIP -Port 1515 -InformationLevel Quiet -WarningAction SilentlyContinue
}

$wCheck = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
$sCheck = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

$wazuhRunning = [bool]($wCheck -and $wCheck.Status -eq 'Running')
$sysmonRunning = [bool]($sCheck -and $sCheck.Status -eq 'Running')
$overallSuccess = $wazuhRunning -and $sysmonRunning

$statusJSON = [ordered]@{
    Status       = if ($overallSuccess) { "Success" } else { "Failed" }
    Agent        = if ($wazuhRunning) { "Installed" } else { "Error" }
    Sysmon       = if ($sysmonRunning) { "Active" } else { "Error" }
    Connectivity = if ($conn) { "OK" } else { "Failed" }
}

# Clean Up Install Dir if Validation Passed (Prevents leaving sensitive logs/configs behind)
if ($overallSuccess) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$statusJSON | ConvertTo-Json -Compress