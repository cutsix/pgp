#!/bin/bash
if [[ $EUID -ne 0 ]]; then
    echo "错误：本脚本需要 root 权限执行。" 1>&2
    exit 1
fi

a=$(curl --noproxy '*' -sSL https://api.myip.com/)
b="China"
if [[ $a == *$b* ]]
then
  echo "错误：本脚本不支持境内服务器使用。" 1>&2
	exit 1
fi

# 定义全局变量
INSTALL_NAME=""
INSTALL_PATH=""
SERVICE_NAME=""
PGPMAID_VERSION=""
VERSION_HASH=""

# 获取用户指定的安装名
get_install_name() {
    local default_name="pgp"
    echo "==============================================================="
    echo "多账号支持: 您可以指定一个自定义的安装名称"
    echo "这将决定安装目录(/var/lib/<n>)和系统服务名(<n>)"
    echo "不同名称的安装可以同时运行多个账号实例"
    echo "注意！！！ 需要牢记你这里设置的名称！！！"
    echo "==============================================================="
    printf "请输入安装名称 [默认: $default_name]: "
    read -r custom_name <&1
    
    if [ -z "$custom_name" ]; then
        INSTALL_NAME="$default_name"
    else
        # 移除空格和特殊字符，确保名称有效
        INSTALL_NAME=$(echo "$custom_name" | tr -cd '[:alnum:]_-')
        if [ -z "$INSTALL_NAME" ]; then
            echo "输入的名称无效，使用默认名称: $default_name"
            INSTALL_NAME="$default_name"
        fi
    fi
    
    INSTALL_PATH="/var/lib/$INSTALL_NAME"
    SERVICE_NAME="$INSTALL_NAME"
    
    echo "您选择的安装名称: $INSTALL_NAME"
    echo "安装目录将为: $INSTALL_PATH"
    echo "系统服务名称将为: $SERVICE_NAME"
    echo ""
}

# 手动输入实例名称
manually_input_instance() {
    local operation="$1"
    echo "==============================================================="
    echo "选择要${operation}的 PagerMaid 实例:"
    echo "==============================================================="
    
    list_installations

    echo "如果未在上方列表中显示您的实例，请手动输入实例名称"
    echo "==============================================================="
    
    printf "请输入实例名称 (或输入0返回主菜单): "
    read -r custom_name
    
    if [ "$custom_name" = "0" ]; then
        return 1
    fi
    
    if [ -z "$custom_name" ]; then
        echo "实例名称不能为空，请重新输入"
        return 1
    fi
    
    INSTALL_NAME="$custom_name"
    INSTALL_PATH="/var/lib/$INSTALL_NAME"
    SERVICE_NAME="$INSTALL_NAME"
    
    # 验证目录或服务是否存在
    if [ -d "$INSTALL_PATH" ] || [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        echo "已选择实例: $INSTALL_NAME (路径: $INSTALL_PATH)"
        return 0
    else
        echo "错误: 实例 '$INSTALL_NAME' 不存在，未找到目录或服务文件"
        return 1
    fi
}

# 选择要操作的已安装实例
select_existing_instance() {
    local operation="$1"
    local instances=()
    local count=0
    
    echo "==============================================================="
    echo "选择要${operation}的 PagerMaid 实例:"
    echo "==============================================================="
    
    # 1. 首先查找所有PagerMaid服务文件
    for service_file in /etc/systemd/system/*.service; do
        if [ -f "$service_file" ]; then
            # 检查是否是PagerMaid服务
            if grep -q "PagerMaid-Pyro" "$service_file"; then
                local name=$(basename "$service_file" .service)
                local dir="/var/lib/$name"
                local status="未知"
                
                # 检查服务状态
                if systemctl is-active "$name.service" &>/dev/null; then
                    status=$(systemctl is-active "$name.service")
                fi
                
                # 尝试获取版本信息
                local version="未知"
                version=$(grep "Description" "$service_file" | grep -o "PagerMaid-Pyro [^ ]*" | awk '{print $2}')
                if [ -z "$version" ]; then
                    version="未知"
                fi
                
                count=$((count+1))
                instances[$count]="$name"
                echo "$count) $name (版本: $version, 状态: $status, 目录: $dir)"
            fi
        fi
    done
    
    # 2. 扫描/var/lib目录下所有可能的PagerMaid安装，但尚未创建服务
    for dir in /var/lib/*; do
        if [ -d "$dir" ] && [ -f "$dir/pagermaid/__init__.py" ]; then
            local name=$(basename "$dir")
            local service_exists=false
            
            # 检查此目录是否已作为服务列出
            for i in $(seq 1 $count); do
                if [ "${instances[$i]}" = "$name" ]; then
                    service_exists=true
                    break
                fi
            done
            
            # 如果还没有列出该目录
            if [ "$service_exists" = false ]; then
                count=$((count+1))
                instances[$count]="$name"
                echo "$count) $name (版本: 未知, 状态: 无服务, 目录: $dir)"
            fi
        fi
    done
    
    if [ $count -eq 0 ]; then
        echo "未找到任何 PagerMaid 安装实例"
        echo "==============================================================="
        # 允许手动输入实例名称
        manually_input_instance "$operation"
        return $?
    fi
    
    echo "m) 手动输入实例名称"
    echo "0) 返回主菜单"
    echo "==============================================================="
    
    local selection
    printf "请选择实例编号 [1-$count]: "
    read selection
    
    if [[ $selection -eq 0 ]]; then
        return 1
    elif [[ "$selection" = "m" ]]; then
        manually_input_instance "$operation"
        return $?
    elif [[ $selection -ge 1 && $selection -le $count ]]; then
        INSTALL_NAME="${instances[$selection]}"
        INSTALL_PATH="/var/lib/$INSTALL_NAME"
        SERVICE_NAME="$INSTALL_NAME"
        echo "已选择实例: $INSTALL_NAME (路径: $INSTALL_PATH)"
        return 0
    else
        echo "选择无效"
        return 1
    fi
}

# 获取用户指定的PagerMaid版本
select_pgpmaid_version() {
    echo "==============================================================="
    echo "PagerMaid 版本选择"
    echo "==============================================================="
    echo "请选择要安装的 PagerMaid 版本:"
    echo "  1) PagerMaid 版本: 1.4.12 (暂时存在安装问题，推荐安装下面两个)"
    echo "  2) PagerMaid 版本: 1.4.14 (稳定老版本)"
    echo "  3) PagerMaid 最新版本 (官方最新版)"
    echo ""
    echo "推荐使用1.4.1* 老版本，因为许多插件尚未适配新版PagerMaid"
    echo "对于存在安装问题的版本，请等待后续更新修复~"
    echo "如果安装过程存在问题，请根据提示，寻求官方安装指导"
    echo "使用过程若是出现问题，可以TG PM @sunmoonpm_bot，随缘回复~"
    echo "==============================================================="
    
    local choice
    while true; do
        printf "请选择版本 [1-3, 默认: 2]: "
        read -r choice <&1
        
        # 默认选择版本2
        if [ -z "$choice" ]; then
            choice="2"
        fi
        
        case $choice in
            1)
                PGPMAID_VERSION="1.4.12"
                VERSION_HASH="d461cbc"
                break
                ;;
            2)
                PGPMAID_VERSION="1.4.14"
                VERSION_HASH="fb72387"
                break
                ;;
            3)
                PGPMAID_VERSION="最新版"
                VERSION_HASH=""
                break
                ;;
            *)
                echo "输入无效，请重新选择"
                ;;
        esac
    done
    
    echo "您选择的版本: PagerMaid $PGPMAID_VERSION"
    if [ -n "$VERSION_HASH" ]; then
        echo "对应的Commit Hash: $VERSION_HASH"
    fi
    echo ""
}

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    elif cat /proc/version | grep -q -E -i "debian"; then
        release="debian"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    fi
}

welcome() {
    echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
    echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
    echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
    echo ""
    echo ""
    echo "欢迎使用 PagerMaid-Pyro 一键安装程序。"
    echo "安装即将开始"
    echo "如果您想取消安装，"
    echo "请在 5 秒钟内按 Ctrl+C 终止此脚本。"
    echo ""
    sleep 5
}

yum_update() {
    echo "正在优化 yum . . ."
    yum install yum-utils epel-release -y >>/dev/null 2>&1
}

yum_git_check() {
    echo "正在检查 Git 安装情况 . . ."
    if command -v git >>/dev/null 2>&1; then
        echo "Git 似乎存在，安装过程继续 . . ."
    else
        echo "Git 未安装在此系统上，正在进行安装"
        yum install git -y >>/dev/null 2>&1
    fi
}

yum_screen_check() {
    echo "正在检查 Screen 安装情况 . . ."
    if command -v screen >>/dev/null 2>&1; then
        echo "Screen 似乎存在, 安装过程继续 . . ."
    else
        echo "Screen 未安装在此系统上，正在进行安装"
        yum install screen -y >>/dev/null 2>&1
    fi
}

yum_require_install() {
    echo "正在安装系统所需依赖，可能需要几分钟的时间 . . ."
    yum install python-devel python3-devel zbar zbar-devel ImageMagick wget -y >>/dev/null 2>&1
    wget -T 2 -O /etc/yum.repos.d/konimex-neofetch-epel-7.repo https://copr.fedorainfracloud.org/coprs/konimex/neofetch/repo/epel-7/konimex-neofetch-epel-7.repo >>/dev/null 2>&1
    yum groupinstall "Development Tools" -y >>/dev/null 2>&1
    yum-config-manager --add-repo https://download.opensuse.org/repositories/home:/Alexander_Pozdnyakov/CentOS_7/ >>/dev/null 2>&1
    sudo rpm --import https://build.opensuse.org/projects/home:Alexander_Pozdnyakov/public_key >>/dev/null 2>&1
    yum list updates >>/dev/null 2>&1
    yum install neofetch figlet tesseract tesseract-langpack-chi-sim tesseract-langpack-eng -y >>/dev/null 2>&1
}

apt_update() {
    echo "正在优化 apt-get . . ."
    apt-get install sudo -y >>/dev/null 2>&1
    apt-get update >>/dev/null 2>&1
}

apt_git_check() {
    echo "正在检查 Git 安装情况 . . ."
    if command -v git >>/dev/null 2>&1; then
        echo "Git 似乎存在, 安装过程继续 . . ."
    else
        echo "Git 未安装在此系统上，正在进行安装"
        apt-get install git -y >>/dev/null 2>&1
    fi
}

apt_screen_check() {
    echo "正在检查 Screen 安装情况 . . ."
    if command -v screen >>/dev/null 2>&1; then
        echo "Screen 似乎存在, 安装过程继续 . . ."
    else
        echo "Screen 未安装在此系统上，正在进行安装"
        apt-get install screen -y >>/dev/null 2>&1
    fi
}

apt_require_install() {
    echo "正在安装系统所需依赖，可能需要几分钟的时间 . . ."
    apt-get install python3-pip python3-venv imagemagick libwebp-dev neofetch libzbar-dev libxml2-dev libxslt-dev tesseract-ocr tesseract-ocr-all -y >>/dev/null 2>&1
    add-apt-repository ppa:dawidd0811/neofetch -y
    apt-get install neofetch -y >>/dev/null 2>&1
}

debian_require_install() {
    echo "正在安装系统所需依赖，可能需要几分钟的时间 . . ."
    apt-get install imagemagick software-properties-common tesseract-ocr tesseract-ocr-chi-sim libzbar-dev neofetch -y >>/dev/null 2>&1
}

download_repo() {
    echo "下载 repository 中 . . ."
    rm -rf $INSTALL_PATH >>/dev/null 2>&1
    git clone https://github.com/TeamPGM/PagerMaid-Pyro.git $INSTALL_PATH >>/dev/null 2>&1
    cd $INSTALL_PATH >>/dev/null 2>&1
    
    # 根据用户选择的版本切换到特定的commit
    if [ -n "$VERSION_HASH" ]; then
        echo "正在切换到 PagerMaid 版本 $PGPMAID_VERSION (commit: $VERSION_HASH) . . ."
        git checkout $VERSION_HASH >>/dev/null 2>&1
    else
        echo "使用 PagerMaid 最新版本 . . ."
    fi
    
    echo "Hello World!" >$INSTALL_PATH/public.lock
}

check_and_install_venv() {
    echo "检查 python3-venv 安装情况..."
    if ! dpkg -s python3-venv &> /dev/null; then
        echo "python3-venv 未安装，正在安装..."
        sudo apt install -y python3-venv
    else
        echo "python3-venv 已安装"
    fi
}

setup_venv() {
    echo "设置虚拟环境..."
    python3 -m venv $INSTALL_PATH/venv
    source $INSTALL_PATH/venv/bin/activate
    export PYV=$INSTALL_PATH/venv/bin/python3
    echo "虚拟环境已激活"
}

pypi_install() {
    echo "下载安装 pypi 依赖中 . . ."
    echo "升级pip..."
    $PYV -m pip install --upgrade pip
    echo "安装 requirements.txt..."
    $PYV -m pip install -r requirements.txt
    echo "安装 PyYAML..."
    sudo -H $PYV -m pip install --ignore-installed PyYAML
    echo "安装 coloredlogs..."
    $PYV -m pip install coloredlogs
    $PYV -m pip install requests
}

configure() {
    config_file=config.yml
    echo "生成配置文件中 . . ."
    cp config.gen.yml config.yml
    sed -i 's/allow_analytic: "True"/allow_analytic: "False"/' $config_file
    printf "请输入应用程序 api_id（不懂请直接回车）："
    read -r api_id <&1
    sed -i "s/ID_HERE/$api_id/" $config_file
    printf "请输入应用程序 api_hash（不懂请直接回车）："
    read -r api_hash <&1
    sed -i "s/HASH_HERE/$api_hash/" $config_file
    printf "请输入应用程序语言（默认：zh-cn）："
    read -r application_language <&1
    if [ -z "$application_language" ]; then
        echo "语言设置为 简体中文"
    else
        sed -i "s/zh-cn/$application_language/" $config_file
    fi
    printf "请输入应用程序地区（默认：China）："
    read -r application_region <&1
    if [ -z "$application_region" ]; then
        echo "地区设置为 中国"
    else
        sed -i "s/China/$application_region/" $config_file
    fi
    printf "请输入 Google TTS 语言（默认：zh-CN）："
    read -r application_tts <&1
    if [ -z "$application_tts" ]; then
        echo "tts发音语言设置为 简体中文"
    else
        sed -i "s/zh-CN/$application_tts/" $config_file
    fi
}

read_checknum() {
    while :; do
    read -p "请输入您的登录验证码: " checknum
    if [ "$checknum" == "" ]; then
        continue
    fi
    read -p "请再次输入您的登录验证码：" checknum2
    if [ "$checknum" != "$checknum2" ]; then
        echo "两次验证码不一致！请重新输入您的登录验证码"
        continue
    else
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "$checknum"
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
        break
    fi
done
read -p "有没有二次登录验证码(两步密码)？ [Y/n]" choi
    if [ "$choi" == "y" ] || [ "$choi" == "Y" ]; then
        read -p "请输入您的二次登录验证码: " twotimepwd
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "$twotimepwd"
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
    fi
}

login_screen() {
    source $INSTALL_PATH/venv/bin/activate
    screen -S $INSTALL_NAME-userbot -X quit >>/dev/null 2>&1
    screen -dmS $INSTALL_NAME-userbot
    sleep 1
    screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "cd $INSTALL_PATH && $PYV -m pagermaid"
    screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
    sleep 3
    if [ "$(ps -def | grep [p]agermaid | grep -v grep)" == "" ]; then
        echo "PagerMaid 运行时发生错误，错误信息："
        cd $INSTALL_PATH && $PYV -m pagermaid >err.log
        cat err.log
        screen -S $INSTALL_NAME-userbot -X quit >>/dev/null 2>&1
        exit 1
    fi
    while :; do
        echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
        echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
        echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
        echo ""
        read -p "请输入您的 Telegram 手机号码（带国际区号 如 +8618888888888）: " phonenum

        if [ "$phonenum" == "" ]; then
            continue
        fi

        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "$phonenum"
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "y"
        screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'

        sleep 2
        
        if [ "$(ps -def | grep [p]agermaid | grep -v grep)" == "" ]; then
            echo "手机号输入错误！请确认您是否带了区号（中国号码为 +86 如 +8618888888888）"
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "cd $INSTALL_PATH && $PYV -m pagermaid"
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
            continue
        fi

        sleep 1
        if [ "$(ps -def | grep [p]agermaid | grep -v grep)" == "" ]; then
            echo "PagerMaid 运行时发生错误，可能是因为发送验证码失败，请检查您的 API_ID 和 API_HASH"
            exit 1
        fi

        read -p "请输入您的登录验证码: " checknum
        if [ "$checknum" == "" ]; then
            read_checknum
            break
        fi

        read -p "请再次输入您的登录验证码：" checknum2
        if [ "$checknum" != "$checknum2" ]; then
            echo "两次验证码不一致！请重新输入您的登录验证码"
            read_checknum
            break
        else
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "$checknum"
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
        fi

        read -p "有没有二次登录验证码？ [Y/n]" choi
        if [ "$choi" == "y" ] || [ "$choi" == "Y" ]; then
            read -p "请输入您的二次登录验证码: " twotimepwd
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff "$twotimepwd"
            screen -x -S $INSTALL_NAME-userbot -p 0 -X stuff $'\n'
            break
        else
            break
        fi
    done
    sleep 5
    screen -S $INSTALL_NAME-userbot -X quit >>/dev/null 2>&1
}

systemctl_reload() {
    echo "正在写入系统进程守护 . . ."
    echo "[Unit]
    Description=PagerMaid-Pyro $PGPMAID_VERSION telegram utility daemon ($INSTALL_NAME)
    After=network.target
    [Install]
    WantedBy=multi-user.target
    [Service]
    Type=simple
    WorkingDirectory=$INSTALL_PATH
    ExecStart=$PYV -m pagermaid
    Restart=always
    " >/etc/systemd/system/$SERVICE_NAME.service
    chmod 755 /etc/systemd/system/$SERVICE_NAME.service >>/dev/null 2>&1
    systemctl daemon-reload >>/dev/null 2>&1
    systemctl start $SERVICE_NAME >>/dev/null 2>&1
    systemctl enable $SERVICE_NAME >>/dev/null 2>&1
}

setup_crontab() {
    echo "正在设置定时任务..."
    
    if ! command -v crontab >/dev/null 2>&1; then
	    echo "crontab未安装，正在尝试安装..."
	    if [ "$release" = "centos" ]; then
		    yum install cronie -y >>/dev/null 2>&1
	    elif [ "$release" = "ubuntu" ] || [ "$release" = "debian" ]; then
		    apt-get install cron -y >>/dev/null 2>&1
	    else
		    echo "无法确定如何安装crontab，请手动安装后再设置定时任务"
		    echo "定时任务内容: 0 6,18 * * * systemctl restart $SERVICE_NAME"
		    return 1
	    fi

	    if ! command -v crontab >/dev/null 2>&1; then
		    echo "crontab安装失败，请手动安装并添加以下内容到crontab:"
		    echo "0 6,18 * * * systemctl restart $SERVICE_NAME"
		    return 1
	    fi
    fi

    if command -v vim.basic >/dev/null 2>&1; then 
	    export EDITOR=/usr/bin/vim.basic
    else
	    echo "vim.basic未找到，将使用系统默认编辑器"
    fi

    crontab -l > /tmp/current_cron 2>/dev/null || echo "" > /tmp/current_cron

    if ! grep -q "systemctl restart $SERVICE_NAME" /tmp/current_cron; then
	    echo "0 6,18 * * * systemctl restart $SERVICE_NAME" >> /tmp/current_cron
	    if crontab /tmp/current_cron; then
		    echo "成功添加定时任务，每天6:00和18:00自动重启 $INSTALL_NAME"
	    else
		    echo "添加定时任务失败，请手动添加以下内容到crontab:"
		    echo "0 6,18 * * * systemctl restart $SERVICE_NAME"
	    fi
    else
	    echo "定时任务已存在，无需重新添加"
    fi

    rm /tmp/current_cron
}

start_installation() {
    get_install_name
    select_pgpmaid_version
    
    if [ "$release" = "centos" ]; then
        echo "系统检测通过。"
        welcome
        yum_update
        yum_git_check
        yum_screen_check
        yum_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    elif [ "$release" = "ubuntu" ]; then
        echo "系统检测通过。"
        welcome
        apt_update
        apt_git_check
        apt_screen_check
        apt_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    elif [ "$release" = "debian" ]; then
        echo "系统检测通过。"
        welcome
        apt_update
        apt_git_check
        apt_screen_check
        debian_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    else
        echo "目前暂时不支持此系统。"
    fi
    exit 1
}

cleanup() {
    if ! select_existing_instance "卸载"; then
        shon_online
        return
    fi
    
    echo "您确定要卸载 PagerMaid ($INSTALL_NAME) 吗？此操作不可逆! [y/N]"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "正在关闭 PagerMaid ($INSTALL_NAME). . ."
        systemctl disable $SERVICE_NAME >>/dev/null 2>&1
        systemctl stop $SERVICE_NAME >>/dev/null 2>&1
        echo "正在删除 PagerMaid ($INSTALL_NAME) 文件 . . ."
        rm -rf /etc/systemd/system/$SERVICE_NAME.service >>/dev/null 2>&1
        rm -rf $INSTALL_PATH >>/dev/null 2>&1
        echo "卸载完成 . . ."
    else
        echo "已取消卸载操作"
    fi
}

reinstall() {
    if ! select_existing_instance "重新安装"; then
        shon_online
        return
    fi
    
    select_pgpmaid_version
    
    echo "正在关闭 PagerMaid ($INSTALL_NAME). . ."
    systemctl disable $SERVICE_NAME >>/dev/null 2>&1
    systemctl stop $SERVICE_NAME >>/dev/null 2>&1
    
    echo "正在删除 PagerMaid ($INSTALL_NAME) 文件 . . ."
    rm -rf /etc/systemd/system/$SERVICE_NAME.service >>/dev/null 2>&1
    rm -rf $INSTALL_PATH >>/dev/null 2>&1
    
    if [ "$release" = "centos" ]; then
        echo "系统检测通过。"
        welcome
        yum_update
        yum_git_check
        yum_screen_check
        yum_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经重新安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    elif [ "$release" = "ubuntu" ]; then
        echo "系统检测通过。"
        welcome
        apt_update
        apt_git_check
        apt_screen_check
        apt_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经重新安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    elif [ "$release" = "debian" ]; then
        echo "系统检测通过。"
        welcome
        apt_update
        apt_git_check
        apt_screen_check
        debian_require_install
        download_repo
	    check_and_install_venv
        setup_venv
        pypi_install
        configure
        login_screen
        systemctl_reload
	    setup_crontab
        echo "PagerMaid $PGPMAID_VERSION ($INSTALL_NAME) 已经重新安装完毕 在telegram对话框中输入 ,help 并发送查看帮助列表"
    else
        echo "目前暂时不支持此系统。"
    fi
}

cleansession() {
    if ! select_existing_instance "重新登录"; then
        shon_online
        return
    fi
    
    if [ ! -d "$INSTALL_PATH" ]; then
        echo "目录不存在请重新安装 PagerMaid ($INSTALL_NAME)。"
        return
    fi
    
    echo "正在关闭 PagerMaid ($INSTALL_NAME). . ."
    systemctl stop $SERVICE_NAME >>/dev/null 2>&1
    echo "正在删除账户授权文件 . . ."
    rm -rf $INSTALL_PATH/pagermaid.session >>/dev/null 2>&1
    echo "请进行重新登陆. . ."
    if [ "$release" = "centos" ]; then
        yum_screen_check
    elif [ "$release" = "ubuntu" ]; then
        apt_screen_check
    elif [ "$release" = "debian" ]; then
        apt_screen_check
    else
        echo "目前暂时不支持此系统。"
    fi
    login_screen
    systemctl start $SERVICE_NAME >>/dev/null 2>&1
    echo "PagerMaid ($INSTALL_NAME) 已重新登录完成"
}

stop_pager() {
    if ! select_existing_instance "关闭"; then
        shon_online
        return
    fi
    
    echo ""
    echo "正在关闭 PagerMaid ($INSTALL_NAME). . ."
    systemctl stop $SERVICE_NAME >>/dev/null 2>&1
    echo "已停止 PagerMaid ($INSTALL_NAME)"
    sleep 2
}

start_pager() {
    if ! select_existing_instance "启动"; then
        shon_online
        return
    fi
    
    echo ""
    echo "正在启动 PagerMaid ($INSTALL_NAME). . ."
    systemctl start $SERVICE_NAME >>/dev/null 2>&1
    echo "已启动 PagerMaid ($INSTALL_NAME)"
    sleep 2
}

restart_pager() {
    if ! select_existing_instance "重启"; then
        shon_online
        return
    fi
    
    echo ""
    echo "正在重新启动 PagerMaid ($INSTALL_NAME). . ."
    systemctl restart $SERVICE_NAME >>/dev/null 2>&1
    echo "已重启 PagerMaid ($INSTALL_NAME)"
    sleep 2
}

install_require() {
    if ! select_existing_instance "重新安装依赖"; then
        shon_online
        return
    fi
    
    echo "正在为 PagerMaid ($INSTALL_NAME) 重新安装依赖..."
    if [ "$release" = "centos" ]; then
        echo "系统检测通过。"
        yum_update
        yum_git_check
        yum_screen_check
        yum_require_install
        cd $INSTALL_PATH
        source $INSTALL_PATH/venv/bin/activate
        export PYV=$INSTALL_PATH/venv/bin/python3
        pypi_install
        systemctl restart $SERVICE_NAME >>/dev/null 2>&1
        echo "PagerMaid ($INSTALL_NAME) 依赖已重新安装完成"
    elif [ "$release" = "ubuntu" ]; then
        echo "系统检测通过。"
        apt_update
        apt_git_check
        apt_screen_check
        apt_require_install
        cd $INSTALL_PATH
        source $INSTALL_PATH/venv/bin/activate
        export PYV=$INSTALL_PATH/venv/bin/python3
	    check_and_install_venv
        pypi_install
        systemctl restart $SERVICE_NAME >>/dev/null 2>&1
        echo "PagerMaid ($INSTALL_NAME) 依赖已重新安装完成"
    elif [ "$release" = "debian" ]; then
        echo "系统检测通过。"
        apt_update
        apt_git_check
        apt_screen_check
        debian_require_install
        cd $INSTALL_PATH
        source $INSTALL_PATH/venv/bin/activate
        export PYV=$INSTALL_PATH/venv/bin/python3
	    check_and_install_venv
        pypi_install
        systemctl restart $SERVICE_NAME >>/dev/null 2>&1
        echo "PagerMaid ($INSTALL_NAME) 依赖已重新安装完成"
    else
        echo "目前暂时不支持此系统。"
    fi
}

list_installations() {
    echo "==============================================================="
    echo "已安装的 PagerMaid 实例:"
    echo "==============================================================="
    
    local count=0
    
    # 1. 首先查找所有PagerMaid服务文件
    for service_file in /etc/systemd/system/*.service; do
        if [ -f "$service_file" ]; then
            # 检查是否是PagerMaid服务
            if grep -q "PagerMaid-Pyro" "$service_file"; then
                local name=$(basename "$service_file" .service)
                local dir="/var/lib/$name"
                local status="未知"
                
                # 检查服务状态
                if systemctl is-active "$name.service" &>/dev/null; then
                    status=$(systemctl is-active "$name.service")
                fi
                
                # 尝试获取版本信息
                local version="未知"
                version=$(grep "Description" "$service_file" | grep -o "PagerMaid-Pyro [^ ]*" | awk '{print $2}')
                if [ -z "$version" ]; then
                    version="未知"
                fi
                
                echo "- $name (版本: $version, 状态: $status, 目录: $dir)"
                count=$((count+1))
            fi
        fi
    done
    
    # 2. 扫描/var/lib目录下所有可能的PagerMaid安装，但尚未创建服务
    for dir in /var/lib/*; do
        if [ -d "$dir" ] && [ -f "$dir/pagermaid/__init__.py" ]; then
            local name=$(basename "$dir")
            local service_exists=false
            
            # 检查此目录是否已作为服务列出
            for service_file in /etc/systemd/system/*.service; do
                if [ -f "$service_file" ] && grep -q "PagerMaid-Pyro" "$service_file"; then
                    local service_name=$(basename "$service_file" .service)
                    if [ "$service_name" = "$name" ]; then
                        service_exists=true
                        break
                    fi
                fi
            done
            
            # 如果还没有列出该目录
            if [ "$service_exists" = false ]; then
                echo "- $name (版本: 未知, 状态: 无服务, 目录: $dir)"
                count=$((count+1))
            fi
        fi
    done
    
    if [ $count -eq 0 ]; then
        echo "未找到任何 PagerMaid 安装实例"
    fi
    
    echo "==============================================================="
    echo ""
}

shon_online() {
    echo -e "\033[1;34msunmoon基于原作者一键安装脚本修改，一键安装旧版人形和框架\033[0m"
    echo ""
    echo -e "\033[1;34m改动：加入虚拟环境\033[0m"
    echo -e "\033[1;34m改动：支持多账号同时运行 (不同目录安装)\033[0m"
    echo -e "\033[1;34m改动：支持多版本安装选择 (1.4.12/1.4.14/最新版)\033[0m"
    echo -e "\033[1;34m改动：去掉日志记录的询问，默认不开启日志记录\033[0m"
    echo -e "\033[1;34m改动：改进实例检测，支持任意名称实例\033[0m"
    echo ""
    echo ""
    echo "一键脚本出现任何问题请转手动搭建！ xtaolabs.com"
    echo ""
    
    # 显示已安装的实例
    list_installations
    
    echo "请选择您需要进行的操作:"
    echo "  1) 安装 PagerMaid"
    echo "  2) 卸载 PagerMaid"
    echo "  3) 重新安装 PagerMaid"
    echo "  4) 重新登陆 PagerMaid"
    echo "  5) 关闭 PagerMaid"
    echo "  6) 启动 PagerMaid"
    echo "  7) 重新启动 PagerMaid"
    echo "  8) 重新安装 PagerMaid 依赖"
    echo "  9) 查看已安装的 PagerMaid 实例"
    echo "  0) 退出脚本"
    echo ""
    echo "     Version：2.2.0 (任意命名实例支持版)"
    echo ""
    echo -n "请输入编号: "
    read N
    case $N in
    1) start_installation ;;
    2) cleanup ;;
    3) reinstall ;;
    4) cleansession ;;
    5) stop_pager ;;
    6) start_pager ;;
    7) restart_pager ;;
    8) install_require ;;
    9) list_installations; shon_online ;;
    0) exit ;;
    *) echo "输入错误！"; shon_online ;;
    esac
}

check_sys
shon_online
