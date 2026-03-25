#!/bin/bash
# ============================================================
#  虚拟机初始化脚本 - 终极合并版 v3.0
#  适用系统：CentOS 7 / RHEL 7-9 / Rocky Linux 8/9
#  特性：全自动无交互，顶部变量按需修改即可
#  用法：chmod +x vm_init_final.sh && sudo bash vm_init_final.sh
# ============================================================

set -euo pipefail

# ╔══════════════════════════════════════════════════════════╗
# ║                   ★ 用户配置区 ★                        ║
# ║            按需修改以下变量，其余无需改动                ║
# ╚══════════════════════════════════════════════════════════╝

# ── 网络 ──────────────────────────────────────────────────
DNS1="114.114.114.114"
DNS2="8.8.8.8"

# ── 防火墙开放端口（空格分隔）────────────────────────────
OPEN_PORTS="22 80 443 3306 6379 8080"

# ── YUM 镜像源（aliyun / tencent）───────────────────────
YUM_MIRROR="aliyun"

# ── 时区 ──────────────────────────────────────────────────
TIMEZONE="Asia/Shanghai"

# ── 新建普通用户（留空则跳过）────────────────────────────
NEW_USER=""

# ── SSH 端口 ───────────────────────────────────────────────
SSH_PORT="22"

# ── 是否安装 Docker（yes / no）───────────────────────────
INSTALL_DOCKER="no"

# ── 是否关闭 Swap（K8s 环境必须 yes）────────────────────
DISABLE_SWAP="yes"

# ── 是否安装 EPEL 源 ──────────────────────────────────────
INSTALL_EPEL="yes"

