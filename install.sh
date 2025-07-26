#!/bin/bash

DDNS_GO_INSTALL_PATH="/opt/ddns-go"
DDNS_GO_SERVICE_FILE="/etc/systemd/system/ddns-go.service"
DDNS_GO_CONFIG_FILE="$DDNS_GO_INSTALL_PATH/.ddns_go_config.yaml"
DDNS_GO_LOG_FILE="$DDNS_GO_INSTALL_PATH/ddns-go.log"
DDNS_GO_UPDATE_LOG_FILE="$DDNS_GO_INSTALL_PATH/update.log"
UPDATE_SCRIPT_NAME="update_ddns_go.sh"
UPDATE_SCRIPT_PATH="$DDNS_GO_INSTALL_PATH/$UPDATE_SCRIPT_NAME"
CRON_COMMENT_TAG="ddns-go-auto-update"

DEFAULT_WEB_PORT="9876"
DDNS_GO_REPO="jeessy2/ddns-go"
DEFAULT_UPDATE_MINUTE="0"
DEFAULT_UPDATE_HOUR="3"
DEFAULT_UPDATE_DAY_OF_WEEK="*"

ARCH="" 

SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"
SCRIPT_MANAGED_WEB_ENABLED="true"
DDNS_GO_DEFAULT_SYNC_INTERVAL="600" 
SCRIPT_MANAGED_SYNC_INTERVAL="$DDNS_GO_DEFAULT_SYNC_INTERVAL"
SCRIPT_MANAGED_CACHE_TIMES=""      
SCRIPT_MANAGED_SKIP_VERIFY="false" 
SCRIPT_MANAGED_CUSTOM_DNS=""       

BACKED_UP_CONFIG_PATH=""

press_enter_to_continue() {
  echo ""
  read -r -p "按 Enter键 返回主菜单..."
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本必须以root权限运行。" >&2
    exit 1
  fi
}

get_public_ip() {
    IP=$(curl -s https://ipv4.icanhazip.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me/ip || hostname -I | awk '{print $1}')
    echo "$IP"
}

_read_and_set_current_service_config_vars() {
    SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"
    SCRIPT_MANAGED_WEB_ENABLED="true"
    SCRIPT_MANAGED_SYNC_INTERVAL="$DDNS_GO_DEFAULT_SYNC_INTERVAL"
    SCRIPT_MANAGED_CACHE_TIMES=""
    SCRIPT_MANAGED_SKIP_VERIFY="false"
    SCRIPT_MANAGED_CUSTOM_DNS=""

    if [ ! -f "$DDNS_GO_SERVICE_FILE" ]; then return ; fi
    local exec_start_line; exec_start_line=$(grep '^ExecStart=' "$DDNS_GO_SERVICE_FILE")
    if [ -z "$exec_start_line" ]; then echo "警告: ddns-go.service 文件中未找到 ExecStart 行。" >&2; return ; fi

    if [[ "$exec_start_line" == *"-noweb"* ]]; then SCRIPT_MANAGED_WEB_ENABLED="false"; else SCRIPT_MANAGED_WEB_ENABLED="true"; fi
    local port_val; port_val=$(echo "$exec_start_line" | grep -oP -- '-l\s*:\s*\K[0-9]+')
    if [[ -n "$port_val" ]]; then SCRIPT_MANAGED_WEB_PORT="$port_val"; elif [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; fi
    local f_val; f_val=$(echo "$exec_start_line" | grep -oP -- '-f\s+\K[0-9]+'); if [[ -n "$f_val" ]]; then SCRIPT_MANAGED_SYNC_INTERVAL="$f_val"; fi 
    local ct_val; ct_val=$(echo "$exec_start_line" | grep -oP -- '-cacheTimes\s+\K[0-9]+'); if [[ -n "$ct_val" ]]; then SCRIPT_MANAGED_CACHE_TIMES="$ct_val"; fi 
    if [[ "$exec_start_line" == *"-skipVerify"* ]]; then SCRIPT_MANAGED_SKIP_VERIFY="true"; else SCRIPT_MANAGED_SKIP_VERIFY="false"; fi
    local dns_val; dns_val=$(echo "$exec_start_line" | grep -oP -- '-dns\s+\K[^ ]+'); if [[ -n "$dns_val" ]]; then SCRIPT_MANAGED_CUSTOM_DNS="$dns_val"; fi
}

_commit_service_config_and_restart() {
    echo "正在更新 ddns-go 服务配置..."
    mkdir -p "$(dirname "$DDNS_GO_SERVICE_FILE")"
    local new_exec_start_line="ExecStart=$DDNS_GO_INSTALL_PATH/ddns-go"
    if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then new_exec_start_line+=" -l :$SCRIPT_MANAGED_WEB_PORT"; fi
    if [ -n "$SCRIPT_MANAGED_SYNC_INTERVAL" ]; then new_exec_start_line+=" -f $SCRIPT_MANAGED_SYNC_INTERVAL"; fi
    if [ -n "$SCRIPT_MANAGED_CACHE_TIMES" ]; then new_exec_start_line+=" -cacheTimes $SCRIPT_MANAGED_CACHE_TIMES"; fi
    new_exec_start_line+=" -c $DDNS_GO_CONFIG_FILE" 
    if [ "$SCRIPT_MANAGED_SKIP_VERIFY" = "true" ]; then new_exec_start_line+=" -skipVerify"; fi
    if [ -n "$SCRIPT_MANAGED_CUSTOM_DNS" ]; then new_exec_start_line+=" -dns $SCRIPT_MANAGED_CUSTOM_DNS"; fi
    if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "false" ]; then new_exec_start_line+=" -noweb"; fi
    local escaped_new_exec_start_line=$(echo "$new_exec_start_line" | sed -e 's/\\/\\\\/g')
    if [ ! -f "$DDNS_GO_SERVICE_FILE" ]; then
      cat > "$DDNS_GO_SERVICE_FILE" << EOF
[Unit]
Description=DDNS-GO Dynamic DNS Client
Documentation=https://github.com/$DDNS_GO_REPO
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$DDNS_GO_INSTALL_PATH
ExecStart=placeholder
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
      echo "  创建了基础服务文件。"
    fi
    sed -i "\#^ExecStart=#c\\${escaped_new_exec_start_line}" "$DDNS_GO_SERVICE_FILE"
    if [ $? -ne 0 ]; then echo "错误: 更新服务文件 $DDNS_GO_SERVICE_FILE 失败。" >&2; return 1; fi
    echo "  服务文件已更新为: ${new_exec_start_line}"
    systemctl daemon-reload
    if [ $? -ne 0 ]; then echo "错误: systemctl daemon-reload 失败。" >&2; fi
    echo "  启用 ddns-go 服务 (如果尚未启用)..."; systemctl enable ddns-go > /dev/null 2>&1
    echo "  重启 ddns-go 服务..."; systemctl restart ddns-go; local restart_status=$?; sleep 1
    if [ $restart_status -eq 0 ] && systemctl is-active --quiet ddns-go; then echo "  ddns-go 服务已成功配置并 (重)启动。"; else
        echo "错误：(重)启动 ddns-go 服务失败 (退出码: $restart_status)。" >&2
        echo "  请检查服务文件: cat /etc/systemd/system/ddns-go.service" >&2
        echo "  并查看详细日志: journalctl -u ddns-go.service -n 50 --no-pager" >&2
        echo "  以及: systemctl status ddns-go.service --no-pager" >&2
    fi
    _read_and_set_current_service_config_vars ; return $restart_status
}

init_arch() {
  if [ -z "$ARCH" ]; then
    local detected_arch_key=""
    local raw_arch_dpkg=""
    local raw_arch_uname=""

    raw_arch_dpkg=$(dpkg --print-architecture 2>/dev/null)

    if [ -n "$raw_arch_dpkg" ]; then
        case "$raw_arch_dpkg" in
            amd64) detected_arch_key="x86_64" ;;
            arm64) detected_arch_key="arm64" ;;
            armhf) detected_arch_key="armv7" ;; 
            armel) detected_arch_key="armv5" ;; 
            i386) detected_arch_key="i386" ;;
            mips) detected_arch_key="mips" ;;
            mipsel) detected_arch_key="mipsle" ;;
            mips64) detected_arch_key="mips64" ;; 
            mips64el) detected_arch_key="mips64le" ;;
            *) detected_arch_key="$raw_arch_dpkg" ;; 
        esac
    fi

    if [ -z "$detected_arch_key" ]; then 
        raw_arch_uname=$(uname -m)
        case "$raw_arch_uname" in
            x86_64) detected_arch_key="x86_64" ;;
            aarch64) detected_arch_key="arm64" ;;
            armv7l) detected_arch_key="armv7" ;;
            armv6l) detected_arch_key="armv6" ;; 
            armv5tel | armv5l) detected_arch_key="armv5" ;;
            i686) detected_arch_key="i386" ;;
            i386) detected_arch_key="i386" ;;
            mips) detected_arch_key="mips" ;;
            mipsel) detected_arch_key="mipsle" ;;
            mips64) detected_arch_key="mips64" ;; 
            mips64el) detected_arch_key="mips64le" ;;
            *) detected_arch_key="$raw_arch_uname" ;; 
        esac
    fi
    ARCH="$detected_arch_key"

    if [ -z "$ARCH" ]; then
      echo "警告（内部）：init_arch 未能确定一个有效的架构关键字。" >&2
    fi
  fi
}

