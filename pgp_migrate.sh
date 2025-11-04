#author sunmoon
#!/bin/bash
set -euo pipefail

INSTALL_NAME=""
INSTALL_PATH=""
SERVICE_NAME=""
ARCHIVE_PATH=""
RELEASE=""
PGPMAID_VERSION=""

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "错误：本脚本需要 root 权限执行。" >&2
        exit 1
    fi
}

detect_release() {
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
    elif grep -qi "debian" /etc/issue 2>/dev/null; then
        RELEASE="debian"
    elif grep -qi "ubuntu" /etc/issue 2>/dev/null; then
        RELEASE="ubuntu"
    elif grep -qi "centos|red hat|redhat" /etc/issue 2>/dev/null; then
        RELEASE="centos"
    elif grep -qi "debian" /proc/version 2>/dev/null; then
        RELEASE="debian"
    elif grep -qi "ubuntu" /proc/version 2>/dev/null; then
        RELEASE="ubuntu"
    elif grep -qi "centos|red hat|redhat" /proc/version 2>/dev/null; then
        RELEASE="centos"
    else
        RELEASE="unknown"
    fi
}

prompt_install_name() {
    local default_name="pgp"
    echo "==============================================================="
    echo "多账号支持: 您可以指定一个自定义的安装名称"
    echo "这将决定安装目录(/var/lib/<名称>)和系统服务名(<名称>)"
    echo "默认实例目录: /var/lib/${default_name}"
    echo "==============================================================="
    printf "请输入实例目录后缀 [默认: %s]: " "$default_name"
    read -r input
    if [[ -z "$input" ]]; then
        INSTALL_NAME="$default_name"
    else
        INSTALL_NAME=$(echo "$input" | tr -cd '[:alnum:]_-')
        if [[ -z "$INSTALL_NAME" ]]; then
            echo "输入的名称无效，使用默认名称: $default_name"
            INSTALL_NAME="$default_name"
        fi
    fi
    INSTALL_PATH="/var/lib/$INSTALL_NAME"
    SERVICE_NAME="$INSTALL_NAME"
    echo "已选择实例: $INSTALL_NAME"
    echo "实例目录: $INSTALL_PATH"
    echo "系统服务名称: $SERVICE_NAME"
    echo ""
}

ensure_install_exists() {
    if [[ ! -d "$INSTALL_PATH" ]]; then
        echo "错误: 未找到目录 $INSTALL_PATH" >&2
        exit 1
    fi
}

stop_service_if_exists() {
    echo "正在停止服务 $SERVICE_NAME (如存在)..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

remove_cron_job() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo "系统未安装 crontab，跳过定时任务清理"
        return
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/${SERVICE_NAME}_cron.XXXXXX)
    if crontab -l 2>/dev/null >"$tmpfile"; then
        :
    else
        >"$tmpfile"
    fi

    if grep -q "systemctl restart $SERVICE_NAME" "$tmpfile"; then
        local filtered="${tmpfile}.filtered"
        grep -v "systemctl restart $SERVICE_NAME" "$tmpfile" >"$filtered" || true
        if [[ -s "$filtered" ]]; then
            crontab "$filtered"
        else
            crontab -r >/dev/null 2>&1 || true
        fi
        echo "已移除与 $SERVICE_NAME 相关的定时任务"
        rm -f "$filtered"
    else
        echo "未检测到与 $SERVICE_NAME 相关的定时任务"
    fi
    rm -f "$tmpfile"
}

export_requirements() {
    local pip_bin="$INSTALL_PATH/venv/bin/pip"
    local output="$INSTALL_PATH/requirements_migrate.txt"
    if [[ -x "$pip_bin" ]]; then
        "$pip_bin" freeze >"$output"
        echo "依赖已导出到 $output"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m pip freeze >"$output"
        echo "未找到虚拟环境，已使用系统 pip 导出到 $output"
    else
        echo "警告: 未能导出 requirements_migrate.txt (未找到 pip)"
    fi
}

create_archive() {
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    ARCHIVE_PATH="/tmp/${SERVICE_NAME}_pagermaid_backup_${timestamp}.tar.gz"
    echo "正在打包 $INSTALL_PATH ..."
    tar -czf "$ARCHIVE_PATH" -C /var/lib "$INSTALL_NAME"
    echo "打包完成，压缩文件已生成: $ARCHIVE_PATH"
}

transfer_archive() {
    read -rp "是否需要将压缩文件发送（采用scp传输）到新机器? [y/N]: " answer
    answer=${answer:-N}
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        read -rp "请输入新机器用户名 [默认: root]: " remote_user
        remote_user=${remote_user:-root}
        read -rp "请输入新机器地址 (例如 1.2.3.4 或 example.com): " remote_host
        if [[ -z "$remote_host" ]]; then
            echo "未提供新机器地址，跳过传输"
            return
        fi
        read -rp "请输入新机器保存路径 [默认: /var/lib]: " remote_path
        remote_path=${remote_path:-/var/lib}
        echo "正在传输文件，请稍候..."
        scp "$ARCHIVE_PATH" "${remote_user}@${remote_host}:${remote_path}/"
        echo "传输完成。请在新机器确认文件位置: ${remote_path}/$(basename "$ARCHIVE_PATH")"
    else
        echo "已跳过自动传输。请手动将 $ARCHIVE_PATH 复制到新机器。"
    fi
}

remove_service_definition() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
}

detect_version() {
    local init_file="$INSTALL_PATH/pagermaid/__init__.py"
    if [[ -f "$init_file" ]]; then
        local detected
        detected=$(grep -E "__version__" "$init_file" | head -n1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)
        if [[ -n "$detected" ]]; then
            PGPMAID_VERSION="$detected"
            return
        fi
    fi
    PGPMAID_VERSION="migrated"
}

