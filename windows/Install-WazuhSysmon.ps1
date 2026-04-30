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
$ManagerIP   = "[IP/DNS]"
$RegPassword = "[PASSWORD]"

# Reverted to your internal infrastructure to avoid internet dependency and supply chain attacks
$WazuhMSI     = "http://[IP/DNS]/windows/wazuh-agent.msi"
$SysmonEXE    = "http://[IP/DNS]/windows/Sysmon64.exe"
$SysmonConfig = "http://[IP/DNS]/windows/sysmonconfig-export.xml"

# Workspace
$InstallDir       = "C:\windows\temp\security-install"
$WazuhMSIPath     = "$InstallDir\wazuh-agent.msi"
$SysmonEXEPath    = "$InstallDir\Sysmon64.exe"
$SysmonConfigPath = "$InstallDir\sysmonconfig.xml"

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
        $p = Start-Process -FilePath $SysmonEXEPath -ArgumentList "-u -force" -Wait -PassThru -WindowStyle Hidden
    }

    # Wazuh Cleanup: Find via Registry and uninstall
    $wazuhSvc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    if ($wazuhSvc) {
        Write-Output "Existing Wazuh found. Uninstalling..."
        $uninstallRegPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $uninstallId = (Get-ItemProperty $uninstallRegPaths -ErrorAction SilentlyContinue | Where-Object DisplayName -match "Wazuh Agent").IdentifyingNumber | Select-Object -First 1
        
        if ($uninstallId) {
            $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $uninstallId /qn" -Wait -PassThru -WindowStyle Hidden
        }
    }
} catch {
    Write-Warning "Could not perform total clean-up. Proceeding to installation: $($_.Exception.Message)"
}

# 3. Wazuh Deployment Logic
try {
    Write-Output "Downloading and installing Wazuh Agent..."
    Invoke-WebRequest -Uri $WazuhMSI -OutFile $WazuhMSIPath -UseBasicParsing
    
    $wazuhArgs = "/i `"$WazuhMSIPath`" /qn WAZUH_MANAGER=`"$ManagerIP`" WAZUH_REGISTRATION_PASSWORD=`"$RegPassword`" WAZUH_AGENT_GROUP=`"Windows`""
    $pWazuh = Start-Process -FilePath "msiexec.exe" -ArgumentList $wazuhArgs -Wait -PassThru -WindowStyle Hidden
    
    if ($pWazuh.ExitCode -notin @(0, 3010)) {
        throw "MSI Installer returned exit code $($pWazuh.ExitCode)"
    }
} catch {
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
} catch {
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

$wazuhRunning  = [bool]($wCheck -and $wCheck.Status -eq 'Running')
$sysmonRunning = [bool]($sCheck -and $sCheck.Status -eq 'Running')
$overallSuccess= $wazuhRunning -and $sysmonRunning

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