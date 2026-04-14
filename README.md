# Wazuh Agent Setup

This repository contains scripts to automate the deployment of the Wazuh Agent across multiple platforms in an enterprise environment.

## Overview

- [`install-wazuh-agent.sh`](#install-wazuh-agentsh) - Universal installer for Debian/RHEL based Linux systems.
- [`Install-WazuhSysmon.ps1`](#install-wazuhsysmonps1) - Unified installer for Wazuh and Sysmon on Windows Server environments.

---

### `install-wazuh-agent.sh`
**Universal Linux Wazuh Installer (Distro-Adaptive)**

A Bash script designed to auto-detect the operating system (Debian, Ubuntu, RHEL, CentOS, Fedora, Rocky, etc.) and intelligently deploy the correct Wazuh agent package. 

**Features:**
- **Intelligent OS Detection:** Automatically pulls the relevant package (`.deb` or `.rpm`) based on the underlying distribution.
- **Clean Slate Deployment:** Includes a hard purge cleanup phase to remove any previous configurations or leftover `/var/ossec` residues.
- **Internal Repository:** Configured to pull packages from an internal repository (`http://dep.infra.local/linux`) rather than public mirrors.
- **Fail-Safe Startup:** Configures service persistence, starts the agent, and performs a 5-second post-install health check.

**Usage:**
Ensure you update the configuration block variables at the top of the script:
```sh
WAZUH_MANAGER="YOUR_MANAGER_IP"
WAZUH_REG_PASS="YOUR_PASSWORD"
```
Execute the script as `root`:
```sh
sudo bash install-wazuh-agent.sh
```

---

### `Install-WazuhSysmon.ps1`
**Windows Unified Security Installer (Wazuh + Sysmon)**

An idempotent PowerShell script designed to install both the Wazuh Agent and Sysmon onto Windows machines.

**Features:**
- **Cleanup Phase:** Searches the registry and active services to purge legacy Wazuh or Sysmon installs before attempting deployment.
- **Internal Dependencies:** Fetches the Sysmon executable, Sysmon XML configuration, and Wazuh MSI from internal architecture (`https://dep.infra.local/windows/`).
- **Telemetry and Validation:** Tests outbound connectivity to both port 1514 and 1515 of the Wazuh manager. Outputs a concise JSON payload representing the final status.
- **Silent & Unattended:** Perfect for mass deployment via SCCM, GPO, or PowerShell Remoting (`Invoke-Command`). 

**Usage:**
Modify the connection details block with your specific coordinates:
```powershell
$ManagerIP   = "YOUR_IP"
$RegPassword = "YOUR_PASSWORD"
```
Run script directly in an elevated PowerShell session:
```powershell
.\Install-WazuhSysmon.ps1
```
