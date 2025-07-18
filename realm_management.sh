#!/bin/bash








SCRIPT_NAME="Realm 管理脚本"

SCRIPT_VERSION="2.3"



RESET=$'\033[0m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
PURPLE=$'\033[0;35m'
TITLE_COLOR=$'\033[0;37m'
CYAN=$'\033[0;36m'
LIGHT_GREEN=$'\033[1;32m'
LIGHT_RED=$'\033[1;31m'



SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PYTHON_EXECUTOR_SCRIPT="${SCRIPT_DIR}/realm_management_py_executor.sh"
PYTHON_INSTALLER_SCRIPT="${SCRIPT_DIR}/install_python.sh"
UPDATE_SCRIPT_PATH="${SCRIPT_DIR}/update_script.sh"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
MANAGER_SETTINGS_FILE="${SCRIPT_DIR}/.realm_management_script_config.conf"
VENV_PATH="${SCRIPT_DIR}/.venv"
REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_DIR="/etc/realm"
REALM_CONFIG_FILE=""
REALM_CONFIG_TYPE=""
REALM_SERVICE_FILE="/etc/systemd/system/realm.service"
GITHUB_BASE_URL="https://github.com"


DAEMON_SERVICE_FILE="/etc/systemd/system/realm_health_check.service"

DAEMON_CONFIG_FILE="${REALM_CONFIG_DIR}/daemon.conf"
DAEMON_SCRIPT_PATH="${SCRIPT_DIR}/health_checker_daemon.py"
DEFAULT_PING_SCRIPT_PATH="${SCRIPT_DIR}/ping_check.sh"

DEFAULT_TCP_PING_SCRIPT_PATH="${SCRIPT_DIR}/tcp_ping_check.sh"
VALIDATOR_SCRIPT_PATH="${SCRIPT_DIR}/validator.py"
HEALTH_CHECK_CONFIG_FILE="${REALM_CONFIG_DIR}/health_checks.conf"
HEALTH_CHECK_LOG_FILE="/var/log/realm_health_check.log"
STATE_BACKUP_FILE="${SCRIPT_DIR}/state.backup.json"

DAEMON_PID_FILE="/var/run/realm_health_check_daemon.pid"





_log() {
    local type="$1"
    local msg="$2"
    case "$type" in
        info)
            echo -e "${CYAN}[INFO]${RESET} $msg"
            ;;
        warn)
            echo -e "${YELLOW}[WARN]${RESET} $msg"
            ;;
        err)
            echo -e "${RED}[ERROR]${RESET} $msg"
            ;;
        succ)
            echo -e "${GREEN}[SUCCESS]${RESET} $msg"
            ;;
    esac
}


initialize_settings() {
    touch "$MANAGER_SETTINGS_FILE"

    if ! grep -q "^REALM_CONFIG_DIR=" "$MANAGER_SETTINGS_FILE" 2>/dev/null; then
        _log info "未找到 Realm 配置目录设置，将使用默认值: /etc/realm"
        echo "REALM_CONFIG_DIR=\"/etc/realm\"" >> "$MANAGER_SETTINGS_FILE"
    fi
}


load_manager_settings() {
    if [[ -f "$MANAGER_SETTINGS_FILE" ]]; then
        source "$MANAGER_SETTINGS_FILE"

        DAEMON_CONFIG_FILE="${REALM_CONFIG_DIR}/daemon.conf"
        HEALTH_CHECK_CONFIG_FILE="${REALM_CONFIG_DIR}/health_checks.conf"
    fi
}


detect_config_file() {
    if [[ -n "$REALM_CONFIG_FILE" && -f "$REALM_CONFIG_FILE" ]]; then
        return
    fi

    local toml_file="${REALM_CONFIG_DIR}/config.toml"
    local json_file="${REALM_CONFIG_DIR}/config.json"

    if [[ -f "$toml_file" ]]; then
        REALM_CONFIG_FILE="$toml_file"
        REALM_CONFIG_TYPE="toml"
    elif [[ -f "$json_file" ]]; then
        REALM_CONFIG_FILE="$json_file"
        REALM_CONFIG_TYPE="json"
    else
        REALM_CONFIG_FILE="$toml_file"
        REALM_CONFIG_TYPE="toml"
    fi
}


check_root() {
    if [[ $EUID -ne 0 ]]; then
        _log err "此脚本需要root权限运行。请使用 'sudo ./realm_management.sh' 运行。"
        exit 1
    fi
}


takeover_running_realm() {
    local running_process
    running_process=$(pgrep -af "realm")
    
    if [[ -n "$running_process" ]]; then
        local config_path
        config_path=$(echo "$running_process" | grep -oP '(-c|--config)\s+\K[^\s]+' | head -n 1)

        if [[ -n "$config_path" && -f "$config_path" ]]; then
            local running_config_dir
            running_config_dir=$(dirname "$(realpath "$config_path")")
            
            if [[ "$running_config_dir" != "$REALM_CONFIG_DIR" ]]; then
                _log warn "检测到正在运行的 Realm 实例，其配置目录与当前脚本设置不同！"
                echo "  - 正在运行的实例配置: $config_path"
                echo "  - 当前脚本管理目录: $REALM_CONFIG_DIR"
                
                read -e -p "是否接管此Realm实例的配置? [Y/n]: " choice
                choice=${choice:-Y}
                
                if [[ "$choice" == "Y" ]] || [[ "$choice" == "y" ]]; then
                    _log info "正在将管理配置从 $REALM_CONFIG_DIR 迁移到 $running_config_dir..."
                    
                    [[ -f "${REALM_CONFIG_DIR}/health_checks.conf" ]] && mv "${REALM_CONFIG_DIR}/health_checks.conf" "${running_config_dir}/"
                    [[ -f "${REALM_CONFIG_DIR}/daemon.conf" ]] && mv "${REALM_CONFIG_DIR}/daemon.conf" "${running_config_dir}/"

                    sed -i "s|^REALM_CONFIG_DIR=.*|REALM_CONFIG_DIR=\"$running_config_dir\"|" "$MANAGER_SETTINGS_FILE"
                    
                    _log succ "已接管配置并迁移了相关设置。脚本将重新加载。"
                    sleep 2
                    exec "$0" "$@"
                else
                    _log info "用户取消接管。将继续使用当前管理目录: $REALM_CONFIG_DIR"
                fi
            fi
        fi
    fi
}


