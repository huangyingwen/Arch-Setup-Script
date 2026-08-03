#!/bin/bash
#
# 02-install-hyprland.sh — 安装 Hyprland 桌面环境 (end-4/dots-hyprland)
#
# 用法：重启进入刚安装好的系统，以你创建的普通用户登录（不要用 root），
# 然后运行:
#   chmod +x 02-install-hyprland.sh
#   ./02-install-hyprland.sh
#
# 参考: https://github.com/end-4/dots-hyprland
#
set -eu

output() {
    printf '\e[1;34m%-6s\e[m\n' "${@}"
}

err() {
    printf '\e[1;31m%-6s\e[m\n' "${@}" >&2
}

if [ "$(id -u)" -eq 0 ]; then
    err '请不要以 root 身份运行本脚本，用你日常使用的普通用户账户运行。'
    exit 1
fi

if ! command -v sudo >/dev/null; then
    err '未找到 sudo，请检查基础安装是否完整。'
    exit 1
fi

output '更新系统并安装基础构建依赖 ...'
sudo pacman -Syu --needed --noconfirm git base-devel

# ---------------------------------------------------------------------------
# 安装 AUR helper (yay)，dots-hyprland 的部分依赖需要从 AUR 安装
# ---------------------------------------------------------------------------
if ! command -v yay >/dev/null; then
    output '安装 yay (AUR helper) ...'
    tmpdir=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "${tmpdir}/yay-bin"
    (cd "${tmpdir}/yay-bin" && makepkg -si --noconfirm)
    rm -rf "${tmpdir}"
fi

# ---------------------------------------------------------------------------
# 克隆并安装 dots-hyprland
# ---------------------------------------------------------------------------
TARGET_DIR="${HOME}/dots-hyprland"

if [ -d "${TARGET_DIR}" ]; then
    output "${TARGET_DIR} 已存在。"
    read -r -p '重新拉取最新代码并覆盖？(y/N): ' choice
    if [ "${choice}" = 'y' ] || [ "${choice}" = 'Y' ]; then
        rm -rf "${TARGET_DIR}"
        git clone --recursive https://github.com/end-4/dots-hyprland.git "${TARGET_DIR}"
    fi
else
    output '克隆 dots-hyprland ...'
    git clone --recursive https://github.com/end-4/dots-hyprland.git "${TARGET_DIR}"
fi

cd "${TARGET_DIR}"

output '运行安装脚本 (./setup install) ...'
output '安装过程中会提示各类可选组件，按需选择即可。'
./setup install

# ---------------------------------------------------------------------------
# fcitx5 中文输入法自启动（环境变量已在基础安装阶段写入 /etc/environment）
# ---------------------------------------------------------------------------
HYPR_CONF="${HOME}/.config/hypr/hyprland.conf"
if [ -f "${HYPR_CONF}" ] && ! grep -q 'exec-once = fcitx5' "${HYPR_CONF}"; then
    output '在 hyprland.conf 中添加 fcitx5 自启动 ...'
    echo 'exec-once = fcitx5 -d' >> "${HYPR_CONF}"
fi

output '完成。注销后在登录管理器 (SDDM) 选择 Hyprland 会话登录即可。'
output '如需切换中文输入法，可运行 fcitx5-configtool 添加拼音输入法方案。'