write_service_file() {
    detect_version
    cat <<UNIT >/etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=PagerMaid-Pyro ${PGPMAID_VERSION} telegram utility daemon ($INSTALL_NAME)
After=network.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_PATH
ExecStart=$INSTALL_PATH/venv/bin/python3 -m pagermaid
Restart=always
UNIT
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    echo "systemd 守护进程已写入: /etc/systemd/system/$SERVICE_NAME.service"
}

reload_systemd() {
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_system_dependencies() {
    echo "正在安装系统依赖..."
    if [[ "$RELEASE" = "centos" ]]; then
        yum install -y python3 python3-venv python3-pip git screen imagemagick zbar zbar-devel tesseract tesseract-langpack-chi-sim tesseract-langpack-eng
    elif [[ "$RELEASE" = "ubuntu" || "$RELEASE" = "debian" ]]; then
        apt-get update
        apt-get install -y python3 python3-venv python3-pip imagemagick libzbar-dev libxml2-dev libxslt-dev tesseract-ocr tesseract-ocr-all
    else
        echo "无法识别的系统，已跳过系统依赖安装。"
    fi
}

install_requirements_chain() {
    local req_txt="$INSTALL_PATH/requirements.txt"
    local req_mig="$INSTALL_PATH/requirements_migrate.txt"
    local python_bin=""
    local pip_exe=""

    if [[ -x "$INSTALL_PATH/venv/bin/python3" ]]; then
        python_bin="$INSTALL_PATH/venv/bin/python3"
    elif command -v python3 >/dev/null 2>&1; then
        python_bin="$(command -v python3)"
    fi

    if [[ -n "$python_bin" ]]; then
        if "$python_bin" -m pip --version >/dev/null 2>&1; then
            echo "正在升级 pip..."
            "$python_bin" -m pip install --upgrade pip
            if [[ -f "$req_txt" ]]; then
                echo "正在安装官方 requirements.txt ..."
                "$python_bin" -m pip install -r "$req_txt"
            else
                echo "警告: 未找到官方 requirements.txt"
            fi
            if [[ -f "$req_mig" ]]; then
                echo "正在安装迁移依赖 requirements_migrate.txt ..."
                "$python_bin" -m pip install -r "$req_mig"
            else
                echo "提示: 未发现迁移依赖文件 requirements_migrate.txt"
            fi
            return
        fi
    fi

    if command -v pip3 >/dev/null 2>&1; then
        pip_exe="$(command -v pip3)"
    elif command -v pip >/dev/null 2>&1; then
        pip_exe="$(command -v pip)"
    else
        echo "警告: 未找到 pip，无法安装依赖"
        return
    fi

    if [[ -f "$req_txt" ]]; then
        echo "正在安装官方 requirements.txt (系统 pip)..."
        "$pip_exe" install -r "$req_txt"
    else
        echo "警告: 未找到官方 requirements.txt"
    fi
    if [[ -f "$req_mig" ]]; then
        echo "正在安装迁移依赖 requirements_migrate.txt (系统 pip)..."
        "$pip_exe" install -r "$req_mig"
    else
        echo "提示: 未发现迁移依赖文件 requirements_migrate.txt"
    fi
}

rebuild_virtualenv() {
    echo "正在重新构建虚拟环境..."
    rm -rf "$INSTALL_PATH/venv"
    python3 -m venv "$INSTALL_PATH/venv"
    install_requirements_chain
}

source_mode() {
    prompt_install_name
    ensure_install_exists
    stop_service_if_exists
    remove_cron_job
    export_requirements
    create_archive
    transfer_archive
    echo ""
    echo "旧机器操作完成。压缩文件位于: $ARCHIVE_PATH"
    echo "请在新机器执行同脚本并选择恢复模式完成迁移。"
}

destination_mode() {
    prompt_install_name
    read -rp "请输入压缩文件的完整路径: " archive_file
    if [[ -z "$archive_file" || ! -f "$archive_file" ]]; then
        echo "错误: 找不到压缩文件: $archive_file" >&2
        exit 1
    fi

    if [[ -d "$INSTALL_PATH" ]]; then
        read -rp "检测到 $INSTALL_PATH 已存在，是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "已取消部署。"
            exit 0
        fi
        rm -rf "$INSTALL_PATH"
    fi

    mkdir -p /var/lib
    echo "正在解压..."
    tar -xzf "$archive_file" -C /var/lib

    install_requirements_chain

    remove_service_definition
    write_service_file
    reload_systemd
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "服务已成功启动。"
        return
    fi

    echo "首次启动失败，准备重新安装依赖并重建环境..."
    install_system_dependencies
    rebuild_virtualenv
    remove_service_definition
    write_service_file
    reload_systemd
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "服务已在重新安装依赖后成功启动。"
    else
        echo "服务仍未成功启动，请执行 journalctl -u $SERVICE_NAME -f 查看日志。"
    fi
}

main_menu() {
    echo "==============================================================="
    echo "PagerMaid-Pyro 迁移助手"
    echo "==============================================================="
    echo "1) 旧机器：打包并迁移实例"
    echo "2) 新机器：解包并恢复实例"
    echo "q) 退出"
    echo -e "\033[1;34m如遇问题，可联系作者sunmoon\033[0m"
    echo "==============================================================="
    while true; do
        read -rp "请选择操作: " choice
        case "$choice" in
            1) source_mode; break ;;
            2) destination_mode; break ;;
            q|Q) echo "已退出。"; exit 0 ;;
            *) echo "输入无效，请重新选择。" ;;
        esac
    done
}

check_root
detect_release
main_menu
