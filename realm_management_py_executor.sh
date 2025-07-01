#!/bin/bash









set -e


SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
VENV_PATH="${SCRIPT_DIR}/.venv"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
MANAGER_SETTINGS_FILE="${SCRIPT_DIR}/.realm_management_script_config.conf"


VENV_PYTHON="${VENV_PATH}/bin/python3"
VENV_PIP="${VENV_PATH}/bin/pip"


DAEMON_SCRIPT_PATH="${SCRIPT_DIR}/health_checker_daemon.py"
VALIDATOR_SCRIPT_PATH="${SCRIPT_DIR}/validator.py"


_log() {
    local type="$1"
    local msg="$2"
    local color_reset=$'\033[0m'
    local color_cyan=$'\033[0;36m'
    local color_red=$'\033[0;31m'
    local color_yellow=$'\033[0;33m'


    case "$type" in
        info)
            echo -e "${color_cyan}[INFO]${color_reset} $msg" >&2
            ;;
        warn)
            echo -e "${color_yellow}[WARN]${color_reset} $msg" >&2
            ;;
        err)
            echo -e "${color_red}[ERROR]${color_reset} $msg" >&2
            ;;
    esac
}



init_and_activate_env() {

    if [[ -f "$MANAGER_SETTINGS_FILE" ]]; then
        source "$MANAGER_SETTINGS_FILE"
    fi


    if [ -d "$VENV_PATH" ]; then

        if [[ "$PYTHON_ENV_SOURCE" != "python-venv" ]]; then

            if [[ -n "$CONDA_PREFIX" && "$(realpath "$CONDA_PREFIX")" == "$(realpath "$VENV_PATH")" ]]; then

                :
            elif [ -f "${VENV_PATH}/bin/activate" ]; then

                source "${VENV_PATH}/bin/activate"
            else
                _log err "在 ${VENV_PATH} 中找不到有效的 activate 脚本。"
                exit 1
            fi
        else


            source "${VENV_PATH}/bin/activate"
        fi
    else

        _log info "虚拟环境 (.venv) 不存在，将使用 'python3 -m venv' 创建。"
        
        if ! command -v python3 &>/dev/null; then
            _log err "未找到 'python3' 命令。无法创建虚拟环境。请先安装 Python 3.6+。"
            exit 1
        fi
        
        local python_version
        python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
        if [[ "$(printf '%s\n' "3.6" "$python_version" | sort -V | head -n1)" != "3.6" ]]; then
            _log err "Python 版本过低 ($python_version)。此脚本的Python部分需要 Python 3.6 或更高版本。"
            exit 1
        fi

        if ! python3 -m venv "$VENV_PATH"; then
            _log warn "创建 Python 虚拟环境失败。这通常是因为缺少 'python3-venv' 包。"
            
            local pm=""
            if command -v "apt-get" &>/dev/null; then
                pm="apt"
            elif command -v "yum" &>/dev/null; then
                pm="yum"

            elif command -v "dnf" &>/dev/null; then
                pm="dnf"
            fi
            
            if [[ -z "$pm" ]]; then
                _log err "无法检测到支持的包管理器，请手动安装 venv 相关包。"
                exit 1
            fi

            read -p "是否尝试自动安装 'python3-venv' (或等效包)? [Y/n]: " choice
            choice=${choice:-Y}
            if [[ "$choice" != "Y" ]] && [[ "$choice" != "y" ]]; then
                _log err "用户拒绝安装，脚本无法继续。"
                exit 1
            fi

            local venv_pkg=""
            if [[ "$pm" == "apt" ]]; then
                venv_pkg="python${python_version}-venv"
            elif [[ "$pm" == "yum" || "$pm" == "dnf" ]]; then
                venv_pkg="python3-devel"
            fi

            if [[ -z "$venv_pkg" ]]; then
                _log err "无法为您的系统确定 venv 包的名称。请手动安装。"
                exit 1
            fi

            _log info "正在使用 '$pm' 安装 '$venv_pkg'..."
            if [[ "$pm" == "apt" ]]; then
                apt-get update
                apt-get install -y "$venv_pkg"
            else
                "$pm" install -y "$venv_pkg"
            fi
            
            _log info "再次尝试创建 Python 虚拟环境..."
            if ! python3 -m venv "$VENV_PATH"; then
                _log err "创建虚拟环境仍然失败。请手动检查并安装 '$venv_pkg'。"
                rm -rf "$VENV_PATH"
                exit 1
            fi
        fi

        if grep -q "^PYTHON_ENV_SOURCE=" "$MANAGER_SETTINGS_FILE" 2>/dev/null; then
            sed -i "s|^PYTHON_ENV_SOURCE=.*|PYTHON_ENV_SOURCE='python-venv'|" "$MANAGER_SETTINGS_FILE"
        else
            echo "PYTHON_ENV_SOURCE='python-venv'" >> "$MANAGER_SETTINGS_FILE"
        fi
        _log info "已在配置文件中记录环境来源为 'python-venv'。"
        
        source "${VENV_PATH}/bin/activate"
    fi


    local active_pip
    active_pip=$(type -p pip)
    if [[ -z "$active_pip" ]]; then
        _log err "在激活的环境中找不到 'pip' 命令！"
        exit 1
    fi


    if [ -f "$REQUIREMENTS_FILE" ]; then
        "$active_pip" install -q --root-user-action=ignore -r "$REQUIREMENTS_FILE"
    else
        _log err "'requirements.txt' 文件未找到！"
        exit 1
    fi

}




ACTION="$1"

shift 

init_and_activate_env

ACTIVE_PYTHON=$(type -p python)

case "$ACTION" in
    init_env)
        : # 什么都不做，因为 init_and_activate_env 总是会执行
        ;;
    validate_config)

        "$ACTIVE_PYTHON" "$VALIDATOR_SCRIPT_PATH" "$@"
        ;;
    parse_upstreams)

        "$ACTIVE_PYTHON" "$DAEMON_SCRIPT_PATH" --action parse_upstreams --file "$1"
        ;;
    modify_state)

        "$ACTIVE_PYTHON" "$DAEMON_SCRIPT_PATH" --action "$1" --address "$2" --file "$3" --state-file "$4"
        ;;
    start_daemon)
        exec "$ACTIVE_PYTHON" -u "$DAEMON_SCRIPT_PATH" --action start_daemon
        ;;
    *)
        _log err "传递给Python执行器的无效操作: '$ACTION'"
        exit 1
        ;;
esac
