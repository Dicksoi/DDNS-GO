#!/bin/bash
# Script Version: 1.2.5-rootfix
# Fully removed sudo dependencies

# --- Strict Mode ---
set -e
set -o pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Configuration ---
DDNS_GO_GH_REPO="jeessy2/ddns-go"
INSTALL_DIR="/usr/local/bin"
BIN_NAME="ddns-go"
BIN_PATH="${INSTALL_DIR}/${BIN_NAME}"
CONFIG_DIR="/etc/ddns-go"
CONFIG_FILE="${CONFIG_DIR}/ddns-go.conf"
SERVICE_FILE="/etc/systemd/system/ddns-go.service"
DDNS_USER="ddns-go"

# --- Utility Functions ---
log() {
    local type="$1" msg="$2"
    case "$type" in
        INFO) color="${BLUE}" ;;
        SUCCESS) color="${GREEN}" ;;
        WARN) color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
        *) color="${NC}" ;;
    esac
    echo -e "${color}[$(date +'%Y-%m-%d %H:%M:%S')] [${type}] ${msg}${NC}" >&2
}

die() { log "ERROR" "$1"; exit 1; }

# --- Dependency Check ---
check_deps() {
    for cmd in curl tar jq; do
        if ! command -v "$cmd" >/dev/null; then
            log "INFO" "正在安装依赖: $cmd"
            apt-get update -y && apt-get install -y "$cmd" || die "无法安装 $cmd"
        fi
    done
}

# --- Installation ---
install_ddns_go() {
    # Get latest version
    log "INFO" "正在获取最新版本..."
    latest_version=$(curl -s "https://api.github.com/repos/${DDNS_GO_GH_REPO}/releases/latest" | jq -r '.tag_name')
    [ -z "$latest_version" ] && die "无法获取最新版本"

    # Prepare temp directory
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    # Download and extract
    log "INFO" "正在下载 ${latest_version}..."
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        arm*) arch="arm" ;;
        *) arch="amd64" ;;
    esac
    
    download_url="https://github.com/${DDNS_GO_GH_REPO}/releases/download/${latest_version}/ddns-go_${latest_version#v}_linux_${arch}.tar.gz"
    curl -fL "$download_url" -o "${temp_dir}/ddns-go.tar.gz" || die "下载失败"
    
    log "INFO" "正在解压..."
    tar xzf "${temp_dir}/ddns-go.tar.gz" -C "$temp_dir" || die "解压失败"
    
    # Install binary
    log "INFO" "正在安装到 ${BIN_PATH}"
    mkdir -p "${INSTALL_DIR}"
    mv "${temp_dir}/ddns-go" "${BIN_PATH}"
    chmod +x "${BIN_PATH}"

    # Create config
    log "INFO" "正在创建配置文件..."
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_FILE}" <<EOF
PORT=9876
INTERVAL=300
NOWEB=false
EOF

    # Create service user
    if ! id "${DDNS_USER}" &>/dev/null; then
        useradd -r -s /bin/false "${DDNS_USER}"
    fi
    chown -R "${DDNS_USER}:${DDNS_USER}" "${CONFIG_DIR}"

    # Create systemd service
    log "INFO" "正在创建系统服务..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=DDNS-Go Service
After=network.target

[Service]
User=${DDNS_USER}
ExecStart=${BIN_PATH} -l :9876 -f 300 -c ${CONFIG_FILE}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ddns-go
    systemctl start ddns-go

    log "SUCCESS" "安装完成！"
    echo -e "访问管理界面: ${GREEN}http://<你的IP>:9876${NC}"
}

# --- Main ---
check_deps
install_ddns_go
