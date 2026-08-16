# Arch Linux + Hyprland 安装脚本

参考：[huangyingwen/Arch-Setup-Script](https://github.com/huangyingwen/Arch-Setup-Script/blob/main/install.sh)（fork 自 patarapolw/arch-btrfs）。

## ⚠️ 警告

`01-base.sh` 启动时会询问安装模式：

- **单系统**：清空整块所选磁盘，新建 ESP + root 分区。
- **双系统**：不清空磁盘，复用已有 EFI 分区（不格式化），只在空闲空间创建 root 分区。

无论哪种模式，运行前都请确认磁盘选择正确，并提前备份重要数据。

## 文件说明

| 文件            | 运行环境                           | 说明                                                                                     |
| --------------- | ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `01-base.sh`    | Arch 安装 ISO 的 live 环境（root） | 分区、格式化、安装基础系统（含中文字体/输入法、tmux）、btrfs 子卷、zram swap。sddm 由 02 脚本安装 |
| `02-desktop.sh` | 装好后的系统，普通用户登录         | 安装 Hyprland 桌面（dots-hyprland）、SDDM（SilentSDDM 主题）、Rofi（adi1090x/rofi 主题）           |
| `03-repair.sh`  | Arch 安装 ISO 的 live 环境（root） | 系统崩溃/无法启动时，挂载系统并 chroot 维护；子卷列表 = 硬编码基线 + 注册表（或 fstab）  |
| `04-subvol.sh`  | 已安装运行中的系统（root）         | 动态添加 btrfs 子卷，同步写入 fstab 和 `/etc/btrfs-subvols.conf` 注册表                  |
| `05-os-prober-btrfs-patch.sh` | 已安装运行中的系统（root） | 修复 os-prober 对 btrfs 子卷系统的检测与引导（grub-mount 读顶层、引导路径缺子卷前缀、不加载微码），幂等可重复运行 |

## 快速开始

1. 用 Arch 官方 ISO 启动机器（UEFI 模式）。
2. 联网后执行：

   ```bash
   curl -O https://<你的托管地址>/01-base.sh
   chmod +x 01-base.sh
   ./01-base.sh
   ```

   按提示选择安装模式（单系统/双系统）、磁盘、ESP/根分区大小、用户名/密码/主机名等信息。根分区直接按 Enter 使用磁盘剩余空间（双系统为剩余空闲空间），输入数字则以 GiB 为单位使用指定大小。

3. 安装完成后 `reboot`，以你创建的**普通用户**登录（若无图形环境，用 `Ctrl+Alt+F2` 切换到 tty）。
4. 执行：

   ```bash
   chmod +x 02-desktop.sh
   ./02-desktop.sh
   ```

   脚本依次完成：
   - **dots-hyprland** — 通过在线脚本安装 Hyprland 桌面环境
   - **SDDM** — 登录管理器 + SilentSDDM 主题（catppuccin-latte 配色）
   - **Rofi** — 应用启动器 + adi1090x/rofi 主题（launcher style-5 / powermenu style-1，onedark 配色）

5. 重启后在 SDDM 登录界面选择 Hyprland 会话即可进入桌面。

---

## 基础系统

> 由 `01-base.sh` 完成，以下为关键配置说明。

### 分区方案

```
disk（单系统：清空整块盘；双系统：保留已有分区）
├── ESP         (fat32) → /boot/efi   单系统新建；双系统复用已有（无则新建，MiB，默认 512）
└── root        (btrfs)               单系统占满整块盘；双系统占满空闲空间（回车=剩余，输入数字=指定 GiB）
    ├── @                         → /（/boot 是 @ 里的普通目录，不单独分区/分卷）
    ├── @home                     → /home
    ├── @root                     → /root
    ├── @snapshots                → /.snapshots                (snapper 管理)
    ├── @srv                      → /srv
    ├── @var_log                  → /var/log                   (nodatacow)
    ├── @var_cache                → /var/cache                 (nodatacow)
    ├── @tmp                      → /tmp                       (nodatacow)
    ├── @var_tmp                  → /var/tmp                   (nodatacow)
    ├── @var_spool                → /var/spool                 (nodatacow)
    ├── @var_lib_docker           → /var/lib/docker             (nodatacow)
    ├── @var_lib_libvirt_images   → /var/lib/libvirt/images      (nodatacow)
    ├── @var_lib_machines         → /var/lib/machines            (nodatacow)
    ├── @var_lib_sddm             → /var/lib/sddm                (nodatacow)
    └── @var_lib_AccountsService  → /var/lib/AccountsService     (nodatacow)

root 分区默认占满磁盘剩余空间（双系统下为剩余空闲空间）；若手动指定了 GiB 大小，剩余空间则原样保留，可留给其他用途。
```

脚本只处理 **ESP**（单系统新建 / 双系统复用）和 **root** 两个分区，不会动磁盘上其他已有的分区。没有独立 `/boot` 分区，也没有 swap 分区：

- **`/boot` 就是根子卷 `@` 里的一个普通目录**——GRUB 原生支持从 btrfs 读取内核/initramfs，`grub-btrfs` 会根据当前挂载的子卷生成菜单。snapper 对根分区打快照时会**自动把 `/boot` 一起打进去**，回滚时内核、initramfs、GRUB 配置会跟着回到一致状态。
- **swap 用 zram 代替**（见下方），不占用磁盘空间。

**root 分区默认占满磁盘剩余空间**（双系统下为剩余空闲空间）：直接按 Enter 即可；若指定了 GiB 大小，剩余空间会原样保留，你可以自己建别的分区。

**btrfs 子卷划分**思路分三类：

| 类型      | 子卷                                                                                   | 说明                                             |
| --------- | -------------------------------------------------------------------------------------- | ------------------------------------------------ |
| 快照隔离  | `@home` `@root` `@srv` `@var_lib_docker` `@var_lib_libvirt_images` `@var_lib_machines` | 数据类目录独立成子卷，根分区回滚时不会被带回去   |
| nodatacow | `@var_log` `@var_cache` `@tmp` `@var_tmp` `@var_spool`                                 | 高频写入 / 易失目录，关掉 CoW 减少写放大         |
| 服务可写  | `@var_lib_sddm` `@var_lib_AccountsService`                                             | 根快照设为只读默认子卷时 sddm 仍需写入，独立出来 |

相比参考脚本去掉的子卷：

| 去掉的子卷           | 原因                                                                      |
| -------------------- | ------------------------------------------------------------------------- |
| `@boot`、`@cryptkey` | `/boot` 是 `@` 里的普通目录，不需要单独子卷；也没有 LUKS，不需要 cryptkey |
| `@var_crash`         | 桌面场景很少分析 crash dump，如需可自行添加                               |
| `@var_lib_ollama`    | 默认不装 ollama，如需可照葫芦画瓢加一个                                   |

**动态添加子卷**：已安装好的系统上用 `04-subvol.sh` 添加子卷，它会同时写入 `/etc/fstab` 和 `/etc/btrfs-subvols.conf` 注册表。`03-repair.sh` 修复挂载时自动从注册表发现动态子卷（`--from-fstab` 可切换为从 fstab 解析），无需手动同步子卷列表。

### zram swap

不再创建物理 swap 分区，改用 `zram-generator`。配置 `/etc/systemd/zram-generator.conf`：

```ini
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
```

`zram-size = min(ram / 2, 8192)` 取"内存的一半"和"8GiB"中较小值。开机时 `systemd-zram-generator` 自动创建启用，不需要手动 `systemctl enable` 或写 fstab。小内存机器（≤4GiB）可改为 `ram`。

### mkinitcpio 优化

`/etc/mkinitcpio.conf` 的调整：

- **HOOKS**：`(base udev autodetect modconf block filesystems keyboard)`，去掉了 `microcode`（GRUB 自动拼接 `intel-ucode.img`/`amd-ucode.img`，不需要 hook）和 `fsck`（btrfs 无开机自动 fsck）。
- **MODULES**：不手动声明 `btrfs`——`filesystems` hook 会自动收入已加载的根文件系统模块，单分区场景不需要。
- **压缩**：`COMPRESSION="zstd"` + `COMPRESSION_OPTIONS=(-3)`，降低等级缩短 `mkinitcpio -P` 构建时间。

### 中文支持

系统语言默认英文 (`LANG=en_US.UTF-8`)，同时：

- 已生成 `zh_CN.UTF-8` locale，可临时使用：`LC_ALL=zh_CN.UTF-8 <命令>`
- 已安装中文字体：`inter-font` `adobe-source-serif-fonts` `noto-fonts-cjk` `noto-fonts-emoji` `ttf-sarasa-gothic`
- 已安装 fcitx5（`fcitx5` + `fcitx5-chinese-addons` + `fcitx5-gtk` + `fcitx5-qt`），环境变量写入 `/etc/environment`，Hyprland 自启动由 dotfiles repo 管理
- 首次使用运行 `fcitx5-configtool` 添加拼音输入方案

切换到全中文界面：`/etc/locale.conf` 改为 `LANG=zh_CN.UTF-8`。

---

## 桌面环境

> 由 `02-desktop.sh` 完成。

```
桌面环境
├── WM / Shell       → Hyprland (dots-hyprland)
├── 登录管理器        → SDDM + SilentSDDM 主题
├── 应用启动器        → Rofi + adi1090x/rofi 主题
└── 输入法           → fcitx5 (dotfiles 管理)
```

| 组件       | 选型                                                        | 说明                                                             |
| ---------- | ----------------------------------------------------------- | ---------------------------------------------------------------- |
| WM         | [dots-hyprland](https://ii.clsty.link/zh-cn/ii-qs/01setup/) | Hyprland + 全套 dotfiles，通过在线脚本安装                       |
| 登录管理器 | [SDDM](https://github.com/sddm/sddm)                        | Qt6 原生，Wayland 模式运行，配置通过 sed 精确修改                |
| 登录主题   | [SilentSDDM](https://github.com/uiriansan/SilentSDDM)       | catppuccin-latte 配色，支持虚拟键盘                              |
| 应用启动器 | [Rofi](https://github.com/davatorium/rofi)                  | Wayland 原生，modi: drun / run / filebrowser / window            |
| Rofi 主题  | [adi1090x/rofi](https://github.com/adi1090x/rofi)           | launcher type-1 style-5 + powermenu type-1 style-1，onedark 配色 |

### 配置方式

SDDM 和 Rofi 均**不覆盖整个配置文件**，而是通过 `sed` 精确修改指定字段：

| 目标文件                                             | 修改内容                                                   |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| `/etc/sddm.conf`                                     | DisplayServer / GreeterEnvironment / InputMethod / Current |
| `/usr/share/sddm/themes/silent/metadata.desktop`     | ConfigFile → catppuccin-latte                              |
| `~/.config/rofi/launchers/type-1/launcher.sh`        | theme → style-5                                            |
| `~/.config/rofi/launchers/type-1/shared/colors.rasi` | @import → onedark                                          |
| `~/.config/rofi/powermenu/type-1/powermenu.sh`       | theme → style-1                                            |
| `~/.config/rofi/powermenu/type-1/shared/colors.rasi` | @import → onedark                                          |

---

## 备份与恢复

- `snapper-timeline.timer` 自动定时快照，`snapper-cleanup.timer` 自动清理旧快照。
- `grub-btrfsd.service` 把快照自动写入 GRUB 菜单，可直接从快照启动。
- 回滚（可在当前运行系统中直接执行）：
  1. `sudo snapper -c root list` 查看快照列表
  2. `sudo snapper -c root rollback <编号>`（自动创建当前状态快照，再切换默认子卷）
  3. 重启后即进入回滚状态（**`/boot` 一起回滚**，内核和系统状态一致）

  如果系统已经进不去，用 `03-repair.sh` 挂载后 chroot 再执行上面命令。

## 系统修复

系统崩溃/无法启动时（GRUB 挂了、mkinitcpio 失败、忘记密码等），用 Arch ISO 启动后：

```bash
chmod +x 03-repair.sh
./03-repair.sh
```

自动检测 EFI 分区（GPT 类型）和 root 分区（标签 `root`），挂载所有 btrfs 子卷到 `/mnt`，然后 chroot 进去。退出 shell 时自动卸载。常见用途：

- 重新生成 GRUB 配置：`grub-mkconfig -o /boot/grub/grub.cfg`
- 重新生成 initramfs：`mkinitcpio -P`
- 忘记密码：`passwd <用户名>`
- 手动回滚：`snapper -c root rollback <编号>`

只想挂载不进 chroot：`./03-repair.sh --no-chroot`。如果注册表损坏或丢失，可用 `--from-fstab` 改为从 `/etc/fstab` 解析子卷：`./03-repair.sh --from-fstab`。两个参数可组合使用。
