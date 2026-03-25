# 🖥️ 虚拟机初始化脚本集

> 一键自动化初始化 Linux 虚拟机，支持 CentOS/RHEL/Rocky 和 Ubuntu，适用于学习、测试、生产环境

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-CentOS%20%7C%20Ubuntu-green.svg)]()
[![Shell](https://img.shields.io/badge/Shell-Bash-orange.svg)]()

---

## ✨ 特性

- ✅ **全自动无交互**：顶部变量配置，一键执行
- ✅ **幂等安全**：重复运行不破坏已有配置
- ✅ **多系统支持**：CentOS 7-9 / RHEL / Rocky / Ubuntu 20.04-24.04
- ✅ **克隆友好**：支持快照克隆场景，避免 IP/SSH 冲突
- ✅ **生产就绪**：内核优化、安全加固、日志审计

---

## 🚀 快速开始

### CentOS / RHEL / Rocky

```bash
# 下载脚本
curl -fsSL -o vm_init_final.sh https://raw.githubusercontent.com/YOUR_USERNAME/vm-init-scripts/main/centos/vm_init_final.sh

# 修改配置（可选）
vim vm_init_final.sh  # 编辑顶部变量区

# 执行
chmod +x vm_init_final.sh
sudo bash vm_init_final.sh

# 重启
sudo reboot
