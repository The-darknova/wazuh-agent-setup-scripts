#!/usr/bin/env bash
#
# Universal Linux Wazuh Installer (Distro-Adaptive)
# Execution Mode: Bash / Root / Silent / Pipe-compatible

set -e

# ==========================================
# 1. Configuration Block (Variables)
# ==========================================
WAZUH_MANAGER="[IP/DNS]"
WAZUH_REG_PASS="[PASSWORD]"

# Internal package repository
REPO_URL="http://[IP/DNS]/linux"
WAZUH_DEB_PKG="wazuh-agent_amd64.deb"
WAZUH_RPM_PKG="wazuh-agent-x86_64.rpm"

# ==========================================
# Utility Functions
# ==========================================
log() { echo -e "[INFO] $1"; }
error() { echo -e "[ERROR] $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
    error "Please run this script as root (e.g., sudo bash)."
fi

# ==========================================
# 2. Intelligent Distro Detection
# ==========================================
log "Detecting operating system..."

if [ ! -f /etc/os-release ]; then
    error "/etc/os-release not found. Cannot determine the Linux distribution."
fi

source /etc/os-release

OS_FAMILY=""
PKG_MANAGER=""
PKG_EXT=""

if [[ "$ID" == "debian" || "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* || "$ID_LIKE" == *"ubuntu"* ]]; then
    OS_FAMILY="debian"
    PKG_MANAGER="apt-get"
    PKG_EXT="deb"
elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "almalinux" || "$ID" == "rocky" || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"centos"* || "$ID_LIKE" == *"fedora"* ]]; then
    OS_FAMILY="redhat"
    PKG_MANAGER="yum"
    if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    fi
    PKG_EXT="rpm"
else
    error "Unsupported OS family. Auto-Detection works for Debian and RHEL derivatives."
fi

log "Detected OS Family: $OS_FAMILY ($PKG_MANAGER)"

# ==========================================
# 3. Prerequisite Check (Ensuring curl exists)
# ==========================================
if ! command -v curl >/dev/null 2>&1; then
    log "curl is missing. Installing curl..."
    if [ "$OS_FAMILY" == "debian" ]; then
        $PKG_MANAGER update -y && $PKG_MANAGER install -y curl
    elif [ "$OS_FAMILY" == "redhat" ]; then
        $PKG_MANAGER install -y curl
    fi
fi

# ==========================================
# 4. "Hard Purge" Cleanup
# ==========================================
log "Initiating cleanup of existing installations..."

if systemctl list-unit-files wazuh-agent.service >/dev/null 2>&1; then
    if systemctl is-active --quiet wazuh-agent; then
        log "Stopping wazuh-agent service..."
        systemctl stop wazuh-agent || true
    fi
fi

if [ "$OS_FAMILY" == "debian" ]; then
    DEBIAN_FRONTEND=noninteractive $PKG_MANAGER purge -y wazuh-agent || true
elif [ "$OS_FAMILY" == "redhat" ]; then
    $PKG_MANAGER remove -y wazuh-agent || true
fi

if [ -d "/var/ossec" ]; then
    log "Wiping /var/ossec directory to prevent Duplicate ID errors..."
    rm -rf /var/ossec || error "Failed to delete /var/ossec."
fi

# ==========================================
# 5. Adaptive Installation Logic
# ==========================================
TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

PKG_FILE="$TEMP_DIR/wazuh-agent.$PKG_EXT"

if [ "$OS_FAMILY" == "debian" ]; then
    DOWNLOAD_URL="$REPO_URL/$WAZUH_DEB_PKG"
elif [ "$OS_FAMILY" == "redhat" ]; then
    DOWNLOAD_URL="$REPO_URL/$WAZUH_RPM_PKG"
fi

log "Downloading Wazuh Agent package..."
if ! curl -sSL --fail "$DOWNLOAD_URL" -o "$PKG_FILE"; then
    error "Download failed. Please check the URL or network connectivity."
fi

log "Injecting Wazuh Manager IP and Registration Password..."
export WAZUH_MANAGER="$WAZUH_MANAGER"
export WAZUH_REGISTRATION_PASSWORD="$WAZUH_REG_PASS"

log "Starting package installation..."
# Using apt-get/yum install on the local file ensures missing dependencies are resolved automatically
if [ "$OS_FAMILY" == "debian" ]; then
    DEBIAN_FRONTEND=noninteractive $PKG_MANAGER install -y "$PKG_FILE"
elif [ "$OS_FAMILY" == "redhat" ]; then
    $PKG_MANAGER install -y "$PKG_FILE"
fi

# ==========================================
# 6. Service & Verification
# ==========================================
log "Configuring service to start on boot..."
systemctl enable wazuh-agent

log "Starting wazuh-agent service..."
systemctl start wazuh-agent

log "Waiting 5 seconds for service stabilization..."
sleep 5

log "Performing health check..."
if ! systemctl is-active --quiet wazuh-agent; then
    echo -e "[ERROR] Wazuh Agent failed to stay active. Reviewing the last 5 logs:" >&2
    journalctl -u wazuh-agent --no-pager | tail -n 5 >&2
    exit 1
else
    log "Wazuh Agent successfully installed and is running!"
fi