check_dependencies() {
    _log info "正在检查所有依赖 (Python环境和系统命令)..."
    
    if ! bash "$PYTHON_EXECUTOR_SCRIPT" init_env; then
        _log err "Python 环境初始化失败。请检查来自执行器脚本的错误消息。"
        exit 1
    fi
    
    local missing_cmds=()

    local required_cmds=(
        "awk" "bash" "cat" "chmod" "clear" "command" "curl" "cut"
        "date" "dirname" "echo" "eval" "exec" "find" "file" "grep"
        "head" "kill" "mkdir" "mv" "nohup" "ping" "pgrep" "ps"
        "read" "readarray" "realpath" "rm" "sed" "sleep" "ss"
        "source" "sort" "systemctl" "tail" "tar" "tee" "timeout"
        "touch" "tr" "uname" "wc" "mktemp"
    )
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        _log warn "检测到缺失的系统命令: ${missing_cmds[*]}"
        read -e -p "是否尝试自动安装这些依赖? [Y/n]: " choice
        choice=${choice:-Y}
        if [[ "$choice" != "Y" ]] && [[ "$choice" != "y" ]]; then
            _log err "用户拒绝安装依赖，脚本退出。"
            exit 1
        fi

        local pm=""
        if command -v "apt-get" &>/dev/null; then
            pm="apt"
        elif command -v "yum" &>/dev/null; then
            pm="yum"
        elif command -v "dnf" &>/dev/null; then
            pm="dnf"
        elif command -v "pacman" &>/dev/null; then
            pm="pacman"
        elif command -v "apk" &>/dev/null; then
            pm="apk"
        fi

        if [[ -z "$pm" ]]; then
            _log err "无法检测到支持的包管理器，请手动安装: ${missing_cmds[*]}"
            exit 1
        fi

        local packages_to_install=()
        for cmd in "${missing_cmds[@]}"; do
            case "$cmd" in
                awk) packages_to_install+=("gawk");;
                ss) packages_to_install+=("iproute2");;
                ping|timeout)
                    if [[ "$pm" == "apk" ]]; then packages_to_install+=("iputils");
                    elif [[ "$pm" == "pacman" ]]; then packages_to_install+=("inetutils");
                    else packages_to_install+=("inetutils-ping" "coreutils"); fi;;
                realpath|cat|chmod|clear|cut|date|dirname|echo|find|head|mkdir|mv|rm|sleep|sort|tail|touch|tr|uname|wc|mktemp)
                    packages_to_install+=("coreutils");;
                ps|kill|pgrep) packages_to_install+=("procps");;
                file) packages_to_install+=("file");;
                *) packages_to_install+=("$cmd");;
            esac
        done

        packages_to_install=($(echo "${packages_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        _log info "将要安装的包: ${packages_to_install[*]}"
        
        local install_cmd_str
        if [[ "$pm" == "apt" ]]; then install_cmd_str="apt-get update && apt-get install -y"
        elif [[ "$pm" == "yum" || "$pm" == "dnf" ]]; then install_cmd_str="$pm makecache && $pm install -y"
        elif [[ "$pm" == "pacman" ]]; then install_cmd_str="pacman -Sy --noconfirm"
        elif [[ "$pm" == "apk" ]]; then install_cmd_str="apk update && apk add"
        fi

        _log info "正在执行安装命令..."
        eval "${install_cmd_str} ${packages_to_install[*]}"

        for cmd in "${missing_cmds[@]}"; do
            if ! command -v "$cmd" &>/dev/null; then
                _log err "依赖 '$cmd' 安装失败或未被完全安装。请手动处理后重试。"
                exit 1
            fi
        done
    fi
    _log succ "所有依赖检查完成。"
}


check_python_dependency() {
    if [ ! -d "$VENV_PATH" ]; then
        _log err "Python 虚拟环境目录 (.venv) 不存在。"
        _log err "请重新运行脚本以自动完成依赖检查和环境设置。"
        return 1
    fi
    return 0
}


check_helper_scripts() {
    _log info "正在检查辅助脚本文件..."
    local required_scripts=(
        "$PYTHON_EXECUTOR_SCRIPT"
        "$DAEMON_SCRIPT_PATH"
        "$DEFAULT_PING_SCRIPT_PATH"
        "$DEFAULT_TCP_PING_SCRIPT_PATH"
        "$VALIDATOR_SCRIPT_PATH"
        "$PYTHON_INSTALLER_SCRIPT"
        "$UPDATE_SCRIPT_PATH"
        "$REQUIREMENTS_FILE"
    )
    for script_path in "${required_scripts[@]}"; do
        if [[ ! -f "$script_path" ]]; then
            _log err "核心脚本文件缺失: $(basename "$script_path")"
            _log err "请确保所有脚本文件都位于同一目录下。"
            exit 1
        fi
    done

    local scripts_to_check_exec=(
        "$0" 
        "$PYTHON_EXECUTOR_SCRIPT" 
        "$DEFAULT_PING_SCRIPT_PATH" 
        "$DEFAULT_TCP_PING_SCRIPT_PATH" 
        "$UPDATE_SCRIPT_PATH"
    )
    for script_path in "${scripts_to_check_exec[@]}"; do
        if [[ ! -x "$script_path" ]]; then
            _log warn "脚本文件需要执行权限: $script_path"
            chmod +x "$script_path"
            _log succ "已自动为 $(basename "$script_path") 授予执行权限。"
        fi
    done
    _log succ "辅助脚本文件检测通过。"
}


check_github_and_get_proxy() {
    _log info "正在检测 GitHub 连接性..."
    if curl -o /dev/null -s -m 5 --head https://api.github.com; then
        _log succ "GitHub 连接正常。"
        GITHUB_BASE_URL="https://github.com"
    else
        _log warn "GitHub 连接超时或失败！"
        local default_proxy="https://ghproxy.com"
        read -e -p "请输入GitHub反代地址 [默认: ${default_proxy}]: " proxy_url
        proxy_url=${proxy_url:-$default_proxy}
        GITHUB_BASE_URL="${proxy_url}/https://github.com"
        _log info "将使用代理地址进行下载: ${GITHUB_BASE_URL}"
    fi
}


install_realm() {
    _log info "开始安装或更新 Realm..."

    if [[ -f "$REALM_BIN_PATH" ]]; then
        _log warn "Realm 似乎已安装。"
        read -e -p "是否要继续并覆盖当前版本? [y/N]: " confirm_reinstall
        if [[ "${confirm_reinstall}" != "y" && "${confirm_reinstall}" != "Y" ]]; then
            _log info "操作已取消。"
            return
        fi
        _log info "好的，将继续重新安装/更新 Realm..."
    fi

    check_github_and_get_proxy

    echo "-----------------------------------------------------"
    _log info "请选择要安装的版本:"
    echo "  1) gnu  (标准版, 兼容性好, 适用于大多数桌面/服务器系统)"
    echo "  2) musl (轻量版, 适用于容器环境或嵌入式系统)"
    echo "-----------------------------------------------------"
    read -e -p "请输入选项 [默认: 1]: " libc_choice
    libc_choice=${libc_choice:-1}

    local libc_type=""
    case "$libc_choice" in
        1) libc_type="gnu" ;;
        2) libc_type="musl" ;;
        *) _log err "无效选项, 已退出安装。"; return 1 ;;
    esac
    _log info "已选择安装 ${libc_type} 版本。"

    ARCH=$(uname -m)
    local REALM_ARCH=""
    case "$ARCH" in
        x86_64) REALM_ARCH="x86_64-unknown-linux-${libc_type}" ;;
        aarch64) REALM_ARCH="aarch64-unknown-linux-${libc_type}" ;;
        *) _log err "不支持的系统架构: $ARCH"; exit 1 ;;
    esac

    _log info "正在从 GitHub API 获取最新的版本标签..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

    if [[ -z "$LATEST_VERSION" ]]; then
        _log err "无法获取 Realm 最新版本号，请检查网络。"
        return 1
    fi
    _log succ "成功获取到最新版本: $LATEST_VERSION"

    local DOWNLOAD_URL="${GITHUB_BASE_URL}/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${REALM_ARCH}.tar.gz"
    local temp_file="/tmp/realm.tar.gz"

    _log info "正在从 $DOWNLOAD_URL 下载..."
    curl -L --connect-timeout 10 -o "$temp_file" "$DOWNLOAD_URL"

    if ! command -v file &>/dev/null || ! file "$temp_file" | grep -q "gzip compressed data"; then
        _log err "下载失败或文件类型不正确。"
        rm -f "$temp_file"
        return 1
    fi

    _log info "解压文件..."
    tar -xzf "$temp_file" -C "/tmp/"
    
    local extracted_file
    extracted_file=$(find /tmp -maxdepth 2 -type f \( -name "realm-*-unknown-linux-*" -o -name "realm" \))

    if [[ -z "$extracted_file" ]]; then
        _log err "在 /tmp 目录中未找到解压后的 realm 可执行文件。"
        rm -f "$temp_file"
        return 1
    fi
    _log info "找到文件: $extracted_file"

    if systemctl is-active --quiet realm; then
        _log info "正在停止当前运行的 Realm 服务..."
        systemctl stop realm
    fi

    _log info "安装二进制文件到 $REALM_BIN_PATH"
    mv -f "$extracted_file" "$REALM_BIN_PATH"
    chmod +x "$REALM_BIN_PATH"

    if [[ ! -f "$REALM_SERVICE_FILE" ]]; then
        mkdir -p "$REALM_CONFIG_DIR"
        detect_config_file
        if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
            _log info "创建默认配置文件: $REALM_CONFIG_FILE"
            cat > "$REALM_CONFIG_FILE" <<EOF