# ══════════════════════════════════════════════════════════
#  以下内容无需修改
# ══════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# 颜色 & 日志函数
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${BLUE}[INFO]${NC}   $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $*"; }
error()   { echo -e "${RED}[ERROR]${NC}  $*"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

# 记录日志到文件
LOG_FILE="/root/vm_init_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─────────────────────────────────────────────
# 0. 环境预检
# ─────────────────────────────────────────────
step "Step 0 · 环境预检"

[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

# 检测操作系统
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_NAME="$NAME"
    OS_VER="${VERSION_ID%%.*}"   # 取主版本号 7 / 8 / 9
else
    error "无法识别操作系统"
fi

# 检测包管理器
PKG_MGR="yum"
command -v dnf &>/dev/null && PKG_MGR="dnf"

info "操作系统：${OS_NAME} ${VERSION_ID}"
info "内核版本：$(uname -r)"
info "包管理器：${PKG_MGR}"
success "环境预检通过"

# ─────────────────────────────────────────────
# 1. 自动检测网卡 & 固化静态 IP
# ─────────────────────────────────────────────
step "Step 1 · 网络配置（DHCP → 静态 IP）"

# 自动找第一块有 IP 的非 lo 网卡
IFACE=$(ip -o -4 addr show | awk '$2 != "lo" {print $2; exit}')
[[ -z "$IFACE" ]] && error "未检测到可用网卡，请检查网络连接"

STATIC_IP=$(ip -o -4 addr show dev "${IFACE}" | awk '{print $4}' | cut -d'/' -f1 | head -1)
PREFIX=$(ip -o -4 addr show dev "${IFACE}" | awk '{print $4}' | cut -d'/' -f2 | head -1)
GATEWAY=$(ip route | awk '/default/ {print $3; exit}')

[[ -z "$STATIC_IP" ]] && error "网卡 ${IFACE} 未获取到 IP，请确认 DHCP 正常"
[[ -z "$GATEWAY"   ]] && GATEWAY="${STATIC_IP%.*}.2" && warn "未检测到网关，使用兜底值：${GATEWAY}"
[[ -z "$PREFIX"    ]] && PREFIX="24"

info "检测到网卡：${IFACE}"
info "当前 IP   ：${STATIC_IP}/${PREFIX}"
info "网关      ：${GATEWAY}"

IFCFG_DIR="/etc/sysconfig/network-scripts"
IFCFG="${IFCFG_DIR}/ifcfg-${IFACE}"
[[ -f "$IFCFG" ]] && cp "${IFCFG}" "${IFCFG}.bak.$(date +%F_%T)" && info "已备份原网卡配置"

cat > "${IFCFG}" <<EOF
TYPE=Ethernet
BOOTPROTO=none
NAME=${IFACE}
DEVICE=${IFACE}
ONBOOT=yes
IPADDR=${STATIC_IP}
PREFIX=${PREFIX}
GATEWAY=${GATEWAY}
DNS1=${DNS1}
DNS2=${DNS2}
EOF

# 重启网络（兼容 NetworkManager 与旧版 network）
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    nmcli connection reload 2>/dev/null || true
    nmcli connection up "${IFACE}" 2>/dev/null || true
else
    systemctl restart network 2>/dev/null || true
fi

success "静态 IP 固化完成：${STATIC_IP}/${PREFIX}  网关：${GATEWAY}"

# ─────────────────────────────────────────────
# 2. 主机名
# ─────────────────────────────────────────────
step "Step 2 · 主机名"

CURRENT_HOSTNAME=$(hostname)
info "当前主机名：${CURRENT_HOSTNAME}（保持不变）"
# 确保 /etc/hosts 有本机记录，避免 sudo 警告
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1   ${CURRENT_HOSTNAME}" >> /etc/hosts
success "主机名配置完成"

# ─────────────────────────────────────────────
# 3. 关闭 SELinux
# ─────────────────────────────────────────────
step "Step 3 · 关闭 SELinux"

if [[ -f /etc/selinux/config ]]; then
    setenforce 0 2>/dev/null || warn "setenforce 失败（可能已是 Permissive）"
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    success "SELinux 已设为 disabled（重启后永久生效）"
else
    warn "未找到 SELinux 配置文件，跳过"
fi

# ─────────────────────────────────────────────
# 4. 配置防火墙
# ─────────────────────────────────────────────
step "Step 4 · 配置防火墙"

if systemctl list-unit-files 2>/dev/null | grep -q firewalld; then
    systemctl enable --now firewalld
    for port in ${OPEN_PORTS}; do
        firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
        info "已开放端口：${port}/tcp"
    done
    firewall-cmd --reload
    success "防火墙已启用，开放端口：${OPEN_PORTS}"
else
    warn "未检测到 firewalld，跳过防火墙配置"
fi

# ─────────────────────────────────────────────
# 5. 配置 YUM / DNF 镜像源
# ─────────────────────────────────────────────
step "Step 5 · 配置 ${YUM_MIRROR} 镜像源"

mkdir -p /etc/yum.repos.d/backup
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

case "${YUM_MIRROR}" in
    aliyun)
        if [[ "$OS_VER" == "7" ]]; then
            curl -fsSL -o /etc/yum.repos.d/CentOS-Base.repo \
                https://mirrors.aliyun.com/repo/Centos-7.repo
        elif [[ "$OS_VER" == "8" ]]; then
            curl -fsSL -o /etc/yum.repos.d/CentOS-Base.repo \
                https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
        else
            # Rocky 9 / RHEL 9
            curl -fsSL -o /etc/yum.repos.d/rocky.repo \
                https://mirrors.aliyun.com/repo/rocky-9.repo 2>/dev/null || true
        fi
        ;;
    tencent)
        curl -fsSL -o /etc/yum.repos.d/CentOS-Base.repo \
            "https://mirrors.tencent.com/repo/centos${OS_VER}_base.repo"
        ;;
    *)
        warn "未知镜像源 ${YUM_MIRROR}，跳过源配置"
        ;;
esac

if [[ "$INSTALL_EPEL" == "yes" ]]; then
    info "安装 EPEL 源..."
    ${PKG_MGR} install -y epel-release &>/dev/null || warn "EPEL 安装失败，可忽略"
fi

${PKG_MGR} clean all &>/dev/null
${PKG_MGR} makecache &>/dev/null || ${PKG_MGR} makecache fast &>/dev/null || true
success "镜像源配置完成（${YUM_MIRROR}）"

# ─────────────────────────────────────────────
# 6. 系统更新 & 常用工具
# ─────────────────────────────────────────────
step "Step 6 · 系统更新 & 安装常用工具"

info "系统更新中（时间较长，请耐心等待）..."
${PKG_MGR} update -y -q

PACKAGES=(
    vim wget curl git unzip tar
    net-tools lsof bind-utils tcpdump
    bash-completion tree htop iotop
    sysstat rsync lrzsz nmap-ncat
)
${PKG_MGR} install -y "${PACKAGES[@]}" &>/dev/null
success "常用工具安装完成"

# ─────────────────────────────────────────────
# 7. 时区 & 时间同步
# ─────────────────────────────────────────────
step "Step 7 · 时区 & NTP 时间同步"

timedatectl set-timezone "${TIMEZONE}"

if ! ${PKG_MGR} list installed chrony &>/dev/null 2>&1; then
    ${PKG_MGR} install -y chrony &>/dev/null
