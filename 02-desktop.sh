#!/bin/bash
#
# 02-desktop.sh — 安装 Hyprland 桌面环境 (dots-hyprland)
#
# 用法：重启进入刚安装好的系统，以你创建的普通用户登录（不要用 root），
# 然后运行:
#   chmod +x 02-desktop.sh
#   ./02-desktop.sh
#
# 参考:
#   - dots-hyprland: https://ii.clsty.link/zh-cn/ii-qs/01setup/
#   - SDDM 主题: https://github.com/uiriansan/SilentSDDM
#   - Rofi 主题: https://github.com/adi1090x/rofi
#
set -euo pipefail

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
  cd "${tmpdir}/yay-bin"
  makepkg -si --noconfirm
  rm -rf "${tmpdir}"
fi

# ===========================================================================
# 1. 安装 dots-hyprland（在线脚本，使用默认目录）
# ===========================================================================
output '通过在线脚本安装 dots-hyprland ...'
output '脚本来源: https://ii.clsty.link/zh-cn/ii-qs/01setup/'
output '默认克隆到 ~/.cache/dots-hyprland'

bash <(curl -s https://ii.clsty.link/get)

# ===========================================================================
# 2. 安装 Rofi 启动器 + adi1090x/rofi 主题
# ===========================================================================
output '安装 Rofi ...'
sudo pacman -S --needed --noconfirm rofi

ROFI_THEME_DIR="${HOME}/.config/rofi"
if [ ! -f "${ROFI_THEME_DIR}/setup.sh" ]; then
  output '安装 adi1090x/rofi 主题 ...'
  tmpdir=$(mktemp -d)
  git clone --depth=1 https://github.com/adi1090x/rofi.git "${tmpdir}/rofi"
  cd "${tmpdir}/rofi"

  # 运行主题安装脚本（自动备份已有配置 → 安装字体 → 安装主题到 ~/.config/rofi）
  chmod +x setup.sh
  ./setup.sh

  rm -rf "${tmpdir}"
else
  output 'adi1090x/rofi 主题已安装，跳过。'
fi

# 配置 Rofi 主题样式和配色（参考本机配置）
output '配置 Rofi 主题 ...'
# Launcher: type-1, style-5, 配色 onedark
sed -i "s/^theme='.*'/theme='style-5'/" "${ROFI_THEME_DIR}/launchers/type-1/launcher.sh"
sed -i 's|@import .*|@import "~/.config/rofi/colors/onedark.rasi"|' "${ROFI_THEME_DIR}/launchers/type-1/shared/colors.rasi"
# Powermenu: type-1, style-1, 配色 onedark
sed -i "s/^theme='.*'/theme='style-1'/" "${ROFI_THEME_DIR}/powermenu/type-1/powermenu.sh"
sed -i 's|@import .*|@import "~/.config/rofi/colors/onedark.rasi"|' "${ROFI_THEME_DIR}/powermenu/type-1/shared/colors.rasi"
# ---------------------------------------------------------------------------
# 完成提示
# ---------------------------------------------------------------------------
output '============================================'
output '全部安装完成！'
output ''
output '  ✓ dots-hyprland (Hyprland 桌面)'
output '  ✓ Rofi (应用启动器) + adi1090x/rofi 主题'
output ''
output 'Rofi 启动器快捷方式: Super + D (通过 hyprland 配置绑定)'