[log]
level = "info"
output = "/var/log/realm.log"

[[endpoints]]
listen = "0.0.0.0:10000"
remote = "127.0.0.1:20000"
EOF
        fi
        _log info "创建 systemd 服务文件..."
        cat > "$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=realm service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$REALM_BIN_PATH -c $REALM_CONFIG_FILE
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm
        _log succ "Realm ($LATEST_VERSION-$libc_type) 首次安装完成！"
    else
        _log succ "Realm 二进制文件已更新为 $LATEST_VERSION-$libc_type！"
    fi
    
    _log info "请使用主菜单中的 '启动/重启 Realm' 选项来启动服务。"
    rm -f "$temp_file"
}


uninstall_realm() {
    _log warn "这将彻底卸载 Realm！"
    read -e -p "确定吗? [y/N]: " choice
    choice=${choice:-N}
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        _log info "操作已取消。"
        return
    fi

    _log info "正在停止并禁用 Realm 服务..."
    systemctl stop realm
    systemctl disable realm


    stop_health_check_daemon

    _log info "正在删除文件..."
    rm -f "$REALM_BIN_PATH"
    rm -f "$REALM_SERVICE_FILE"

    read -e -p "是否删除所有配置文件和日志? [y/N]: " del_config
    choice=${del_config:-N}
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        _log warn "正在删除配置文件目录: $REALM_CONFIG_DIR"

        rm -rf "$REALM_CONFIG_DIR"
        
        _log warn "正在删除健康检测日志、状态文件和脚本配置文件..."
        rm -f "$HEALTH_CHECK_LOG_FILE"
        rm -f "$STATE_BACKUP_FILE"
        rm -f "$MANAGER_SETTINGS_FILE"

        rm -f "$DAEMON_SERVICE_FILE"

        rm -f "$DAEMON_PID_FILE"

        read -e -p "是否同时删除 Python 虚拟环境 (.venv)? [y/N]: " del_venv
        if [[ "$del_venv" == "y" || "$del_venv" == "Y" ]]; then
            _log warn "正在删除 Python 虚拟环境..."
            rm -rf "$VENV_PATH"
        fi
        _log succ "Realm 已被彻底卸载。"
    else
        _log succ "Realm 已卸载，但配置文件已保留。"
    fi


    systemctl daemon-reload
}



