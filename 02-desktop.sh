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


# ---------------------------------------------------------------------------
# VMware 虚拟机 Hyprland 兼容配置
# vmwgfx 不完全支持 direct_scanout，需禁用否则窗口/壁纸无法渲染（黑屏但光标可见）
# ---------------------------------------------------------------------------
if systemd-detect-virt --quiet --vmware 2>/dev/null; then
    output '检测到 VMware 虚拟机，添加 Hyprland 兼容配置 ...'
    CUSTOM_DIR="${HOME}/.config/hypr/custom"
    mkdir -p "${CUSTOM_DIR}"
    # dots-hyprland 会自动 source custom/general.lua，不存在则创建
    if [ ! -f "${CUSTOM_DIR}/general.lua" ]; then
        cat > "${CUSTOM_DIR}/general.lua" <<'EOF'
-- VMware 虚拟机兼容设置
hl.config({
    misc = {
        no_direct_scanout = true,
    },
})
EOF
        output '  已禁用 direct_scanout（解决 VMware 黑屏问题）'
    else
        output '  custom/general.lua 已存在，跳过（请手动确认 direct_scanout 配置）'
    fi
fi

# ===========================================================================
# 2. 安装并配置 SDDM（登录管理器）+ SilentSDDM 主题
# ===========================================================================
output '安装 SDDM 登录管理器 ...'
sudo pacman -S --needed --noconfirm sddm qt6-svg qt6-virtualkeyboard qt6-multimedia qt6-imageformats

# 先生成默认 /etc/sddm.conf（主题安装和后续 sed 配置都依赖此文件）
if [ ! -f /etc/sddm.conf ]; then
    output '生成默认 /etc/sddm.conf ...'
    sddm --example-config | sudo tee /etc/sddm.conf > /dev/null || true
fi

# 辅助函数: 在指定 [section] 范围内设置 key=value
# 用法: sddm_set <Section> <Key> <Value>
sddm_set() {
    local section="$1" key="$2" value="$3"
    # 在 [section] 到下一个 [ 之间替换已存在的 key（含注释掉的）
    sudo sed -i "/^\[${section}\]/,/^\[/ s|^#\?${key}=.*|${key}=${value}|" /etc/sddm.conf
}

# 安装 SilentSDDM 主题
SDDM_THEME_DIR="/usr/share/sddm/themes/silent"
if [ ! -d "${SDDM_THEME_DIR}" ]; then
    output '安装 SilentSDDM 主题 ...'
    tmpdir=$(mktemp -d)
    git clone -b main --depth=1 https://github.com/uiriansan/SilentSDDM.git "${tmpdir}/SilentSDDM"
    cd "${tmpdir}/SilentSDDM"

    # 使用项目自带的安装脚本
    chmod +x install.sh
    sudo ./install.sh

    rm -rf "${tmpdir}"
else
    output 'SilentSDDM 主题已安装，跳过。'
fi

# 设置主题配色为 catppuccin-latte（参考本机配置）
output '设置 SilentSDDM 主题配色为 catppuccin-latte ...'
# 先注释掉所有已启用的 ConfigFile，再单独启用 catppuccin-latte
sudo sed -i 's/^ConfigFile=/; ConfigFile=/' "${SDDM_THEME_DIR}/metadata.desktop"
sudo sed -i 's/^; ConfigFile=configs\/catppuccin-latte\.conf/ConfigFile=configs\/catppuccin-latte.conf/' "${SDDM_THEME_DIR}/metadata.desktop"

# 配置 SDDM：通过 sed 修改现有配置，不覆盖整个文件（参照本机配置）
output '配置 SDDM ...'

# [General]
sddm_set General DisplayServer wayland
sddm_set General GreeterEnvironment "QML2_IMPORT_PATH=/usr/share/sddm/themes/silent/components/,QT_IM_MODULE=qtvirtualkeyboard,QT_SCREEN_SCALE_FACTORS=2,QT_FONT_DPI=192"
sddm_set General InputMethod qtvirtualkeyboard

# [Theme]
sddm_set Theme Current silent

# [Wayland] — HiDPI 缩放
sddm_set Wayland EnableHiDPI true

# [X11] — HiDPI 缩放 + DPI 设置（参照本机配置）
sddm_set X11 EnableHiDPI true
sddm_set X11 ServerArguments "-nolisten tcp -dpi 94"

# 启用 SDDM 服务
output '启用 SDDM 服务 ...'
sudo systemctl enable sddm.service


# ===========================================================================
# 3. 安装 Rofi 启动器 + adi1090x/rofi 主题
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
output '  ✓ SDDM (登录管理器) + SilentSDDM 主题'
output '  ✓ Rofi (应用启动器) + adi1090x/rofi 主题'
output ''
output '重启后 SDDM 登录界面将使用 SilentSDDM 主题。'
output '在登录界面选择 Hyprland 会话即可进入桌面。'
output 'Rofi 启动器快捷方式: Super + D (通过 hyprland 配置绑定)'
output ''
output '如需切换中文输入法，可运行 fcitx5-configtool 添加拼音输入法方案。'