fi
systemctl enable --now chronyd
chronyc makestep &>/dev/null || true

success "时区：${TIMEZONE}  当前时间：$(date '+%Y-%m-%d %H:%M:%S')"

# ─────────────────────────────────────────────
# 8. SSH 安全加固
# ─────────────────────────────────────────────
step "Step 8 · SSH 安全加固"

SSHD_CFG="/etc/ssh/sshd_config"
cp "${SSHD_CFG}" "${SSHD_CFG}.bak"

# 修改端口
sed -i "s/^#Port 22$/Port ${SSH_PORT}/" "${SSHD_CFG}"
sed -i "s/^Port 22$/Port ${SSH_PORT}/"  "${SSHD_CFG}"

# 性能优化（关闭 DNS 反解 & GSSAPI，加快登录速度）
sed -i 's/^#UseDNS.*/UseDNS no/'                              "${SSHD_CFG}"
sed -i 's/^UseDNS.*/UseDNS no/'                               "${SSHD_CFG}"
sed -i 's/^#GSSAPIAuthentication.*/GSSAPIAuthentication no/'  "${SSHD_CFG}"
sed -i 's/^GSSAPIAuthentication.*/GSSAPIAuthentication no/'   "${SSHD_CFG}"

# 保持连接（心跳，防止超时断连）
grep -q "ClientAliveInterval" "${SSHD_CFG}" || \
    echo -e "\nClientAliveInterval 60\nClientAliveCountMax 10" >> "${SSHD_CFG}"

# 如果修改了端口，防火墙同步开放
if [[ "$SSH_PORT" != "22" ]]; then
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
fi

systemctl restart sshd
success "SSH 加固完成，端口：${SSH_PORT}"

# ─────────────────────────────────────────────
# 9. 内核参数优化
# ─────────────────────────────────────────────
step "Step 9 · 内核参数优化"

# 避免重复写入
grep -q "VM 初始化优化" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'SYSCTL'

# ── VM 初始化优化 ──────────────────────────────
# TCP 连接优化
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.ip_local_port_range = 1024 65535
# 文件系统
fs.file-max = 655350
# 内存
vm.swappiness = 10
SYSCTL

sysctl -p &>/dev/null
success "内核参数优化完成"

# ─────────────────────────────────────────────
# 10. 文件句柄 limits
# ─────────────────────────────────────────────
step "Step 10 · 系统 limits 优化"

grep -q "VM 初始化优化" /etc/security/limits.conf || cat >> /etc/security/limits.conf <<'LIMITS'

# ── VM 初始化优化 ──
* soft nofile 65535
* hard nofile 65535
* soft nproc  65535
* hard nproc  65535
LIMITS

success "limits.conf 优化完成"

# ─────────────────────────────────────────────
# 11. 关闭 Swap
# ─────────────────────────────────────────────
step "Step 11 · Swap 配置"

if [[ "$DISABLE_SWAP" == "yes" ]]; then
    swapoff -a
    sed -i '/\bswap\b/s/^/#/' /etc/fstab
    success "Swap 已关闭（K8s 环境推荐）"
else
    info "跳过 Swap 关闭（当前已启用）"
fi

# ─────────────────────────────────────────────
# 12. 创建普通用户（可选）
# ─────────────────────────────────────────────
step "Step 12 · 用户配置"

if [[ -n "$NEW_USER" ]]; then
    if id "$NEW_USER" &>/dev/null; then
        warn "用户 ${NEW_USER} 已存在，跳过创建"
    else
        useradd -m -s /bin/bash "$NEW_USER"
        # 生成随机密码并保存
        RAND_PASS=$(openssl rand -base64 12)
        echo "${NEW_USER}:${RAND_PASS}" | chpasswd
        echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        echo "${NEW_USER}  密码：${RAND_PASS}" > "/root/${NEW_USER}_credentials.txt"
        chmod 600 "/root/${NEW_USER}_credentials.txt"
        success "用户 ${NEW_USER} 创建完成，密码已保存至 /root/${NEW_USER}_credentials.txt"
    fi
else
    info "NEW_USER 为空，跳过用户创建"
fi

# ─────────────────────────────────────────────
# 13. 安装 Docker（可选）
# ─────────────────────────────────────────────
step "Step 13 · Docker 安装"

