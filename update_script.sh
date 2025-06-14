#!/bin/bash









RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'


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


MAIN_SCRIPT_TO_RESTART="$1"

CURRENT_VERSION="$2"


if [[ -z "$MAIN_SCRIPT_TO_RESTART" || -z "$CURRENT_VERSION" ]]; then
    _log err "更新脚本必须由主脚本调用，且需要提供版本号。请不要直接运行此脚本。"
    exit 1
fi


REPO="RealmManagement/RealmManagementScript"
ASSET_PREFIX="realm-management-script"
API_URL="https://api.github.com/repos/$REPO/releases/latest"


_log info "正在检测 GitHub 连接性..."
if ! curl -o /dev/null -s -m 5 --head https://api.github.com; then
    _log err "无法连接到 GitHub API。请检查您的网络连接。"
    exit 1
fi
_log succ "GitHub 连接正常。"


_log info "正在从 GitHub 获取最新 Release 的信息..."
API_RESPONSE=$(curl -s -L "$API_URL")


LATEST_VERSION_TAG=$(echo "$API_RESPONSE" | grep -Po '"tag_name": "\K.*?(?=")')


if [[ -z "$LATEST_VERSION_TAG" ]]; then
    _log err "无法从 GitHub API 获取最新版本号。"
    exit 1
fi


REMOTE_VERSION=${LATEST_VERSION_TAG#v}


_log info "当前版本: ${CURRENT_VERSION}, 最新版本: ${REMOTE_VERSION}"
if [[ "$CURRENT_VERSION" == "$REMOTE_VERSION" ]]; then
    _log succ "您当前已经是最新版本 ($CURRENT_VERSION)。无需更新。"
    exit 0
fi


_log info "检测到新版本: ${REMOTE_VERSION}。"
read -e -p "是否要立即更新? [Y/n]: " choice

choice=${choice:-Y}
if [[ "$choice" != "Y" ]] && [[ "$choice" != "y" ]]; then
    _log info "更新操作已取消。"
    exit 0
fi


_log info "准备更新..."


DOWNLOAD_URL=$(curl -s -L "$API_URL" | grep "browser_download_url.*${ASSET_PREFIX}\.tar\.gz" | head -n 1 | cut -d '"' -f 4)


if [[ -z "$DOWNLOAD_URL" ]]; then
    _log err "无法找到最新的管理脚本资源文件。"
    _log err "请检查仓库 '${REPO}' 是否有有效的 Release，或者尝试使用代理。"
    exit 1
fi


ASSET_NAME=$(basename "$DOWNLOAD_URL")
_log succ "成功找到最新的资源文件: ${ASSET_NAME}"


TEMP_ARCHIVE="/tmp/${ASSET_NAME}"


_log info "正在下载 ${ASSET_NAME}..."
curl -L -f -o "$TEMP_ARCHIVE" "$DOWNLOAD_URL"


if [ $? -ne 0 ]; then
    _log err "下载文件失败。请检查您的网络或重试。"

    rm -f "$TEMP_ARCHIVE"
    exit 1
fi
_log succ "下载完成。"


SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)



_log info "正在解压文件以覆盖当前版本: ${SCRIPT_DIR}"
tar -xzf "$TEMP_ARCHIVE" -C "$SCRIPT_DIR" --strip-components=1


if [ $? -ne 0 ]; then
    _log err "解压文件 '${ASSET_NAME}' 失败。"

    rm -f "$TEMP_ARCHIVE"
    exit 1
fi


rm -f "$TEMP_ARCHIVE"

_log succ "脚本文件已成功更新！"


_log info "正在重启管理脚本..."
sleep 2
exec "$MAIN_SCRIPT_TO_RESTART"