is_ddns_go_installed() {
  if [ -f "$DDNS_GO_INSTALL_PATH/ddns-go" ] && [ -f "$DDNS_GO_SERVICE_FILE" ] && grep -q "ExecStart=$DDNS_GO_INSTALL_PATH/ddns-go" "$DDNS_GO_SERVICE_FILE" 2>/dev/null; then return 0 ; 
  elif [ -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then return 0 ; fi
  return 1
}

ensure_dependencies() {
  echo "检查并安装必要的工具 (curl, tar, jq)..."
  NEEDS_INSTALL=0
  for pkg in curl tar jq; do
    if ! dpkg -s "$pkg" > /dev/null 2>&1 && ! command -v "$pkg" > /dev/null 2>&1; then NEEDS_INSTALL=1; echo "  工具 $pkg 未安装。"; break; fi
  done
  if [ $NEEDS_INSTALL -eq 1 ]; then
    echo "  正在更新软件包列表并安装缺失的工具..."
    if command -v apt > /dev/null 2>&1; then apt update > /dev/null 2>&1; if ! apt install -y curl tar jq > /dev/null 2>&1; then echo "错误：使用 apt 安装工具失败。" >&2; return 1; fi
    elif command -v yum > /dev/null 2>&1; then if ! yum install -y curl tar jq > /dev/null 2>&1; then echo "错误：使用 yum 安装工具失败。" >&2; return 1; fi
    elif command -v dnf > /dev/null 2>&1; then if ! dnf install -y curl tar jq > /dev/null 2>&1; then echo "错误：使用 dnf 安装工具失败。" >&2; return 1; fi
    else echo "错误: 未知的包管理器。请手动安装 curl, tar, jq。" >&2; return 1; fi
    echo "  必要的工具已成功安装。"
  else echo "  所有必要的工具均已安装。" ; fi
  return 0
}

uninstall_ddns_go() {
  local preserve_config=${1:-false} 
  local temp_backup_path_for_uninstall="/tmp/.ddns_go_config.yaml.bak-uninstall-$(date +%s)"
  echo "开始彻底卸载 ddns-go..."; BACKED_UP_CONFIG_PATH=""
  if [ "$preserve_config" = "true" ] && [ -f "$DDNS_GO_CONFIG_FILE" ]; then
    echo "  请求保留配置文件。正在备份 $DDNS_GO_CONFIG_FILE 到 $temp_backup_path_for_uninstall..."
    cp "$DDNS_GO_CONFIG_FILE" "$temp_backup_path_for_uninstall"
    if [ $? -ne 0 ]; then echo "  警告: 备份配置文件失败！" >&2; else echo "  配置文件已成功临时备份。"; BACKED_UP_CONFIG_PATH="$temp_backup_path_for_uninstall"; fi
  fi
  SERVICE_BASENAME=$(basename "$DDNS_GO_SERVICE_FILE")
  if systemctl list-unit-files | grep -q "^${SERVICE_BASENAME}"; then echo "  停止并禁用 ddns-go 服务..."; systemctl stop "${SERVICE_BASENAME}" > /dev/null 2>&1; systemctl disable "${SERVICE_BASENAME}" > /dev/null 2>&1;
  else echo "  ddns-go 服务未找到或未激活。" ; fi
  if [ -f "$DDNS_GO_SERVICE_FILE" ]; then echo "  删除 systemd 服务文件..."; rm -f "$DDNS_GO_SERVICE_FILE"; fi
  echo "  重新加载 systemd 配置..."; systemctl daemon-reload >/dev/null 2>&1
  if crontab -l 2>/dev/null | grep -qE "$UPDATE_SCRIPT_PATH|$CRON_COMMENT_TAG"; then echo "  从 crontab 中删除自动更新任务..."; (crontab -l 2>/dev/null | grep -vE "$UPDATE_SCRIPT_PATH|$CRON_COMMENT_TAG") | crontab - ;
  else echo "  未在 crontab 中找到自动更新任务。" ; fi
  OLD_CRON_FILE="/etc/cron.d/ddns-go-update" ; if [ -f "$OLD_CRON_FILE" ]; then echo "  删除旧的 cron 文件 $OLD_CRON_FILE..."; rm -f "$OLD_CRON_FILE"; fi
  if [ -d "$DDNS_GO_INSTALL_PATH" ]; then echo "  删除安装目录: $DDNS_GO_INSTALL_PATH"; rm -rf "$DDNS_GO_INSTALL_PATH"; if [ $? -eq 0 ]; then echo "  目录已成功删除。"; else echo "  错误：删除目录失败。" >&2; fi
  else echo "  安装目录 $DDNS_GO_INSTALL_PATH 未找到。" ; fi
  echo "ddns-go 彻底卸载完成。"
}

install_ddns_go_core() {
  init_arch 
  if [ -z "$ARCH" ]; then echo "错误：无法确定系统架构，无法继续安装核心文件。" >&2; return 1; fi
  echo "正在获取最新的 ddns-go 版本信息 (目标架构: $ARCH)..."
  LATEST_RELEASE_API_URL="https://api.github.com/repos/$DDNS_GO_REPO/releases/latest"
  LATEST_RELEASE_INFO=$(curl -sL --connect-timeout 10 --retry 3 "$LATEST_RELEASE_API_URL")
  if [ -z "$LATEST_RELEASE_INFO" ] || echo "$LATEST_RELEASE_INFO" | jq -e '.message == "Not Found" or .message | test("API rate limit exceeded")' > /dev/null 2>&1 ; then
    echo "错误：无法获取最新版本信息 (API限流或仓库未找到)。响应: $LATEST_RELEASE_INFO" >&2; return 1; fi

  DOWNLOAD_URL=""
  JQ_FILTER_STD='.assets[] | select(.name | test("^ddns-go_.*_linux_" + $arch + "\\.tar\\.gz$")) | .browser_download_url'
  DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_STD" | head -n 1)

  if [ -z "$DOWNLOAD_URL" ] && [[ "$ARCH" == mips* ]]; then 
    echo "  标准过滤器未找到 '$ARCH' 直匹配文件，尝试MIPS特定后缀..."
    JQ_FILTER_MIPS_HF='.assets[] | select(.name | test("^ddns-go_.*_linux_" + $arch + "_hardfloat\\.tar\\.gz$")) | .browser_download_url'
    DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_MIPS_HF" | head -n 1)
    if [ -z "$DOWNLOAD_URL" ]; then
      JQ_FILTER_MIPS_SF='.assets[] | select(.name | test("^ddns-go_.*_linux_" + $arch + "_softfloat\\.tar\\.gz$")) | .browser_download_url'
      DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_MIPS_SF" | head -n 1)
      if [ -n "$DOWNLOAD_URL" ]; then echo "  找到MIPS Softfloat版本。" ; fi
    elif [ -n "$DOWNLOAD_URL" ]; then echo "  找到MIPS Hardfloat版本。" ; fi
  fi
  
  if [ -z "$DOWNLOAD_URL" ]; then
    echo "  主要过滤器未找到匹配，尝试通用后备过滤器..."
    JQ_FILTER_FALLBACK='.assets[] | select(.name | test("linux_" + $arch + "\\.tar\\.gz$") and (.name | contains("ddns-go"))) | .browser_download_url'
    DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_FALLBACK" | head -n 1)

    if [ -z "$DOWNLOAD_URL" ] && [[ "$ARCH" == mips* ]]; then 
        echo "  通用后备过滤器未找到 '$ARCH' 直匹配文件，尝试MIPS特定后缀的后备过滤器..."
        JQ_FILTER_MIPS_FALLBACK_HF='.assets[] | select(.name | test("linux_" + $arch + "_hardfloat\\.tar\\.gz$") and (.name | contains("ddns-go"))) | .browser_download_url'
        DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_MIPS_FALLBACK_HF" | head -n 1)
        if [ -z "$DOWNLOAD_URL" ]; then
            JQ_FILTER_MIPS_FALLBACK_SF='.assets[] | select(.name | test("linux_" + $arch + "_softfloat\\.tar\\.gz$") and (.name | contains("ddns-go"))) | .browser_download_url'
            DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r --arg arch "$ARCH" "$JQ_FILTER_MIPS_FALLBACK_SF" | head -n 1)
            if [ -n "$DOWNLOAD_URL" ]; then echo "  找到MIPS Softfloat版本 (后备)。" ; fi
        elif [ -n "$DOWNLOAD_URL" ]; then echo "  找到MIPS Hardfloat版本 (后备)。" ; fi
    fi
  fi

  if [ -z "$DOWNLOAD_URL" ]; then echo "错误：未找到适用于 linux $ARCH 架构的 ddns-go 下载链接。可用资源:" >&2; echo "$LATEST_RELEASE_INFO" | jq -r '.assets[].name' >&2; return 1; fi
  echo "  找到下载链接：$DOWNLOAD_URL"
  LATEST_VERSION_TAG=$(echo "$LATEST_RELEASE_INFO" | jq -r '.tag_name'); LATEST_VERSION=${LATEST_VERSION_TAG#v}
  if [ -z "$LATEST_VERSION" ]; then echo "错误: 无法解析最新版本标签。" >&2; return 1; fi
  echo "  准备安装 ddns-go 版本 $LATEST_VERSION..."; mkdir -p "$DDNS_GO_INSTALL_PATH"; cd "$DDNS_GO_INSTALL_PATH" || { echo "错误：无法进入目录"; return 1; }
  echo "  正在下载 ddns-go..."; curl -L -o ddns-go.tar.gz "$DOWNLOAD_URL" --connect-timeout 20 --retry 3
  if [ $? -ne 0 ]; then echo "错误：下载 ddns-go 失败。" >&2; return 1; fi
  echo "  正在解压 ddns-go..."; rm -f "$DDNS_GO_INSTALL_PATH/ddns-go" 
  tar -xzf ddns-go.tar.gz -C "$DDNS_GO_INSTALL_PATH" ddns-go 2>/dev/null
  if [ ! -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then
      BINARY_PATH_IN_ARCHIVE=$(tar -tzf ddns-go.tar.gz | grep -E '/ddns-go$|^ddns-go$' | head -n 1)
      if [ -n "$BINARY_PATH_IN_ARCHIVE" ]; then echo "  检测到二进制文件位于: $BINARY_PATH_IN_ARCHIVE, 尝试提取..."; tar -xzf ddns-go.tar.gz -C "$DDNS_GO_INSTALL_PATH" --strip-components=$(echo "$BINARY_PATH_IN_ARCHIVE" | awk -F/ '{print NF-1}') "$BINARY_PATH_IN_ARCHIVE"; fi
  fi
  if [ ! -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then echo "错误：解压失败，未找到执行文件。" >&2; rm -f ddns-go.tar.gz; return 1; fi
  rm -f ddns-go.tar.gz; chmod +x "$DDNS_GO_INSTALL_PATH/ddns-go"; echo "ddns-go 版本 $LATEST_VERSION 安装成功。"
  return 0
}

_configure_auto_update_cronjob() {
  local minute="$1"; local hour="$2"; local day_of_week="$3"
  init_arch 
  if [ -z "$ARCH" ]; then echo "错误(配置更新): 无法确定架构。"; return 1; fi
  mkdir -p "$(dirname "$UPDATE_SCRIPT_PATH")"
cat > "$UPDATE_SCRIPT_PATH" << EOF
#!/bin/bash
LOG_FILE="$DDNS_GO_UPDATE_LOG_FILE"
INSTALL_PATH="$DDNS_GO_INSTALL_PATH"
DDNS_GO_EXEC="\$INSTALL_PATH/ddns-go"
REPO="$DDNS_GO_REPO"

get_target_arch_for_update() {
  local detected_arch_key=""
  local raw_arch_dpkg=\$(dpkg --print-architecture 2>/dev/null)
  if [ -n "\$raw_arch_dpkg" ]; then
      case "\$raw_arch_dpkg" in
          amd64) detected_arch_key="x86_64" ;; arm64) detected_arch_key="arm64" ;;
          armhf) detected_arch_key="armv7" ;; armel) detected_arch_key="armv5" ;;
          i386) detected_arch_key="i386" ;; mips) detected_arch_key="mips" ;;
          mipsel) detected_arch_key="mipsle" ;; mips64) detected_arch_key="mips64" ;;
          mips64el) detected_arch_key="mips64le" ;; *) detected_arch_key="\$raw_arch_dpkg" ;;
      esac
  fi
  if [ -z "\$detected_arch_key" ]; then 
      local raw_arch_uname=\$(uname -m)
      case "\$raw_arch_uname" in
          x86_64) detected_arch_key="x86_64" ;; aarch64) detected_arch_key="arm64" ;;
          armv7l) detected_arch_key="armv7" ;; armv6l) detected_arch_key="armv6" ;;
          armv5tel | armv5l) detected_arch_key="armv5" ;;
          i686) detected_arch_key="i386" ;; i386) detected_arch_key="i386" ;;
          mips) detected_arch_key="mips" ;; mipsel) detected_arch_key="mipsle" ;;
          mips64) detected_arch_key="mips64" ;; mips64el) detected_arch_key="mips64le" ;;
          *) detected_arch_key="\$raw_arch_uname" ;; 
      esac
  fi
  echo "\$detected_arch_key"
}
TARGET_ARCH=\$(get_target_arch_for_update)
if [ -z "\$TARGET_ARCH" ]; then printf "错误(更新脚本): 无法确定目标架构。\n"; echo "错误(更新脚本): 无法确定目标架构。" >> \$LOG_FILE; exit 1; fi

