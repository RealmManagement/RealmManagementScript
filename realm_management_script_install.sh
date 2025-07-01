#!/bin/bash

REPO="RealmManagement/RealmManagementScript"

WITH_ENV_PREFIX="realm-management-script-with-venv"
SOURCE_ONLY_PREFIX="realm-management-script"

CORE_SCRIPT="realm_management.sh"


echo "======================================================================"
echo " 请选择要下载的 Realm Management Script 版本"
echo "======================================================================"
echo
echo "  [1] 完整包"
echo "      > 描述: 包含python相关环境及依赖，开箱即用"
echo "      > 体积: 较大(80MB+)，如果您与Github的连通性不佳，下载可能较慢。"
echo
echo "  [2] 精简包"
echo "      > 描述: 体积小，下载快，稍后会自动补全python相关环境及依赖"
echo "      > 体积: 小(20KB+)"
echo
echo "----------------------------------------------------------------------"
echo "  提示: 如果您在中国大陆，或者不确定如何选择，请选择 [2]。"
echo "----------------------------------------------------------------------"


ASSET_PREFIX=""
USER_CHOICE=""
while true; do
    read -p "请输入您的选项 [1/2]，然后按 Enter: " choice

    case $choice in
        1)
            ASSET_PREFIX="$WITH_ENV_PREFIX"
            USER_CHOICE="1"
            echo "您已选择: [1] 完整包。"
            break
            ;;
        2)
            ASSET_PREFIX="$SOURCE_ONLY_PREFIX"
            USER_CHOICE="2"
            echo "您已选择: [2] 精简包。"
            break
            ;;
        *)
            echo "输入无效。请输入 1 或 2。"
            ;;
    esac
done


echo
echo "正在从 GitHub 获取最新 Release 的信息..."
API_URL="https://api.github.com/repos/$REPO/releases/latest"
DOWNLOAD_URL=$(curl -s -L "$API_URL" | grep "browser_download_url.*${ASSET_PREFIX}.*\.tar\.gz" | head -n 1 | cut -d '"' -f 4)
if [ "$USER_CHOICE" = "2" ]; then
DOWNLOAD_URL=$(curl -s -L "$API_URL" | grep "browser_download_url.*${ASSET_PREFIX}\.tar\.gz" | head -n 1 | cut -d '"' -f 4)
fi
ASSET_NAME=$(basename "$DOWNLOAD_URL")

if [ -z "$DOWNLOAD_URL" ]; then
    echo "错误：无法找到以 '${ASSET_PREFIX}' 开头的资源文件。"
    exit 1
fi
echo "成功找到资源文件: $ASSET_NAME"



echo "正在下载 $ASSET_NAME..."
curl -L -f -o "$ASSET_NAME" "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo "错误：下载文件失败。"
    exit 1
fi
echo "下载完成。"

echo "正在解压主软件包..."
tar -xzf "$ASSET_NAME"
if [ $? -ne 0 ]; then
    echo "错误：解压主软件包 '$ASSET_NAME' 失败。"
    exit 1
fi
echo "主软件包解压完成。"


if [ "$USER_CHOICE" = "1" ]; then
    if [ -f "venv.tar.gz" ]; then
        echo "检测到环境包，正在创建 .venv 目录并解压 Python 环境..."
        mkdir .venv
        tar -xzf "venv.tar.gz" -C .venv
        if [ $? -ne 0 ]; then
            echo "错误：解压环境包 'venv.tar.gz' 到 .venv 目录失败。"
            exit 1
        fi
        echo "Python 环境解压完成，已生成 '.venv/' 目录。"
    else
        echo "错误：在解压的文件中未找到环境包 'venv.tar.gz'。"
        exit 1
    fi
fi


if [ ! -f "$CORE_SCRIPT" ]; then
    echo "错误：在解压的文件中未找到核心脚本 '$CORE_SCRIPT'。"
    exit 1
fi

echo "找到核心脚本: $CORE_SCRIPT"

echo "----------------------------------------------------"
echo "下载脚本执行完毕。请使用命令【bash ./"$CORE_SCRIPT"】启动Realm管理脚本"