if [[ "$INSTALL_DOCKER" == "yes" ]]; then
    info "安装 Docker CE..."

    # 清理旧版本
    ${PKG_MGR} remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-engine 2>/dev/null || true

    ${PKG_MGR} install -y yum-utils &>/dev/null
    yum-config-manager --add-repo \
        https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

    ${PKG_MGR} install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin &>/dev/null

    # 配置镜像加速 & 日志限制
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DAEMON'
{
  "registry-mirrors": [
    "https://registry.cn-hangzhou.aliyuncs.com",
    "https://mirror.ccs.tencentyun.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "exec-opts": ["native.cgroupdriver=systemd"]
}
DAEMON

    systemctl enable --now docker
    # 当前用户加入 docker 组（如有普通用户）
    [[ -n "$NEW_USER" ]] && usermod -aG docker "$NEW_USER" || true

    success "Docker 安装完成：$(docker --version)"
else
    info "INSTALL_DOCKER=no，跳过 Docker 安装"
fi

# ─────────────────────────────────────────────
# 14. 配置 Vim & Bash 环境美化
# ─────────────────────────────────────────────
step "Step 14 · Vim & Bash 环境配置"

# Vim 配置
cat > /root/.vimrc <<'VIMRC'
set number
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set hlsearch
set ignorecase
set ruler
syntax on
set encoding=utf-8
set fileencodings=utf-8,gbk,latin1
VIMRC

# Bash 别名（避免重复写入）
grep -q "VM Init 别名" /root/.bashrc || cat >> /root/.bashrc <<'BASHRC'

# ── VM Init 别名 ──────────────────────────────
alias ll='ls -alh --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
alias vi='vim'
alias ports='ss -tulnp'
alias myip='ip addr show'
alias mymem='free -h'
alias mydisk='df -h'
alias myps='ps aux --sort=-%cpu | head -20'
alias histg='history | grep'
# 网络连通性快速检测
alias pingtest='ping -c 3 114.114.114.114'
BASHRC

source /root/.bashrc 2>/dev/null || true
success "Vim & Bash 环境配置完成"

# ─────────────────────────────────────────────
# 15. 生成初始化报告
# ─────────────────────────────────────────────
step "Step 15 · 生成初始化报告"

REPORT="/root/vm_init_report_$(date +%Y%m%d_%H%M%S).txt"

{
echo "╔══════════════════════════════════════════════╗"
echo "║          虚拟机初始化报告                    ║"
echo "╚══════════════════════════════════════════════╝"
echo "  生成时间  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  主机名    : $(hostname)"
echo "  系统版本  : $(cat /etc/redhat-release 2>/dev/null || echo "$OS_NAME $VERSION_ID")"
echo "  内核版本  : $(uname -r)"
echo ""
echo "──────────── 网络信息 ─────────────────────────"
echo "  网卡      : ${IFACE}"
echo "  IP 地址   : ${STATIC_IP}/${PREFIX}"
echo "  网关      : ${GATEWAY}"
echo "  DNS       : ${DNS1} / ${DNS2}"
echo ""
echo "──────────── 硬件资源 ─────────────────────────"
echo "  CPU 核数  : $(grep -c processor /proc/cpuinfo)"
echo "  内存大小  : $(free -h | awk '/^Mem/{print $2}')"
echo "  磁盘使用  :"
df -h | awk 'NR>1{printf "    %-20s %-8s %-8s %-8s %s\n",$1,$2,$3,$4,$5}'
echo ""
echo "──────────── 配置状态 ─────────────────────────"
echo "  SELinux   : $(getenforce 2>/dev/null || echo 'disabled')"
echo "  防火墙    : $(systemctl is-active firewalld 2>/dev/null || echo 'inactive')"
echo "  开放端口  : ${OPEN_PORTS}"
echo "  SSH 端口  : ${SSH_PORT}"
echo "  时区      : $(timedatectl | awk '/Time zone/{print $3}')"
echo "  Swap      : $(swapon --show 2>/dev/null | wc -l | awk '{if($1>0)print "已启用";else print "已关闭"}')"
echo "  YUM 源    : ${YUM_MIRROR}"
[[ "$INSTALL_DOCKER" == "yes" ]] && echo "  Docker    : $(docker --version 2>/dev/null || echo '安装失败')"
[[ -n "$NEW_USER" ]]             && echo "  新建用户  : ${NEW_USER}"
echo ""
echo "  完整日志  : ${LOG_FILE}"
echo "══════════════════════════════════════════════"
} | tee "$REPORT"

# ─────────────────────────────────────────────
# 完成
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      ✅  所有初始化步骤已全部完成！          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  报告路径：${REPORT}${NC}"
echo -e "${YELLOW}  日志路径：${LOG_FILE}${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  ⚠  建议执行 reboot 使所有配置完全生效${NC}"
echo ""
