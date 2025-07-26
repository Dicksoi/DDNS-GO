#!/bin/bash
# DDNS-Go安装脚本（修复404问题）
# 适用于没有sudo的环境

# 基本配置
DDNS_GO_GH_REPO="jeessy2/ddns-go"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ddns-go"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 依赖检查
check_deps() {
    for cmd in curl tar jq; do
        if ! command -v "$cmd" >/dev/null; then
            log "${YELLOW}正在安装依赖: $cmd${NC}"
            apt-get update && apt-get install -y "$cmd" || {
                log "${RED}无法安装 $cmd${NC}"
                exit 1
            }
        fi
    done
}

# 安装流程
install() {
    check_deps
    
    log "${GREEN}正在获取最新版本...${NC}"
    latest_version=$(curl -s "https://api.github.com/repos/${DDNS_GO_GH_REPO}/releases/latest" | jq -r '.tag_name')
    [ -z "$latest_version" ] && {
        log "${RED}无法获取最新版本${NC}"
        exit 1
    }

    # 确定系统架构
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="x86_64" ;;
        armv7l) arch="armv7" ;;
        aarch64) arch="arm64" ;;
        *) arch="x86_64" ;;
    esac

    # 创建临时目录
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    # 尝试两种URL格式
    for url_format in \
        "https://github.com/${DDNS_GO_GH_REPO}/releases/download/${latest_version}/ddns-go_${latest_version#v}_Linux_${arch}.tar.gz" \
        "https://github.com/${DDNS_GO_GH_REPO}/releases/download/${latest_version}/ddns-go_${latest_version#v}_linux_${arch}.tar.gz"
    do
        log "${YELLOW}尝试下载: $url_format${NC}"
        if curl -fL "$url_format" -o "${temp_dir}/ddns-go.tar.gz"; then
            log "${GREEN}下载成功${NC}"
            break
        fi
    done

    [ ! -f "${temp_dir}/ddns-go.tar.gz" ] && {
        log "${RED}所有下载尝试均失败${NC}"
        exit 1
    }

    # 解压和安装
    tar xzf "${temp_dir}/ddns-go.tar.gz" -C "$temp_dir"
    mkdir -p "$INSTALL_DIR"
    mv "${temp_dir}/ddns-go" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/ddns-go"

    # 创建配置文件
    mkdir -p "$CONFIG_DIR"
    echo -e "PORT=9876\nINTERVAL=300" > "$CONFIG_DIR/config.yaml"

    log "${GREEN}安装完成！${NC}"
    echo -e "运行命令: ${INSTALL_DIR}/ddns-go -l :9876 -f 300 -c ${CONFIG_DIR}/config.yaml"
}

install