manage_config() {
    detect_config_file
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        _log info "当前不存在配置文件。"
        read -e -p "您想创建哪种格式的配置文件? (1 for .toml, 2 for .json) [默认: 1]: " format_choice
        format_choice=${format_choice:-1}
        if [[ "$format_choice" == "1" ]]; then
            REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.toml"
            _log info "将创建并编辑: $REALM_CONFIG_FILE"
        elif [[ "$format_choice" == "2" ]]; then
            REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.json"
            _log info "将创建并编辑: $REALM_CONFIG_FILE"
        else
            _log err "无效选择。"
            return
        fi
        mkdir -p "$REALM_CONFIG_DIR"
        touch "$REALM_CONFIG_FILE"
    fi
    
    _log info "当前 Realm 配置文件路径: $REALM_CONFIG_FILE"
    read -e -p "按 Enter键 使用 'vim' 编辑，或输入其它编辑器名 (如 'nano'): " editor
    editor=${editor:-vim}

    if ! command -v "$editor" &> /dev/null; then
        _log err "编辑器 '$editor' 未找到。"
        return
    fi

    "$editor" "$REALM_CONFIG_FILE"
    _log info "配置文件已保存。"

    read -e -p "是否立即检查配置并重启服务以应用更改? [Y/n]: " restart_now
    restart_now=${restart_now:-Y}
    if [[ "$restart_now" == "y" || "$restart_now" == "Y" ]]; then
        _log warn "重要提示：通过管理配置文件功能重启Realm时，默认您已修改配置文件至完整状态，"
        _log warn "将清空配置文件状态记录文件，以防止健康检测功能误恢复可能已不再使用的配置项。"
        read -e -p "您理解并确认要继续吗? [Y/n]: " confirm_clear
        confirm_clear=${confirm_clear:-Y}
        if [[ "$confirm_clear" == "y" || "$confirm_clear" == "Y" ]]; then

            check_config_and_start "" "from_manual_edit"
        else
            _log info "操作已取消。状态记录文件未被清空。"
            _log warn "您需要稍后手动重启Realm服务以应用配置更改。"
        fi
    else
        _log warn "您需要稍后手动重启Realm服务以应用配置更改。"
    fi
}


check_config_and_start() {
    local mode="$1"
    local source_action="$2"
    
    detect_config_file
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        _log err "配置文件不存在，无法操作！"
        return 1
    fi

    _log info "正在通过执行器检查配置文件有效性 (并尝试自动校正)..."
    

    local stderr_file
    stderr_file=$(mktemp)
    



    local fixed_config
    fixed_config=$(bash "$PYTHON_EXECUTOR_SCRIPT" validate_config --file "$REALM_CONFIG_FILE" --autofix 2> "$stderr_file")
    local exit_code=$?
    

    local validator_logs
    validator_logs=$(cat "$stderr_file")
    

    rm "$stderr_file"
    

    if [[ -n "$validator_logs" ]]; then
        echo "--- [校验脚本输出] ---"
        echo -e "$validator_logs"
        echo "------------------------"
    fi


    if [[ $exit_code -ne 0 ]]; then
        _log err "配置文件检查失败！请根据以上错误提示修改配置。"
        return 1
    fi


    if echo "$validator_logs" | grep -q "\[警告\]"; then
        _log warn "检测到您的配置文件中存在不规范的内容，脚本已自动校正。"
        

        if [[ "$mode" == "check_only" ]]; then
            _log info "您当前处于'仅检查'模式。以下是校正后的内容预览："
            echo "--- [校正后内容预览] ---"
            echo "$fixed_config"
            echo "--------------------------"
            _log info "如需应用更改，请使用菜单中的'管理配置文件'或'启动/重启'功能。"
            return 0
        fi

        echo "--- [校正后内容预览] ---"
        echo "$fixed_config"
        echo "--------------------------"
        read -e -p "是否要将以上自动校正的内容写入配置文件? [Y/n]: " choice
        choice=${choice:-Y}
        if [[ "$choice" == "Y" ]] || [[ "$choice" == "y" ]]; then
            _log info "正在将校正后的配置写入文件: $REALM_CONFIG_FILE"

            local tmp_write_file
            tmp_write_file=$(mktemp)
            echo "$fixed_config" > "$tmp_write_file"
            mv "$tmp_write_file" "$REALM_CONFIG_FILE"
            _log succ "配置文件已成功更新！"
        else
            _log info "用户取消操作。配置文件未被修改。"
            _log warn "为避免服务状态与配置文件不一致，将取消本次启动/重启操作。"
            return 1
        fi
    fi


    if [[ "$mode" == "check_only" ]]; then
        _log succ "配置文件检查通过，未发现问题。"
        return 0
    fi
    

    if [[ "$source_action" == "from_manual_edit" ]]; then
        if [[ -f "$STATE_BACKUP_FILE" ]]; then
            _log warn "检测到手动修改配置并重启，这将清空健康检测的状态备份。"
            > "$STATE_BACKUP_FILE"
            _log succ "状态备份文件 ($STATE_BACKUP_FILE) 已清空。"
        fi
    fi
    
    _log info "正在启动/重启 Realm 服务..."
    systemctl restart realm
    sleep 1
    _log info "当前服务状态:"
    systemctl status realm --no-pager
}


stop_realm() {
    _log info "正在停止 Realm 服务..."
    systemctl stop realm
    sleep 1
    _log info "当前服务状态:"
    systemctl status realm --no-pager
}


