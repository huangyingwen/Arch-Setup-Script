# quickshell Qt 版本不匹配排查与修复

## 症状

重启进入 Hyprland 桌面后，quickshell（面板 / shell）无法启动，日志报错：

```
WARN qt.qpa.xcb: could not connect to display
WARN qt.qpa.plugin: From 6.5.0, xcb-cursor0 or libxcb-cursor0 is needed to load the Qt xcb platform plugin.
FATAL: This application failed to start because no Qt platform plugin could be initialized.

Available platform plugins are: eglfs, linuxfb, minimal, minimalegl, offscreen, vkkhrdisplay, vnc, wayland-brcm, wayland-egl, wayland, xcb.

ERROR: Quickshell has crashed under pid XXXX
ERROR: Quickshell crashed within 10 seconds of launching. Not restarting to avoid a crash loop.
```

典型表现：Hyprland 桌面能正常启动（光标可见、快捷键可用），但面板、通知中心等 quickshell 组件全部消失。

## 根本原因

quickshell 依赖 **Qt 私有 API**（`QtWaylandClient`），这些私有 API 在不同 Qt 小版本之间没有 ABI 兼容保证。

dots-hyprland 通过预编译的 `.pkg.tar.zst` 包安装 `illogical-impulse-quickshell-git`，编译时的 Qt 版本与系统实际运行的 Qt 版本不一致时，wayland 平台插件初始化失败：

1. Qt 尝试加载 wayland 后端 → 因私有 API 符号不匹配，初始化失败
2. Fallback 到 xcb 后端 → 纯 Wayland 环境没有 X server，连接被拒绝
3. 所有平台插件均不可用 → crash

**最常见触发场景**：`02-desktop.sh` 先执行 `pacman -Syu`（更新 Qt 到最新），再通过 dots-hyprland 在线脚本安装预编译的 quickshell（用旧 Qt 编译），两者版本脱节。

## 排查步骤

### 1. 确认 quickshell 是否已安装

```bash
pacman -Qi illogical-impulse-quickshell-git
```

### 2. 对比 Qt 版本与 quickshell 编译时间

```bash
# 系统 Qt 版本
pacman -Q qt6-base

# quickshell 编译时间 & 版本
pacman -Qi illogical-impulse-quickshell-git | grep -E "Version|Build Date"
```

如果 quickshell 的 Build Date 明显早于 `pacman -Syu` 的执行时间（即 Qt 最近更新过），说明存在版本不匹配。

### 3. 手动测试 quickshell 是否能启动

```bash
# 先杀掉残留进程
killall -9 qs quickshell 2>/dev/null

# 尝试启动（加调试日志）
QT_DEBUG_PLUGINS=1 quickshell --help 2>&1 | grep -iE "wayland|fail|error|cannot"

# 或直接尝试加载配置
QT_QPA_PLATFORM=wayland quickshell -p ~/.config/quickshell/ii/shell.qml
```

如果 `--help` 能正常输出但加载 shell.qml 时 crash，可以基本确认是 ABI 不匹配。

### 4. 检查 quickshell 的 Qt 链接情况

```bash
# 查看链接的 Qt 库版本
ldd /usr/bin/quickshell | grep -i qt

# 对比系统 Qt 库
pacman -Ql qt6-base | grep "libQt6.*\.so"
```

## 修复方法

### 方法一：从源码重编译（推荐）

dots-hyprland 在缓存中保留了 PKGBUILD，直接用它从源码编译：

```bash
cd ~/.cache/dots-hyprland/sdata/dist-arch/illogical-impulse-quickshell-git
makepkg -si --noconfirm
```

- `-s`：自动安装缺失的编译依赖
- `-i`：编译完成后直接安装
- `--noconfirm`：跳过确认

> **注意**：不要加 `--needed`，否则 `pacman -U` 看到同名同版本包会跳过安装，旧的二进制不会被替换。

编译耗时约 5–15 分钟（取决于机器性能），完成后重启 Hyprland 或直接运行：

```bash
killall qs quickshell; qs -c ii &
```

### 方法二：从 AUR 安装 quickshell-git

如果 dots-hyprland 缓存的 PKGBUILD 版本过老、编译失败，可改用 AUR：

```bash
# 先卸载 dots-hyprland 版本
sudo pacman -Rdd illogical-impulse-quickshell-git

# 从 AUR 安装（始终从源码编译，版本最新）
yay -S --noconfirm quickshell-git
```

> AUR 版本提供 `quickshell` + `quickshell-git`，与 dots-hyprland 版本冲突。

### 方法三：强制重装 dots-hyprland 预编译包

如果 dots-hyprland 的预编译包版本刚好与系统 Qt 兼容（小概率），可以尝试强制重装：

```bash
sudo pacman -S --force $(ls -t ~/.cache/dots-hyprland/sdata/dist-arch/illogical-impulse-quickshell-git/*.pkg.tar.zst | head -1)
```

一般不建议，因为预编译包的 Qt 版本是固定的。

## 预防措施

在 `pacman -Syu` 升级系统后，如果 Qt 有小版本更新（如 6.9 → 6.10），需要**同步重编译** quickshell：

```bash
# 系统更新后重编译 quickshell
cd ~/.cache/dots-hyprland/sdata/dist-arch/illogical-impulse-quickshell-git
makepkg -si --noconfirm
```

## 参考

- [quickshell-mirror/quickshell#301](https://github.com/quickshell-mirror/quickshell/issues/301) — Qt 6.10 更新后 quickshell 不工作
- Qt 6.10 将 `QtWaylandClient` 合并入 `QtBase`，相关私有 API 路径变化
- dots-hyprland 文档：<https://ii.clsty.link/zh-cn/ii-qs/01setup/>