echo "----------------------------------------------------" >> \$LOG_FILE
echo "开始检查 ddns-go 更新 (\$(date)) for arch \$TARGET_ARCH" >> \$LOG_FILE
if [ ! -x "\$DDNS_GO_EXEC" ]; then printf "错误: ddns-go 执行文件 %s 未找到或不可执行。\n" "\$DDNS_GO_EXEC"; echo "错误: \$DDNS_GO_EXEC 未找到或不可执行。" >> \$LOG_FILE; exit 1; fi

CURRENT_VERSION_RAW=\$("\$DDNS_GO_EXEC" -v 2>&1 | grep -oE '[v]?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
if [ -z "\$CURRENT_VERSION_RAW" ]; then printf "错误: 无法从 %s -v 的输出解析当前版本号。\n" "\$DDNS_GO_EXEC"; echo "错误: 无法解析当前版本号。" >> \$LOG_FILE; exit 1; fi
CURRENT_VERSION=\${CURRENT_VERSION_RAW#v}
echo "ddns-go -v command output for version check: [\$CURRENT_VERSION_RAW]" >> \$LOG_FILE

LATEST_RELEASE_API_URL="https://api.github.com/repos/\$REPO/releases/latest"
LATEST_RELEASE_INFO=\$(curl -sL --connect-timeout 10 --retry 3 "\$LATEST_RELEASE_API_URL")
if [ -z "\$LATEST_RELEASE_INFO" ] || echo "\$LATEST_RELEASE_INFO" | jq -e '.message=="Not Found" or .message|test("API rate limit exceeded")' >/dev/null 2>&1; then
  printf "错误: 无法获取最新的 ddns-go 版本信息 (可能是API限流或仓库不存在)。\n"
  echo "错误: 无法获取最新版本信息. API响应: \$LATEST_RELEASE_INFO" >> \$LOG_FILE; exit 1; fi

DOWNLOAD_URL=""
JQ_FILTER_STD='.assets[] | select(.name | test("^ddns-go_.*_linux_" + \$arch + "\\\\.tar\\\\.gz\$")) | .browser_download_url'
DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_STD" | head -n 1)

if [ -z "\$DOWNLOAD_URL" ] && [[ "\$TARGET_ARCH" == mips* ]]; then
  echo "  (日志) 标准过滤器未找到 '\$TARGET_ARCH' 直匹配文件，尝试MIPS特定后缀..." >> \$LOG_FILE
  JQ_FILTER_MIPS_HF='.assets[] | select(.name | test("^ddns-go_.*_linux_" + \$arch + "_hardfloat\\\\.tar\\\\.gz\$")) | .browser_download_url'
  DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_MIPS_HF" | head -n 1)
  if [ -z "\$DOWNLOAD_URL" ]; then
    JQ_FILTER_MIPS_SF='.assets[] | select(.name | test("^ddns-go_.*_linux_" + \$arch + "_softfloat\\\\.tar\\\\.gz\$")) | .browser_download_url'
    DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_MIPS_SF" | head -n 1)
  fi
fi

if [ -z "\$DOWNLOAD_URL" ]; then
  echo "  (日志) 主要过滤器未找到匹配，尝试通用后备过滤器..." >> \$LOG_FILE
  JQ_FILTER_FALLBACK='.assets[] | select(.name | test("linux_" + \$arch + "\\\\.tar\\\\.gz\$") and (.name | contains("ddns-go"))) | .browser_download_url'
  DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_FALLBACK" | head -n 1)
  if [ -z "\$DOWNLOAD_URL" ] && [[ "\$TARGET_ARCH" == mips* ]]; then
      echo "  (日志) MIPS通用后备过滤器未找到，尝试MIPS特定后缀的后备..." >> \$LOG_FILE
      JQ_FILTER_MIPS_FALLBACK_HF='.assets[] | select(.name | test("linux_" + \$arch + "_hardfloat\\\\.tar\\\\.gz\$") and (.name | contains("ddns-go"))) | .browser_download_url'
      DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_MIPS_FALLBACK_HF" | head -n 1)
      if [ -z "\$DOWNLOAD_URL" ]; then
          JQ_FILTER_MIPS_FALLBACK_SF='.assets[] | select(.name | test("linux_" + \$arch + "_softfloat\\\\.tar\\\\.gz\$") and (.name | contains("ddns-go"))) | .browser_download_url'
          DOWNLOAD_URL=\$(echo "\$LATEST_RELEASE_INFO" | jq -r --arg arch "\$TARGET_ARCH" "\$JQ_FILTER_MIPS_FALLBACK_SF" | head -n 1)
      fi
  fi
fi

if [ -z "\$DOWNLOAD_URL" ]; then printf "错误: 未找到适用于 %s 架构的 ddns-go 下载链接。\n" "\$TARGET_ARCH"; echo "错误: 未找到适用于 \$TARGET_ARCH 的下载链接。" >> \$LOG_FILE; echo "可用资源:" >> \$LOG_FILE; echo "\$LATEST_RELEASE_INFO" | jq -r '.assets[].name' >> \$LOG_FILE; exit 1; fi
LATEST_VERSION_TAG=\$(echo "\$LATEST_RELEASE_INFO" | jq -r '.tag_name'); LATEST_VERSION=\${LATEST_VERSION_TAG#v}
if [ -z "\$LATEST_VERSION" ]; then printf "错误: 无法从API响应中解析最新版本标签。\n"; echo "错误: 无法解析最新版本标签。" >> \$LOG_FILE; exit 1; fi

echo "当前版本: \$CURRENT_VERSION, 最新版本: \$LATEST_VERSION" >> \$LOG_FILE
if [ "\$CURRENT_VERSION" == "\$LATEST_VERSION" ]; then 
  printf "ddns-go 程序已是最新版本 (v%s)。\n" "\$CURRENT_VERSION"
  echo "ddns-go 已是最新版 (v\$CURRENT_VERSION)。" >> \$LOG_FILE; 
  if ! systemctl is-active --quiet ddns-go && [ -f "/etc/systemd/system/ddns-go.service" ]; then 
    echo "  服务未运行，尝试启动..." >> \$LOG_FILE; 
    systemctl start ddns-go >> \$LOG_FILE 2>&1; 
  fi; 
  exit 0; 
fi

printf "发现新版 ddns-go v%s (当前 v%s)，开始更新...\n" "\$LATEST_VERSION" "\$CURRENT_VERSION"
echo "发现新版 v\$LATEST_VERSION (当前 v\$CURRENT_VERSION)，开始更新..." >> \$LOG_FILE

if systemctl is-active --quiet ddns-go; then 
  echo "  正在停止 ddns-go 服务..." >> \$LOG_FILE; 
  systemctl stop ddns-go >> \$LOG_FILE 2>&1; 
  if [ \$? -ne 0 ]; then echo "警告: 停止服务失败，仍尝试更新。" >> \$LOG_FILE; else echo "  服务已停止。" >> \$LOG_FILE; fi
fi
cd "\$INSTALL_PATH" || { printf "错误：无法进入安装目录 %s\n" "\$INSTALL_PATH"; echo "错误: 无法进入目录 \$INSTALL_PATH" >> \$LOG_FILE; exit 1; }

if [ -f "\$DDNS_GO_EXEC" ]; then 
  echo "  备份当前 ddns-go 执行文件..." >> \$LOG_FILE;
  mv "\$DDNS_GO_EXEC" "\$DDNS_GO_EXEC.old" >> \$LOG_FILE 2>&1; 
fi

echo "  正在下载新版本从 \$DOWNLOAD_URL..." >> \$LOG_FILE 
curl -L -o ddns-go.tar.gz "\$DOWNLOAD_URL" --connect-timeout 20 --retry 3
if [ \$? -ne 0 ]; then 
  printf "错误：下载新版本 ddns-go 失败。\n"
  echo "错误: 下载失败。" >> \$LOG_FILE; 
  if [ -f "\$DDNS_GO_EXEC.old" ]; then echo "  尝试恢复旧版本..." >> \$LOG_FILE; mv "\$DDNS_GO_EXEC.old" "\$DDNS_GO_EXEC" >> \$LOG_FILE 2>&1; fi; 
  echo "  尝试重启 ddns-go 服务(下载失败后)..." >> \$LOG_FILE; systemctl start ddns-go >> \$LOG_FILE 2>&1; exit 1; 
fi

echo "  正在解压新版本..." >> \$LOG_FILE 
rm -f "\$INSTALL_PATH/ddns-go"
tar -xzf ddns-go.tar.gz -C "\$INSTALL_PATH" ddns-go 2>/dev/null
if [ ! -f "\$INSTALL_PATH/ddns-go" ]; then
    BINARY_PATH_IN_ARCHIVE=\$(tar -tzf ddns-go.tar.gz | grep -E '/ddns-go$|^ddns-go$' | head -n 1)
    if [ -n "\$BINARY_PATH_IN_ARCHIVE" ]; then 
      echo "  检测到压缩包内路径: \$BINARY_PATH_IN_ARCHIVE, 尝试提取..." >> \$LOG_FILE
      tar -xzf ddns-go.tar.gz -C "\$INSTALL_PATH" --strip-components=\$(echo "\$BINARY_PATH_IN_ARCHIVE" | awk -F/ '{print NF-1}') "\$BINARY_PATH_IN_ARCHIVE" >> \$LOG_FILE 2>&1; 
    fi
fi

if [ ! -f "\$DDNS_GO_EXEC" ]; then 
  printf "错误：解压新版本 ddns-go 后未找到执行文件。\n"
  echo "错误: 解压后未找到执行文件。" >> \$LOG_FILE; rm -f ddns-go.tar.gz; 
  if [ -f "\$DDNS_GO_EXEC.old" ]; then echo "  尝试恢复旧版本..." >> \$LOG_FILE; mv "\$DDNS_GO_EXEC.old" "\$DDNS_GO_EXEC" >> \$LOG_FILE 2>&1; fi; 
  echo "  尝试重启 ddns-go 服务(解压失败后)..." >> \$LOG_FILE; systemctl start ddns-go >> \$LOG_FILE 2>&1; exit 1; 
fi
rm -f ddns-go.tar.gz; chmod +x "\$DDNS_GO_EXEC"

NEW_INSTALLED_VERSION_RAW=\$("\$DDNS_GO_EXEC" -v 2>&1 | grep -oE '[v]?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
NEW_INSTALLED_VERSION=\${NEW_INSTALLED_VERSION_RAW#v}

printf "ddns-go 已成功更新到版本 v%s。正在重启服务...\n" "\$NEW_INSTALLED_VERSION"
echo "更新完成。新版本已安装 (v\$NEW_INSTALLED_VERSION)。正在重启服务..." >> \$LOG_FILE

systemctl start ddns-go >> \$LOG_FILE 2>&1 
if systemctl is-active --quiet ddns-go; then 
  echo "服务已成功重启。" >> \$LOG_FILE; 
  if [ -f "\$DDNS_GO_EXEC.old" ]; then rm -f "\$DDNS_GO_EXEC.old"; fi
else 
  printf "错误：ddns-go 更新后服务重启失败。\n"
  echo "错误: 服务重启失败。" >> \$LOG_FILE; 
  if [ -f "\$DDNS_GO_EXEC.old" ]; then echo "  检测到旧版本备份 \$DDNS_GO_EXEC.old，可尝试手动恢复。" >> \$LOG_FILE; fi; 
fi
exit 0
EOF
  chmod +x "$UPDATE_SCRIPT_PATH"
  (crontab -l 2>/dev/null | grep -vF "$UPDATE_SCRIPT_PATH" | grep -vF "$CRON_COMMENT_TAG") | crontab -
  CRON_JOB_LINE="${minute} ${hour} * * ${day_of_week} $UPDATE_SCRIPT_PATH >> \"$DDNS_GO_UPDATE_LOG_FILE\" 2>&1" 
  (crontab -l 2>/dev/null ; echo "$CRON_JOB_LINE # $CRON_COMMENT_TAG") | crontab - 
  local schedule_desc="每天 ${hour}:${minute}"; if [ "$day_of_week" != "*" ]; then local days=("周日" "周一" "周二" "周三" "周四" "周五" "周六"); if [[ "$day_of_week" =~ ^[0-6]$ ]]; then schedule_desc="每周${days[$day_of_week]} ${hour}:${minute}"; else schedule_desc="每周 (无效星期: $day_of_week) ${hour}:${minute}"; fi; fi
  echo "  自动更新任务已配置为 ${schedule_desc} 执行。"
  echo "  更新脚本: $UPDATE_SCRIPT_PATH"; echo "  更新日志: $DDNS_GO_UPDATE_LOG_FILE"
  return 0
}

handle_install() {
  echo "--- 安装 ddns-go ---"
  if is_ddns_go_installed; then 
    echo "ddns-go 已安装。建议使用“重新安装 ddns-go”选项来更新或修复安装。"
    echo "“重新安装”选项会询问您是否保留现有的 YAML 配置文件和特定服务参数。"
    local choice_reinstall; read -r -p "是否要切换到“重新安装”流程? (Y/n): " choice_reinstall
    if [[ "$choice_reinstall" =~ ^[Yy]$ ]] || [ -z "$choice_reinstall" ]; then handle_reinstall; return; fi
    echo "选择不进行重新安装。如果您希望进行全新的覆盖安装（不保留 YAML 配置文件），请确认。"
    local choice_fresh; read -r -p "继续进行全新安装 (将删除现有服务和配置文件)? (y/N): " choice_fresh
    if ! [[ "$choice_fresh" =~ ^[Yy]$ ]]; then echo "安装已取消。"; return; fi
    echo "正在准备全新安装..."; uninstall_ddns_go false 
  fi
  if ! ensure_dependencies; then return 1; fi
  SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; SCRIPT_MANAGED_WEB_ENABLED="true"
  SCRIPT_MANAGED_SYNC_INTERVAL="$DDNS_GO_DEFAULT_SYNC_INTERVAL"; SCRIPT_MANAGED_CACHE_TIMES=""
  SCRIPT_MANAGED_SKIP_VERIFY="false"; SCRIPT_MANAGED_CUSTOM_DNS=""
  local port_input; read -r -p "请输入 ddns-go Web 服务端口号 (1-65535, 回车默认 $SCRIPT_MANAGED_WEB_PORT): " port_input
  SCRIPT_MANAGED_WEB_PORT=${port_input:-$SCRIPT_MANAGED_WEB_PORT} 
  if ! [[ "$SCRIPT_MANAGED_WEB_PORT" =~ ^[0-9]+$ && "$SCRIPT_MANAGED_WEB_PORT" -ge 1 && "$SCRIPT_MANAGED_WEB_PORT" -le 65535 ]]; then echo "错误：无效端口。使用默认 $DEFAULT_WEB_PORT。"; SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; fi
  if ! install_ddns_go_core; then return 1; fi; if ! _commit_service_config_and_restart; then return 1; fi
  echo "配置默认自动更新任务..."; if ! _configure_auto_update_cronjob "$DEFAULT_UPDATE_MINUTE" "$DEFAULT_UPDATE_HOUR" "$DEFAULT_UPDATE_DAY_OF_WEEK"; then echo "警告：自动更新配置失败。"; fi
  echo "----------------------------------------------------"; echo "ddns-go 安装和初始配置完成！ Web 服务端口 $SCRIPT_MANAGED_WEB_PORT。"; echo "请通过 Web 界面 http://<您的IP>:$SCRIPT_MANAGED_WEB_PORT 配置域名和DNS服务商。"; handle_status
}

handle_reinstall() {
  echo "--- 重新安装 ddns-go ---"
  local preserve_yaml_choice="y"; local preserve_service_params_choice="y"; local proceed_due_to_not_installed=false 
  if is_ddns_go_installed; then 
      read -r -p "是否保留 YAML 配置文件 (.ddns_go_config.yaml)？此文件主要包含您的【域名列表、DNS服务商(如阿里云/腾讯云/Cloudflare等)的API密钥、Webhook通知、TTL值】等核心DDNS配置。(Y/n): " yaml_in
      preserve_yaml_choice=${yaml_in:-Y} 
      read -r -p "是否保留服务启动参数 (如Web端口, 同步间隔等 - 来自 .service 文件)? (Y/n): " service_in
      preserve_service_params_choice=${service_in:-Y} 
  else echo "未检测到已安装。将按全新安装流程处理配置。"; preserve_yaml_choice="n"; preserve_service_params_choice="n"; proceed_due_to_not_installed=true; fi

  if [[ "$preserve_service_params_choice" =~ ^[Yy]$ ]]; then if [ "$proceed_due_to_not_installed" = "false" ]; then echo "尝试加载并保留现有服务参数..."; fi; _read_and_set_current_service_config_vars ;
  else echo "使用脚本默认服务参数..."; SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; SCRIPT_MANAGED_WEB_ENABLED="true"; SCRIPT_MANAGED_SYNC_INTERVAL="$DDNS_GO_DEFAULT_SYNC_INTERVAL"; SCRIPT_MANAGED_CACHE_TIMES=""; SCRIPT_MANAGED_SKIP_VERIFY="false"; SCRIPT_MANAGED_CUSTOM_DNS="";
    if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then local port_in_re; read -r -p "请输入Web端口 (新服务配置, 1-65535, 回车默认 $SCRIPT_MANAGED_WEB_PORT): " port_in_re; SCRIPT_MANAGED_WEB_PORT=${port_in_re:-$SCRIPT_MANAGED_WEB_PORT}; if ! [[ "$SCRIPT_MANAGED_WEB_PORT" =~ ^[0-9]+$ && "$SCRIPT_MANAGED_WEB_PORT" -ge 1 && "$SCRIPT_MANAGED_WEB_PORT" -le 65535 ]]; then echo "错误:无效端口。使用默认$DEFAULT_WEB_PORT。"; SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; fi; fi; fi
  if [ "$proceed_due_to_not_installed" = "false" ]; then if [[ "$preserve_yaml_choice" =~ ^[Yy]$ ]]; then echo "卸载旧版 (尝试保留YAML)..."; uninstall_ddns_go true; else echo "卸载旧版 (不保留YAML)..."; uninstall_ddns_go false; fi; echo ""; else BACKED_UP_CONFIG_PATH=""; fi
  if ! ensure_dependencies; then return 1; fi; if ! install_ddns_go_core; then if [ -n "$BACKED_UP_CONFIG_PATH" ] && [ -f "$BACKED_UP_CONFIG_PATH" ]; then echo "错误:核心文件安装失败。备份的YAML仍在: $BACKED_UP_CONFIG_PATH" >&2; fi; return 1; fi
  if [[ "$preserve_yaml_choice" =~ ^[Yy]$ ]]; then if [ -n "$BACKED_UP_CONFIG_PATH" ] && [ -f "$BACKED_UP_CONFIG_PATH" ]; then echo "  恢复YAML配置..."; mkdir -p "$(dirname "$DDNS_GO_CONFIG_FILE")"; cp "$BACKED_UP_CONFIG_PATH" "$DDNS_GO_CONFIG_FILE"; if [ $? -eq 0 ]; then echo "  YAML恢复成功。"; rm -f "$BACKED_UP_CONFIG_PATH"; else echo "  错误:YAML恢复失败! 文件仍在 $BACKED_UP_CONFIG_PATH" >&2; fi; elif [ "$proceed_due_to_not_installed" = "false" ]; then echo "  选择保留YAML但未找到有效备份。"; fi
  else echo "  选择不保留YAML。"; if [ -n "$BACKED_UP_CONFIG_PATH" ] && [ -f "$BACKED_UP_CONFIG_PATH" ]; then rm -f "$BACKED_UP_CONFIG_PATH"; fi; BACKED_UP_CONFIG_PATH=""; fi
  if ! _commit_service_config_and_restart; then return 1; fi
  echo "检查自动更新任务..."; local cron_exists; if crontab -l 2>/dev/null | grep -qF "$UPDATE_SCRIPT_PATH"; then cron_exists="true"; else cron_exists="false"; fi
  if [ "$cron_exists" = "false" ]; then echo "  未找到更新任务，配置默认。"; if ! _configure_auto_update_cronjob "$DEFAULT_UPDATE_MINUTE" "$DEFAULT_UPDATE_HOUR" "$DEFAULT_UPDATE_DAY_OF_WEEK"; then echo "警告:自动更新配置失败。"; fi; else echo "  检测到已存在更新任务，跳过。"; fi
  echo "----------------------------------------------------"; echo "ddns-go 重新安装完成！"; if [[ "$preserve_yaml_choice" =~ ^[Yy]$ ]]; then echo "  - YAML配置文件已尝试恢复。"; else echo "  - YAML配置文件未恢复。"; fi; if [[ "$preserve_service_params_choice" =~ ^[Yy]$ ]]; then echo "  - 服务参数已从旧配置或默认值应用。"; else echo "  - 服务参数已使用脚本默认值应用。"; fi; echo "  - 请检查状态及Web界面 (端口: $SCRIPT_MANAGED_WEB_PORT)。"; handle_status; BACKED_UP_CONFIG_PATH="" 
}

handle_uninstall() {
  echo "--- 彻底卸载 ddns-go ---"; if ! is_ddns_go_installed; then echo "ddns-go 未安装。"; return; fi
  read -r -p "这将彻底删除 ddns-go 及其所有配置和日志 (YAML不保留)。确定吗? (y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then uninstall_ddns_go false; else echo "卸载已取消。"; fi
}

handle_status() {
  echo "--- ddns-go 状态检查 ---"; _read_and_set_current_service_config_vars 
  if ! is_ddns_go_installed && ! [ -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then echo "ddns-go 未安装或程序文件不存在。"; return; fi
  SERVICE_BASENAME=$(basename "$DDNS_GO_SERVICE_FILE"); local web_access_url_status="Web服务配置异常或已禁用"
  if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then SERVER_IP_STATUS=$(get_public_ip); if [ -z "$SERVER_IP_STATUS" ]; then SERVER_IP_STATUS="<你的IP>"; fi; web_access_url_status="http://${SERVER_IP_STATUS}:${SCRIPT_MANAGED_WEB_PORT}"; fi
  echo "Web 界面访问 (基于服务配置): $web_access_url_status"
  if [ -f "$DDNS_GO_SERVICE_FILE" ] && systemctl list-unit-files | grep -q "^${SERVICE_BASENAME}"; then
    echo "服务状态 ($SERVICE_BASENAME):"; systemctl status "$SERVICE_BASENAME" --no-pager -n 15; echo ""
    if systemctl is-active --quiet "$SERVICE_BASENAME"; then local running_cmd; running_cmd=$(systemctl show -p MainPID ${SERVICE_BASENAME} | sed 's/MainPID=//' | xargs -I {} --no-run-if-empty ps -o cmd= -p {} 2>/dev/null || ps -o cmd= -p $(systemctl show -p MainPID ${SERVICE_BASENAME} | sed 's/MainPID=//') 2>/dev/null) ; echo "服务正在运行。"; if [ -n "$running_cmd" ]; then echo "  实际运行命令: $running_cmd"; else echo "  无法获取实际运行命令。"; fi
    else echo "服务未在运行。" ; fi
  elif [ -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then echo "服务文件($DDNS_GO_SERVICE_FILE)未找到，但程序存在。可能安装不完整。"; else echo "ddns-go程序或服务文件均未找到。"; fi
  echo "YAML配置文件: $DDNS_GO_CONFIG_FILE"; if [ -f "$DDNS_GO_CONFIG_FILE" ]; then echo "  状态: 存在"; else echo "  状态: 未找到"; fi
  echo "程序日志: $DDNS_GO_LOG_FILE"; echo "安装路径: $DDNS_GO_INSTALL_PATH"
  echo "程序自动更新状态:"; if [ -f "$UPDATE_SCRIPT_PATH" ]; then echo "  更新脚本: $UPDATE_SCRIPT_PATH"; CRON_JOB=$(crontab -l 2>/dev/null | grep -F "$UPDATE_SCRIPT_PATH" | grep -F "$CRON_COMMENT_TAG"); if [ -n "$CRON_JOB" ]; then echo "  定时任务: $CRON_JOB"; else echo "  未找到自动更新任务。"; fi; echo "  更新日志: $DDNS_GO_UPDATE_LOG_FILE"; else echo "  自动更新脚本未配置。"; fi
}

handle_set_sync_interval() {
  _read_and_set_current_service_config_vars; echo "--- 配置同步间隔 (-f) ---"; echo "当前: ${SCRIPT_MANAGED_SYNC_INTERVAL} 秒"
  read -r -p "新间隔 (秒, 例如300, 回车不改): " interval_input
  if [ -n "$interval_input" ]; then if [[ "$interval_input" =~ ^[0-9]+$ && "$interval_input" -gt 0 ]]; then SCRIPT_MANAGED_SYNC_INTERVAL="$interval_input"; if _commit_service_config_and_restart; then echo "间隔更新为 ${SCRIPT_MANAGED_SYNC_INTERVAL} 秒。"; else echo "错误:更新失败。"; fi; else echo "错误:无效输入。"; fi; else echo "未修改。"; fi
}

handle_set_cache_times() {
  _read_and_set_current_service_config_vars; echo "--- 配置比对频率 (-cacheTimes) ---"; echo "当前: ${SCRIPT_MANAGED_CACHE_TIMES:-未设置}"
  read -r -p "新频率 (整数, 或 'clear' 清除, 回车不改): " cache_input
  if [ -n "$cache_input" ]; then if [[ "$cache_input" =~ ^[0-9]+$ && "$cache_input" -ge 0 ]]; then SCRIPT_MANAGED_CACHE_TIMES="$cache_input"; if _commit_service_config_and_restart; then echo "频率更新为 ${SCRIPT_MANAGED_CACHE_TIMES}。"; else echo "错误:更新失败。"; fi
  elif [ "$cache_input" == "clear" ]; then SCRIPT_MANAGED_CACHE_TIMES=""; if _commit_service_config_and_restart; then echo "频率设置已清除。"; else echo "错误:清除失败。"; fi; else echo "错误:无效输入。"; fi; else echo "未修改。"; fi
}

handle_toggle_skip_verify() {
  _read_and_set_current_service_config_vars; echo "--- 配置跳过TLS验证 (-skipVerify) ---"
  local cur_stat="关闭 (执行验证)"; if [ "$SCRIPT_MANAGED_SKIP_VERIFY" = "true" ]; then cur_stat="开启 (跳过验证)"; fi; echo "当前: $cur_stat"
  local choice_txt="开启 (跳过验证)"; if [ "$SCRIPT_MANAGED_SKIP_VERIFY" = "true" ]; then choice_txt="关闭 (执行验证)"; fi
  read -r -p "切换为 '$choice_txt' 吗? (y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then if [ "$SCRIPT_MANAGED_SKIP_VERIFY" = "true" ]; then SCRIPT_MANAGED_SKIP_VERIFY="false"; else SCRIPT_MANAGED_SKIP_VERIFY="true"; fi
    if _commit_service_config_and_restart; then local new_stat="关闭"; if [ "$SCRIPT_MANAGED_SKIP_VERIFY" = "true" ]; then new_stat="开启"; fi; echo "跳过TLS验证更新为: $new_stat"; else echo "错误:更新失败。"; fi; else echo "操作取消。"; fi
}

handle_set_custom_dns() {
  _read_and_set_current_service_config_vars; echo "--- 配置自定义DNS (-dns) ---"; echo "当前: ${SCRIPT_MANAGED_CUSTOM_DNS:-未设置}"
  read -r -p "新DNS服务器 (例如8.8.8.8, 或 'clear', 回车不改): " dns_input
  if [ -n "$dns_input" ]; then if [ "$dns_input" == "clear" ]; then SCRIPT_MANAGED_CUSTOM_DNS=""; if _commit_service_config_and_restart; then echo "自定义DNS已清除。"; else echo "错误:清除失败。"; fi
  else if [[ "$dns_input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$dns_input" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then SCRIPT_MANAGED_CUSTOM_DNS="$dns_input"; if _commit_service_config_and_restart; then echo "自定义DNS更新为 ${SCRIPT_MANAGED_CUSTOM_DNS}。"; else echo "错误:更新失败。"; fi; else echo "错误:无效DNS格式。"; fi; fi; else echo "未修改。"; fi
}

handle_reset_web_password() {
  echo "--- 重置Web界面密码 ---"; if ! [ -f "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then echo "错误: ddns-go程序未找到。"; return 1; fi
  if [ ! -f "$DDNS_GO_CONFIG_FILE" ]; then echo "错误: YAML配置文件 $DDNS_GO_CONFIG_FILE 未找到。"; return 1; fi
  local new_pwd new_pwd_confirm; read -r -s -p "新密码: " new_pwd; echo ""; if [ -z "$new_pwd" ]; then echo "密码不能为空。取消。"; return; fi
  read -r -s -p "确认新密码: " new_pwd_confirm; echo ""; if [ "$new_pwd" != "$new_pwd_confirm" ]; then echo "密码不一致。取消。"; return; fi
  echo "准备重置..."; local svc_active=false; if systemctl is-active --quiet ddns-go; then svc_active=true; echo "  临时停止服务..."; if ! systemctl stop ddns-go; then echo "错误:停止服务失败。"; return 1; fi; sleep 1; fi
  echo "  执行重置命令..."; if [ ! -x "$DDNS_GO_INSTALL_PATH/ddns-go" ]; then chmod +x "$DDNS_GO_INSTALL_PATH/ddns-go"; fi
  "$DDNS_GO_INSTALL_PATH/ddns-go" -resetPassword "$new_pwd" -c "$DDNS_GO_CONFIG_FILE"; local reset_stat=$?
  if [ "$svc_active" = "true" ]; then echo "  重启服务..."; systemctl start ddns-go; fi
  if [ $reset_stat -eq 0 ]; then echo "密码重置指令已发送。新密码 '$new_pwd'。请尝试登录确认。"; else echo "错误:密码重置失败(码: $reset_stat)。检查日志。"; if [ "$svc_active" = true ] && ! systemctl is-active --quiet ddns-go; then echo "警告:服务重置后未自动重启。" >&2; fi; fi
}

customize_auto_update_schedule() {
  echo "--- 配置程序自动更新计划 ---"; if ! is_ddns_go_installed || ! [ -f "$UPDATE_SCRIPT_PATH" ]; then echo "ddns-go或更新脚本未安装。"; return; fi
  CURRENT_CRON_JOB=$(crontab -l 2>/dev/null | grep -F "$UPDATE_SCRIPT_PATH" | grep -F "$CRON_COMMENT_TAG"); CRON_MINUTE=$DEFAULT_UPDATE_MINUTE; CRON_HOUR=$DEFAULT_UPDATE_HOUR; CRON_DOW=$DEFAULT_UPDATE_DAY_OF_WEEK 
  if [ -n "$CURRENT_CRON_JOB" ]; then CRON_MINUTE=$(echo "$CURRENT_CRON_JOB"|awk '{print $1}'); CRON_HOUR=$(echo "$CURRENT_CRON_JOB"|awk '{print $2}'); CRON_DOW=$(echo "$CURRENT_CRON_JOB"|awk '{print $5}');fi 
  local sched_desc="每天 ${CRON_HOUR}:${CRON_MINUTE}"; if [ "$CRON_DOW" != "*" ]; then local days=("日" "一" "二" "三" "四" "五" "六"); if [[ "$CRON_DOW" =~ ^[0-6]$ ]]; then sched_desc="每周${days[$CRON_DOW]} ${CRON_HOUR}:${CRON_MINUTE}"; fi; fi; echo "当前计划: $sched_desc"
  local freq_c new_dow_in new_hr_in new_min_in new_dow="*" new_hr="$CRON_HOUR" new_min="$CRON_MINUTE"
  local def_freq="1"; if [ "$CRON_DOW" != "*" ] && [[ "$CRON_DOW" =~ ^[0-6]$ ]]; then def_freq="2"; fi
  read -r -p "更新周期 [1]每日 [2]每周 (默认: $def_freq): " freq_c; freq_c=${freq_c:-$def_freq}
  if [ "$freq_c" == "2" ]; then local def_dow="3"; if [[ "$CRON_DOW" =~ ^[0-6]$ ]]; then def_dow="$CRON_DOW"; fi; read -r -p "星期几(0日..6六,默认:$def_dow): " new_dow_in; new_dow=${new_dow_in:-$def_dow}; if ! [[ "$new_dow" =~ ^[0-6]$ ]]; then echo "无效星期,用周三"; new_dow="3"; fi; else new_dow="*"; fi
  read -r -p "小时(0-23,默认:$CRON_HOUR): " new_hr_in; new_hr=${new_hr_in:-$CRON_HOUR}
  read -r -p "分钟(0-59,默认:$CRON_MINUTE): " new_min_in; new_min=${new_min_in:-$CRON_MINUTE}
  if ! [[ "$new_hr" =~ ^([0-9]|1[0-9]|2[0-3])$ && "$new_min" =~ ^([0-9]|[1-5][0-9])$ ]]; then echo "错误:时间无效。"; return; fi
  local new_sched_desc="每天 ${new_hr}:${new_min}"; if [ "$new_dow" != "*" ]; then local days_n=("日" "一" "二" "三" "四" "五" "六"); new_sched_desc="每周${days_n[$new_dow]} ${new_hr}:${new_min}"; fi
  echo "配置新计划为: $new_sched_desc..."; if _configure_auto_update_cronjob "$new_min" "$new_hr" "$new_dow"; then echo "计划已修改。"; else echo "错误:修改失败。"; fi
}

handle_run_program_update_now() {
  echo "--- 立即更新ddns-go程序 ---"
  if ! is_ddns_go_installed; then echo "ddns-go 未安装。"; return; fi
  if [ ! -f "$UPDATE_SCRIPT_PATH" ]; then
    echo "错误: 更新脚本 $UPDATE_SCRIPT_PATH 未找到。请先配置自动更新或重新安装。"
    return
  fi
  if [ ! -x "$UPDATE_SCRIPT_PATH" ]; then
    echo "错误: 更新脚本 $UPDATE_SCRIPT_PATH 不可执行。尝试修复..."
    chmod +x "$UPDATE_SCRIPT_PATH"
    if [ ! -x "$UPDATE_SCRIPT_PATH" ]; then
        echo "修复失败。请检查文件权限。"
        return
    fi
  fi

  local update_output
  local update_status

  echo "执行更新脚本: $UPDATE_SCRIPT_PATH" 
  echo "更新日志将记录到: $DDNS_GO_UPDATE_LOG_FILE"
  
  update_output=$(bash "$UPDATE_SCRIPT_PATH" 2>&1) 
  update_status=$?

  echo "" 
  echo "更新脚本输出:" 
  if [ -n "$update_output" ]; then 
    printf "%s\n" "$update_output" 
  else 
    if [ $update_status -eq 0 ]; then
        echo "(更新脚本执行成功，但无直接控制台输出。请检查日志。)"
    else
        echo "(更新脚本无标准输出/错误输出，且执行失败)"
    fi
  fi
  echo "------------------------" 
 
  if [ $update_status -eq 0 ]; then
    if [ -z "$update_output" ]; then 
        echo "提示: 更新脚本执行完毕 (退出码0)，无明确状态输出。请检查日志。"
    fi
  else 
    echo "错误: 更新脚本执行时遇到问题 (退出状态码: $update_status)。请检查以上输出和日志。"
  fi

  echo "详细日志亦可查阅: tail -n 30 $DDNS_GO_UPDATE_LOG_FILE"
  echo "" 
}

handle_toggle_web_service() { 
  _read_and_set_current_service_config_vars; echo "--- 管理Web服务 ---"
  local choice; if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then echo "当前Web服务已启用 (端口: $SCRIPT_MANAGED_WEB_PORT)。"; read -r -p "要禁用吗 (加-noweb)? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then SCRIPT_MANAGED_WEB_ENABLED="false"; if _commit_service_config_and_restart; then echo "Web服务已禁用。"; else echo "错误:禁用失败。"; fi; else echo "操作取消。"; fi
  else echo "当前Web服务已禁用 (-noweb)。"; read -r -p "要启用吗 (端口 $SCRIPT_MANAGED_WEB_PORT)? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then SCRIPT_MANAGED_WEB_ENABLED="true"; if ! [[ "$SCRIPT_MANAGED_WEB_PORT" =~ ^[0-9]+$ && "$SCRIPT_MANAGED_WEB_PORT" -ge 1 && "$SCRIPT_MANAGED_WEB_PORT" -le 65535 ]]; then SCRIPT_MANAGED_WEB_PORT="$DEFAULT_WEB_PORT"; echo "警告:端口重置为默认$DEFAULT_WEB_PORT。"; fi
      if _commit_service_config_and_restart; then echo "Web服务已启用 (端口 $SCRIPT_MANAGED_WEB_PORT)。"; else echo "错误:启用失败。"; fi; else echo "操作取消。"; fi; fi; echo ""; 
}

handle_change_web_port() { 
  _read_and_set_current_service_config_vars; echo "--- 更改Web服务端口 ---"
  if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "false" ]; then echo "警告:Web服务禁用中。新端口将在启用后生效。当前配置端口(若启用): $SCRIPT_MANAGED_WEB_PORT"; else echo "当前Web端口: $SCRIPT_MANAGED_WEB_PORT"; fi
  local new_port_in; read -r -p "新端口 (1-65535, 回车取消): " new_port_in; if [ -z "$new_port_in" ]; then echo "操作取消。"; return; fi
  if ! [[ "$new_port_in" =~ ^[0-9]+$ && "$new_port_in" -ge 1 && "$new_port_in" -le 65535 ]]; then echo "错误:无效端口。取消。"; return; fi
  SCRIPT_MANAGED_WEB_PORT="$new_port_in"; echo "配置Web端口为 $SCRIPT_MANAGED_WEB_PORT..."
  if _commit_service_config_and_restart; then echo "端口已配置。"; else echo "错误:配置失败。"; fi; echo ""; 
}

main_menu() {
  init_arch 
  _read_and_set_current_service_config_vars 

  clear
  echo "======================================"
  echo "    ddns-go 管理脚本 (v2.2.1)"
  echo "======================================"
  echo " ddns-go 当前启动配置 (来自服务文件):" 

  local web_status_text_param="已启用"
  if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "false" ]; then web_status_text_param="已禁用 (-noweb)"; fi
  echo "   Web 服务状态: $web_status_text_param"

  local display_port_param="$SCRIPT_MANAGED_WEB_PORT"
  if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "false" ]; then display_port_param="N/A"; fi
  echo "   Web 监听端口 (-l): $display_port_param"

  echo "   同步间隔 (-f): ${SCRIPT_MANAGED_SYNC_INTERVAL} 秒"
  echo "   比对频率 (-cacheTimes): ${SCRIPT_MANAGED_CACHE_TIMES:-未设置}"
  echo "   跳过TLS验证 (-skipVerify): ${SCRIPT_MANAGED_SKIP_VERIFY}"
  echo "   自定义DNS (-dns): ${SCRIPT_MANAGED_CUSTOM_DNS:-未设置}"
  echo "--------------------------------------" 
  echo "请选择操作:"
  echo "  1. 安装 ddns-go"
  echo "  2. 重新安装 ddns-go" 
  echo "  3. 彻底卸载 ddns-go"
  echo "  4. 检查 ddns-go 状态"
  
  local opt_num=5
  local web_service_option_text="管理 ddns-go Web 服务" 
  if [ -f "$DDNS_GO_SERVICE_FILE" ]; then 
    if [ "$SCRIPT_MANAGED_WEB_ENABLED" = "true" ]; then web_service_option_text="禁用 ddns-go Web 服务 (当前服务配置: 开)";
    else web_service_option_text="启用 ddns-go Web 服务 (当前服务配置: 关)"; fi
  fi

  echo "  $opt_num. $web_service_option_text"; local toggle_web_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 更改 ddns-go Web 服务端口"; local change_port_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 配置同步间隔 (-f)"; local set_f_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 配置服务商比对频率 (-cacheTimes)"; local set_ct_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 切换TLS证书验证 (-skipVerify)"; local toggle_sv_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 配置自定义DNS服务器 (-dns)"; local set_dns_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 重置Web界面密码"; local reset_pwd_opt_num=$opt_num; ((opt_num++)) 
  echo "  $opt_num. 配置ddns-go程序自动更新计划"; local config_autoupdate_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 立即更新ddns-go程序"; local run_update_now_opt_num=$opt_num; ((opt_num++))
  echo "  $opt_num. 退出脚本"; local exit_opt_num=$opt_num
  echo "--------------------------------------"
  read -r -p "请输入选项数字 [1-$exit_opt_num]: " choice

  case "$choice" in
    1) handle_install ;; 2) handle_reinstall ;; 3) handle_uninstall ;; 4) handle_status ;;
    "$toggle_web_opt_num") handle_toggle_web_service ;; "$change_port_opt_num") handle_change_web_port ;;
    "$set_f_opt_num") handle_set_sync_interval ;; "$set_ct_opt_num") handle_set_cache_times ;;
    "$toggle_sv_opt_num") handle_toggle_skip_verify ;; "$set_dns_opt_num") handle_set_custom_dns ;;
    "$reset_pwd_opt_num") handle_reset_web_password ;; "$config_autoupdate_opt_num") customize_auto_update_schedule ;;
    "$run_update_now_opt_num") handle_run_program_update_now ;; "$exit_opt_num") echo "正在退出脚本..."; exit 0 ;;
    *) echo "无效选项 '$choice'，请输入有效数字。" ;;
  esac
  
  if [[ "$choice" -ne "$exit_opt_num" ]]; then press_enter_to_continue; fi
}

check_root
while true; do main_menu; done