display_status() {
    local realm_status_text
    if systemctl is-active --quiet realm; then
        local realm_pid
        realm_pid=$(systemctl show --property MainPID --value realm 2>/dev/null)
        realm_status_text="${LIGHT_GREEN}运行中${RESET} (PID: ${realm_pid:-N/A})"
    else
        realm_status_text="${LIGHT_RED}已停止${RESET}"
    fi
    printf "  %-22s %-s\n" "${TITLE_COLOR}Realm 服务:${RESET}" "${realm_status_text}"

    printf "  %-22s %-s\n" "${TITLE_COLOR}Realm 配置:${RESET}" "${CYAN}${REALM_CONFIG_FILE:-未创建}${RESET}"

    printf "  %-22s\n" "${TITLE_COLOR}监听端口:${RESET}"
    if systemctl is-active --quiet realm; then
        local pid
        pid=$(systemctl show --property MainPID --value realm 2>/dev/null)
        if [[ -n "$pid" && "$pid" -gt 0 ]]; then
            local ports
            readarray -t ports < <(ss -tlpn "sport != :22" | grep "pid=$pid," | awk '{print $4}')
            
            if [ ${#ports[@]} -eq 0 ]; then
                printf "    %-s\n" "${YELLOW}无 (服务可能正在启动或配置有误)${RESET}"
            else
                local total_ports=${#ports[@]}
                local max_rows=5
                local num_cols=$(( (total_ports + max_rows - 1) / max_rows ))
                
                for ((i=0; i<max_rows; i++)); do
                    local row_has_content=false
                    for ((j=0; j<num_cols; j++)); do
                        if (( (j * max_rows + i) < total_ports )); then
                            row_has_content=true
                            break
                        fi
                    done

                    if [[ "$row_has_content" == true ]]; then
                        printf "    "
                        for ((j=0; j<num_cols; j++)); do
                            local index=$(( j * max_rows + i ))
                            if (( index < total_ports )); then
                                printf "%-28s" "${CYAN}${ports[index]}${RESET}"
                            fi
                        done
                        printf "\n"
                    fi
                done
            fi
        else
            printf "    %-s\n" "${YELLOW}无法获取端口 (PID未找到)${RESET}"
        fi
    else
        printf "    %-s\n" "${YELLOW}未运行${RESET}"
    fi

    local daemon_status_text

    if systemctl is-active --quiet realm_health_check; then
        local daemon_pid
        daemon_pid=$(systemctl show --property MainPID --value realm_health_check 2>/dev/null)
        daemon_status_text="${LIGHT_GREEN}运行中 (systemd 服务)${RESET} (PID: ${daemon_pid:-N/A})"

    elif [[ -f "$DAEMON_PID_FILE" ]] && ps -p "$(cat "$DAEMON_PID_FILE")" > /dev/null; then
        local daemon_pid
        daemon_pid=$(cat "$DAEMON_PID_FILE")
        daemon_status_text="${YELLOW}运行中 (旧版 PID 文件)${RESET} (PID: ${daemon_pid})"

    elif systemctl is-enabled --quiet realm_health_check; then
        daemon_status_text="${YELLOW}已停止 (但已启用)${RESET}"

    else
        daemon_status_text="${LIGHT_RED}已停止${RESET}"
    fi
    printf "  %-22s %-s\n" "${TITLE_COLOR}健康检测服务:${RESET}" "${daemon_status_text}"

    printf "  %-22s %-s\n" "${TITLE_COLOR}健康检测日志:${RESET}" "${CYAN}tail -f ${HEALTH_CHECK_LOG_FILE}${RESET}"
}


parse_upstreams_from_config() {
    detect_config_file
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        return
    fi
    bash "$PYTHON_EXECUTOR_SCRIPT" parse_upstreams "$REALM_CONFIG_FILE"
}


modify_upstream_state() {
    local address="$1"
    local action="$2"

    _log info "通过执行器调用 Python 核心逻辑处理配置文件..."
    if ! bash "$PYTHON_EXECUTOR_SCRIPT" modify_state "$action" "$address" "$REALM_CONFIG_FILE" "$STATE_BACKUP_FILE"; then
        _log err "配置文件修改失败，请检查 Python 脚本输出。"
    fi
}


run_manual_health_check() {
    local line_to_check=$1 
    if [[ ! -s "$HEALTH_CHECK_CONFIG_FILE" ]]; then
        _log warn "没有已配置的健康检测。"
        return
    fi

    local checks_to_run
    if [[ -n "$line_to_check" ]]; then
        checks_to_run=$(sed -n "${line_to_check}p" "$HEALTH_CHECK_CONFIG_FILE")
    else
        checks_to_run=$(cat "$HEALTH_CHECK_CONFIG_FILE")
    fi

    (
        echo -e "\n--- [手动检测] Manual Check Executed: $(date) ---"
        declare -A failed_upstreams
        declare -A recovered_upstreams
        
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                continue
            fi
            
            local upstream_addr
            upstream_addr=$(echo "$line" | cut -d'=' -f1)
            
            local script_path
            script_path=$(echo "$line" | cut -d'=' -f2-)
            
            echo -e "\n${CYAN}正在检测: ${upstream_addr}${RESET}"
            
            local host=""
            local port=""
            if [[ $upstream_addr =~ ^\[(.+)\]:(.+) ]]; then
                host=${BASH_REMATCH[1]}
                port=${BASH_REMATCH[2]}
            elif [[ $upstream_addr =~ ^([^:]+):([^:]+)$ ]]; then
                host=${BASH_REMATCH[1]}
                port=${BASH_REMATCH[2]}
            else
                host=$upstream_addr
            fi
            
            timeout 10 "$script_path" "$host" "$port"
            local exit_code=$?
            
            if [[ $exit_code -eq 0 ]]; then
                echo -e "${GREEN}  -> 检测结果: 正常 (退出码: 0)${RESET}"
                if [[ -f "$STATE_BACKUP_FILE" ]] && grep -qF "\"${upstream_addr}\"" "$STATE_BACKUP_FILE" &>/dev/null; then
                    recovered_upstreams["$upstream_addr"]=1
                fi
            else
                echo -e "${RED}  -> 检测结果: 异常 (退出码: ${exit_code})${RESET}"
                failed_upstreams["$upstream_addr"]=1
            fi
        done <<< "$checks_to_run"

        echo "-------------------------------------"
        local config_modified=false
        
        if [ ${#recovered_upstreams[@]} -gt 0 ]; then
            _log succ "检测到已恢复的节点，是否要立即在配置文件中启用它们?"
            read -e -p "请输入 [Y/n] 进行确认: " apply_choice
            if [[ ${apply_choice:-Y} =~ ^[Yy]$ ]]; then
                _log info "正在应用恢复..."
                for addr in "${!recovered_upstreams[@]}"; do
                    modify_upstream_state "$addr" "enable"
                done
                config_modified=true
            else
                _log info "取消恢复操作。"
            fi
        fi

        if [ ${#failed_upstreams[@]} -gt 0 ]; then
            _log warn "检测到异常上游节点，是否要立即在配置文件中禁用它们?"
            read -e -p "请输入 [Y/n] 进行确认: " apply_choice
            if [[ ${apply_choice:-Y} =~ ^[Yy]$ ]]; then
                _log info "正在应用禁用..."
                for addr in "${!failed_upstreams[@]}"; do
                    modify_upstream_state "$addr" "disable"
                done
                config_modified=true
            else
                _log info "取消禁用操作。"
            fi
        fi

        if [[ "$config_modified" == true ]]; then
            _log info "配置已更改。是否立即重启 Realm 服务以使配置生效?"
            read -e -p "请输入 [Y/n] 进行确认: " restart_choice
            if [[ ${restart_choice:-Y} =~ ^[Yy]$ ]]; then
                check_config_and_start
            fi
        elif [ ${#recovered_upstreams[@]} -eq 0 ] && [ ${#failed_upstreams[@]} -gt 0 ]; then
            _log succ "所有检测均正常。"
        fi
    ) | tee -a "$HEALTH_CHECK_LOG_FILE"
    
    echo "-------------------------------------"
    _log info "手动检测已完成。"
    
    if ! systemctl is-active --quiet realm_health_check; then
        read -e -p "是否要开启后台守护进程以进行持续自动检测? [Y/n]: " start_daemon_choice
        if [[ ${start_daemon_choice:-Y} =~ ^[Yy]$ ]]; then
            start_or_restart_health_check_daemon
        fi
    fi
}


manage_health_checks() {
    if [[ ! -f "$DEFAULT_PING_SCRIPT_PATH" ]] || [[ ! -f "$DEFAULT_TCP_PING_SCRIPT_PATH" ]]; then
        _log err "一个或多个默认检测脚本不存在！"
        sleep 3
        return
    fi

    while true; do
        clear
        echo -e "${TITLE_COLOR}--- 健康检测管理 ---${RESET}"
        _log info "配置文件: $HEALTH_CHECK_CONFIG_FILE"
        echo "-------------------------------------"
        if [[ -s "$HEALTH_CHECK_CONFIG_FILE" ]]; then
            echo -e "${YELLOW}已配置的检测:${RESET}"
            cat -n "$HEALTH_CHECK_CONFIG_FILE"
        else
            echo "当前没有配置任何健康检测。"
        fi
        echo "-------------------------------------"

        echo "1. 添加新的上游检测"
        echo "2. 删除一个上游检测"
        echo "3. 立即执行一次检测"
        echo "0. 返回主菜单"
        read -e -p "请选择: " choice

        case "$choice" in

            1)
                detect_config_file
                local upstreams=()
                if [[ -f "$REALM_CONFIG_FILE" ]]; then

                    while IFS= read -r line; do
                        upstreams+=("$line")
                    done < <(parse_upstreams_from_config)
                fi

                if [[ ${#upstreams[@]} -eq 0 ]]; then
                    _log warn "在 $REALM_CONFIG_FILE 中未找到任何 'remote' 或 'extra_remotes' 地址。"
                    sleep 3
                    continue
                fi
                
                _log info "请从以下检测到的上游地址中选择:"

                for i in "${!upstreams[@]}"; do
                    printf "  %2d) %s\n" "$((i+1))" "${upstreams[i]}"
                done
                

                _log info "请输入要选择的地址编号，单个或多个(以空格分隔)，或输入 'all' 选择全部。"
                read -e -p "请选择: " user_choices

                local selected_indices=()
                if [[ "$user_choices" == "all" ]]; then

                    selected_indices=($(seq 1 ${#upstreams[@]}))
                else

                    read -ra selected_indices <<< "$user_choices"
                fi

                local selected_upstreams=()
                local invalid_choice=false

                for index in "${selected_indices[@]}"; do
                    if ! [[ "$index" =~ ^[1-9][0-9]*$ ]] || (( index > ${#upstreams[@]} )); then
                        _log err "输入无效: '$index'。请输入列表中的有效编号。"
                        invalid_choice=true
                        break
                    fi

                    selected_upstreams+=("${upstreams[$((index-1))]}")
                done

                if [[ "$invalid_choice" == true ]] || [[ ${#selected_upstreams[@]} -eq 0 ]]; then
                    _log warn "没有选择任何有效的上游地址。"
                    sleep 2
                    continue
                fi
                

                _log info "您已选择以下 ${#selected_upstreams[@]} 个上游地址:"
                for addr in "${selected_upstreams[@]}"; do
                    echo "  - $addr"
                done


                _log info "检测脚本要求: 退出状态码 0 表示正常, 其他所有值均视为异常。"
                echo "-------------------------------------"
                _log info "请为这些上游地址统一配置检测脚本:"
                echo "  1) ICMP Ping (ping_check.sh) - 检查网络可达性"
                echo "  2) TCP Ping  (tcp_ping_check.sh) - 检查端口可用性"
                read -e -p "请选择 [默认: 1]: " script_choice
                script_choice=${script_choice:-1}
                
                local default_script_path=""
                if [[ "$script_choice" == "1" ]]; then
                    default_script_path="$DEFAULT_PING_SCRIPT_PATH"
                elif [[ "$script_choice" == "2" ]]; then
                    default_script_path="$DEFAULT_TCP_PING_SCRIPT_PATH"
                else
                    _log err "无效选择。"
                    sleep 2
                    continue
                fi
                
                read -e -p "请输入脚本路径 [默认: $default_script_path]: " script_path
                script_path=${script_path:-$default_script_path}
                
                if [[ ! -f "$script_path" ]] || [[ ! -x "$script_path" ]]; then
                    _log err "脚本不存在或没有执行权限: $script_path"
                    sleep 2
                    continue
                fi
                
                mkdir -p "$(dirname "$HEALTH_CHECK_CONFIG_FILE")"
                touch "$HEALTH_CHECK_CONFIG_FILE"
                

                local success_count=0
                for upstream_addr in "${selected_upstreams[@]}"; do
                    local escaped_addr
                    escaped_addr=$(sed 's/[&/\]/\\&/g' <<< "$upstream_addr")

                    sed -i "/^${escaped_addr}=/d" "$HEALTH_CHECK_CONFIG_FILE"
                    echo "${upstream_addr}=${script_path}" >> "$HEALTH_CHECK_CONFIG_FILE"
                    ((success_count++))
                done

                _log succ "已成功为 ${success_count} 个上游地址配置了检测脚本。"
                sleep 2
                ;;

            2) 
                if [[ ! -s "$HEALTH_CHECK_CONFIG_FILE" ]]; then
                    _log warn "没有可删除的配置。"
                    sleep 2
                    continue
                fi
                
                local line_count
                line_count=$(wc -l < "$HEALTH_CHECK_CONFIG_FILE")
                read -e -p "请输入要删除的配置编号 (1-${line_count}, 输入0取消): " num_to_del

                if ! [[ "$num_to_del" =~ ^[0-9]+$ ]]; then
                    _log err "无效的输入，请输入一个数字。"
                    sleep 2
                    continue
                fi

                if [[ "$num_to_del" -eq 0 ]]; then
                    _log info "操作已取消。"
                    sleep 1
                    continue
                fi

                if (( num_to_del < 1 || num_to_del > line_count )); then
                    _log err "无效的编号。请输入 1 到 ${line_count} 之间的数字。"
                    sleep 2
                    continue
                fi
                
                local line_content
                line_content=$(sed -n "${num_to_del}p" "$HEALTH_CHECK_CONFIG_FILE")
                sed -i "${num_to_del}d" "$HEALTH_CHECK_CONFIG_FILE"
                
                _log succ "已删除配置: ${line_content}"
                sleep 2
                ;;
            3)
                if [[ ! -s "$HEALTH_CHECK_CONFIG_FILE" ]]; then
                    _log warn "没有可执行的检测配置。"
                    sleep 2
                    continue
                fi
                
                echo "-------------------------------------"
                echo "  1) 全部检测"
                echo "  2) 选择单个检测"
                echo "  0) 取消"
                read -e -p "请选择检测范围: " check_scope
                
                case "$check_scope" in
                    1)
                        run_manual_health_check
                        ;;
                    2)
                        local line_count
                        line_count=$(wc -l < "$HEALTH_CHECK_CONFIG_FILE")
                        read -e -p "请输入要检测的配置编号 (1-${line_count}): " num_to_run
                        
                        if ! [[ "$num_to_run" =~ ^[0-9]+$ ]]; then
                            _log err "无效的输入，请输入一个数字。"
                        elif (( num_to_run < 1 || num_to_run > line_count )); then
                            _log err "无效的编号。请输入 1 到 ${line_count} 之间的数字。"
                        else
                            run_manual_health_check "$num_to_run"
                        fi
                        ;;
                    *)
                        _log info "操作已取消。"
                        ;;
                esac
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            0)
                break
                ;;
            *)
                _log err "无效输入"
                sleep 1
                ;;
        esac
    done
}


configure_health_check_cycle() {
    _log info "配置健康检测周期 (Cron 表达式)"
    
    local current_cron
    if [[ -f "$DAEMON_CONFIG_FILE" ]]; then
        current_cron=$(grep "^HEALTH_CHECK_CRON=" "$DAEMON_CONFIG_FILE" | cut -d'=' -f2-)
    fi
    current_cron=${current_cron:-"*/5 * * * *"}

    _log info "当前 Cron 表达式: ${YELLOW}${current_cron}${RESET}"
    echo "Cron 表达式格式: 分 时 日 月 周 (例如: '*/5 * * * *' 表示每5分钟)"
    read -e -p "请输入新的 Cron 表达式 [留空则不修改]: " new_cron

    if [[ -n "$new_cron" ]]; then
        mkdir -p "$(dirname "$DAEMON_CONFIG_FILE")"
        if grep -q "^HEALTH_CHECK_CRON=" "$DAEMON_CONFIG_FILE" 2>/dev/null; then
            sed -i "s|^HEALTH_CHECK_CRON=.*|HEALTH_CHECK_CRON=${new_cron}|" "$DAEMON_CONFIG_FILE"
        else
            echo "HEALTH_CHECK_CRON=${new_cron}" >> "$DAEMON_CONFIG_FILE"
        fi
        _log succ "健康检测周期已更新为: ${new_cron}"
        
        if systemctl is-active --quiet realm_health_check; then
            read -e -p "健康检测服务正在运行。是否要立即重启以应用新的周期? [Y/n]: " restart_choice
            if [[ ${restart_choice:-Y} =~ ^[Yy]$ ]]; then
                _log info "正在重启健康检测服务..."
                start_or_restart_health_check_daemon
            else
                _log warn "配置已更新，但服务未重启。新的周期将在下次手动启动服务时生效。"
            fi
        else
            _log warn "配置已更新。请启动健康检测服务以应用新的周期。"
        fi
    else
        _log info "未做任何修改。"
    fi
}


start_or_restart_health_check_daemon() {

    if [[ -f "$DAEMON_PID_FILE" ]] && ps -p "$(cat "$DAEMON_PID_FILE")" > /dev/null; then
        _log warn "检测到由旧版脚本启动的健康守护进程 (PID: $(cat "$DAEMON_PID_FILE"))。"
        _log info "正在停止旧版进程以便转换为 systemd 服务管理..."
        kill "$(cat "$DAEMON_PID_FILE")"
        rm -f "$DAEMON_PID_FILE"
        sleep 1
        _log succ "旧版进程已停止。"
    fi

    _log info "正在为健康检测服务准备环境配置文件..."
    mkdir -p "$(dirname "$DAEMON_CONFIG_FILE")"
    
    local cron_from_file
    cron_from_file=$(grep "^HEALTH_CHECK_CRON=" "$DAEMON_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-)
    local effective_cron="${cron_from_file:-"*/5 * * * *"}"

    detect_config_file
    

    cat > "$DAEMON_CONFIG_FILE" <<EOF
HEALTH_CHECK_CRON=${effective_cron}
REALM_CONFIG_DIR=${REALM_CONFIG_DIR}
REALM_CONFIG_FILE=${REALM_CONFIG_FILE}
HEALTH_CHECKS_FILE=${HEALTH_CHECK_CONFIG_FILE}
STATE_BACKUP_FILE=${STATE_BACKUP_FILE}
VENV_PYTHON=${VENV_PATH}/bin/python3
HEALTH_CHECK_LOG_FILE=${HEALTH_CHECK_LOG_FILE}
EOF
    

    if [[ ! -f "$DAEMON_SERVICE_FILE" ]]; then
        _log info "正在创建健康检测服务的 systemd 单元文件: $DAEMON_SERVICE_FILE"
        cat > "$DAEMON_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Health Check Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${PYTHON_EXECUTOR_SCRIPT} start_daemon
EnvironmentFile=${DAEMON_CONFIG_FILE}
Restart=on-failure
RestartSec=10
StandardOutput=append:${HEALTH_CHECK_LOG_FILE}
StandardError=append:${HEALTH_CHECK_LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        _log succ "Systemd 单元文件创建成功。"
    fi

    _log info "正在启用并启动(或重启)健康检测服务 (realm_health_check.service)..."

    systemctl enable realm_health_check >/dev/null 2>&1

    systemctl restart realm_health_check

    sleep 1
    if systemctl is-active --quiet realm_health_check; then
        _log succ "健康检测服务已成功启动。"
        _log info "可使用 'systemctl status realm_health_check' 或菜单选项 10 查看状态。"
        _log info "日志文件: tail -f $HEALTH_CHECK_LOG_FILE"
    else
        _log err "启动健康检测服务失败。"
        _log err "请检查日志: journalctl -u realm_health_check -n 50"
    fi
}


stop_health_check_daemon() {
    _log info "开始停止健康检测服务..."
    local stopped_systemd=false
    local stopped_pid=false


    if systemctl is-active --quiet realm_health_check; then
        _log info "正在停止 systemd 服务 (realm_health_check.service)..."
        systemctl stop realm_health_check
        stopped_systemd=true
    fi

    if systemctl list-units --all --type=service | grep -q 'realm_health_check.service'; then
        _log info "正在禁用 systemd 服务..."
        systemctl disable realm_health_check >/dev/null 2>&1
    fi
    

    if [[ -f "$DAEMON_PID_FILE" ]] && ps -p "$(cat "$DAEMON_PID_FILE")" > /dev/null; then
        _log warn "检测到旧版 PID 文件，正在停止相关进程..."
        kill "$(cat "$DAEMON_PID_FILE")"
        rm -f "$DAEMON_PID_FILE"
        stopped_pid=true
    fi
    

    if [[ "$stopped_systemd" == true || "$stopped_pid" == true ]]; then
        _log succ "健康检测服务已停止。"
    else
        _log warn "未检测到正在运行的健康检测服务。"
    fi
}


status_health_check_daemon() {

    if ! systemctl list-units --all --type=service | grep -q 'realm_health_check.service'; then

       if [[ -f "$DAEMON_PID_FILE" ]] && ps -p "$(cat "$DAEMON_PID_FILE")" > /dev/null; then
            _log warn "检测到由旧版脚本启动的进程(PID: $(cat "$DAEMON_PID_FILE"))，但未找到 systemd 服务。"
            _log warn "建议使用菜单选项 [8] 来将其转换为 systemd 服务管理。"
       else
            _log warn "健康检测服务从未安装过。"
       fi
       return
    fi

    _log info "正在获取健康检测服务状态 (realm_health_check.service)..."
    echo "---"

    systemctl status realm_health_check --no-pager
    echo "---"
}



update_management_script() {
    _log warn "这将从 GitHub 下载最新版本的管理脚本并覆盖当前文件。"
    _log warn "请确保您没有对脚本文件进行任何本地修改，否则修改将会丢失。"
    read -e -p "确定要继续吗? [Y/n]: " choice
    choice=${choice:-Y}
    if [[ "$choice" == "Y" ]] || [[ "$choice" == "y" ]]; then

        bash "$UPDATE_SCRIPT_PATH" "$0" "$SCRIPT_VERSION"
    else
        _log info "更新操作已取消。"
    fi
}


main_menu() {
    while true; do
        clear
        detect_config_file
        
        echo -e "${BLUE}=====================================================${RESET}"
        echo -e "${TITLE_COLOR}              ${SCRIPT_NAME} v${SCRIPT_VERSION}              ${RESET}"
        echo -e "${BLUE}=====================================================${RESET}"
        
        display_status
        
        echo "-----------------------------------------------------"
        echo " 1. 安装/更新 Realm"
        echo " 2. 彻底卸载 Realm"
        echo " 3. 启动/重启 Realm"
        echo " 4. 停止 Realm"
        echo " 5. 管理 Realm 配置文件"
        echo " 6. 检查当前配置"
        echo "-----------------------------------------------------"
        echo -e "${CYAN}--- 上游健康检测 ---${RESET}"
        echo " 7. 管理上游检测脚本"
        echo " 8. 启动/重启健康检测服务"
        echo " 9. 停止健康检测服务"
        echo " 10. 查看健康检测服务状态"
        echo " 11. 配置健康检测周期 (Cron)"
        echo "-----------------------------------------------------"
        echo " 12. 更新管理脚本"
        echo "-----------------------------------------------------"
        echo " 0. 退出脚本"
        echo ""
        read -e -p "请输入选项 [0-12]: " choice

        local needs_pause=true
        case "$choice" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) check_config_and_start ;;
            4) stop_realm ;;
            5) manage_config; needs_pause=false ;;
            6) check_config_and_start "check_only" ;;
            7) if check_python_dependency; then manage_health_checks; needs_pause=false; fi ;;
            8) if check_python_dependency; then start_or_restart_health_check_daemon; fi ;;
            9) if check_python_dependency; then stop_health_check_daemon; fi ;;
            10) if check_python_dependency; then status_health_check_daemon; fi ;;
            11) if check_python_dependency; then configure_health_check_cycle; fi ;;
            12) update_management_script; needs_pause=false ;;
            0) _log info "退出脚本。"; exit 0 ;;
            *) _log err "无效的输入，请重试。" ;;
        esac
        
        if [[ "$needs_pause" == true ]]; then
            echo ""
            read -n 1 -s -r -p "按任意键返回主菜单..."
        fi
    done
}



check_root
check_helper_scripts
initialize_settings
load_manager_settings
check_dependencies
takeover_running_realm
main_menu