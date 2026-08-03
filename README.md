# Arch Linux + Hyprland 安装脚本

参考: [huangyingwen/Arch-Setup-Script](https://github.com/huangyingwen/Arch-Setup-Script/blob/main/install.sh)（fork 自 patarapolw/arch-btrfs）与 [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland)。

## ⚠️ 警告

`01-install-base.sh` 会**清空整块所选磁盘**，运行前请确认磁盘选择正确，并提前备份重要数据。

## 文件说明

| 文件                       | 运行环境                               | 说明                                                                        |
| -------------------------- | -------------------------------------- | --------------------------------------------------------------------------- |
| `01-install-base.sh`     | Arch 官方安装 ISO 的 live 环境（root） | 分区、格式化、安装基础系统、中文字体/输入法、btrfs 子卷、zram swap          |
| `02-install-hyprland.sh` | 装好后的系统，普通用户登录             | 安装 Hyprland 平铺窗口管理器（end-4/dots-hyprland）                         |
| `03-mount-for-repair.sh` | Arch 官方安装 ISO 的 live 环境（root） | 系统崩溃/无法启动时，按固定分区标签挂载已安装好的系统并自动 chroot 进去维护 |

## 使用步骤

1. 用 Arch 官方 ISO 启动机器（UEFI 模式）。
2. 联网后执行：
   ```bash
   curl -O https://<你的托管地址>/01-install-base.sh
   chmod +x 01-install-base.sh
   ./01-install-base.sh
   ```

   按提示输入磁盘、ESP/根分区大小、用户名/密码/主机名等信息。根分区大小需要显式指定
   （不会自动占满剩余磁盘空间，方便你把尾部空间留给其他用途，比如双系统、额外分区）。
3. 安装完成后 `reboot`，进入新系统，以你创建的**普通用户**登录（图形环境此时还没有 Hyprland，可先用 tty 或 SDDM 里的其他 fallback session，若无 fallback 可用 `Ctrl+Alt+F2` 切换到 tty 登录）。
4. 执行：
   ```bash
   chmod +x 02-install-hyprland.sh
   ./02-install-hyprland.sh
   ```
5. 完成后注销，在 SDDM 登录界面选择 Hyprland 会话。

## 分区方案

```
disk
├── ESP    (fat32)  -> /boot/efi   独立 EFI 分区，大小由你输入（默认 512M）
├── root   (btrfs)   -> /           大小由你输入（必填，无默认值）
└── (未分配空间)                    留给其他用途，例如日后新增分区、双系统
    ├── @                         -> /（/boot 是这个子卷里的普通目录，不单独分区/分卷）
    ├── @home                     -> /home
    ├── @root                     -> /root
    ├── @snapshots                -> /.snapshots                (snapper 管理)
    ├── @srv                      -> /srv
    ├── @var_log                  -> /var/log                   (nodatacow)
    ├── @var_cache                -> /var/cache                 (nodatacow)
    ├── @tmp                      -> /tmp                       (nodatacow)
    ├── @var_tmp                  -> /var/tmp                   (nodatacow)
    ├── @var_spool                -> /var/spool                 (nodatacow)
    ├── @var_lib_docker           -> /var/lib/docker             (nodatacow)
    ├── @var_lib_libvirt_images   -> /var/lib/libvirt/images      (nodatacow)
    ├── @var_lib_machines         -> /var/lib/machines            (nodatacow)
    ├── @var_lib_sddm             -> /var/lib/sddm                (nodatacow)
    └── @var_lib_AccountsService  -> /var/lib/AccountsService     (nodatacow)
```

只有两个分区：**ESP** 和 **root**。没有独立 `/boot` 分区，也没有 swap 分区：

- **`/boot` 就是根子卷 `@` 里的一个普通目录**，不是单独的分区也不是单独的子卷。GRUB
  原生支持从 btrfs 读取内核/initramfs，`grub-btrfs` 会根据当前挂载的子卷生成菜单。
  这样带来一个直接的好处：snapper 对根分区打快照时会**自动把 `/boot` 一起打进去**，
  回滚到某个快照时，内核、initramfs、GRUB 配置会跟着一起回到那个时间点的一致状态，
  不需要像独立分区那样另外维护一套 rsync/tar 备份机制。
- **swap 用 zram 代替**，见下方「zram swap」章节，不占用磁盘空间。

**根分区大小必须显式输入**：脚本不会自动占满磁盘剩余空间，根分区之后如果还有空闲，
会原样留在磁盘上不动，你可以之后自己用来建别的分区（装其他系统、单独数据盘等）。

**btrfs 子卷划分**参考了 [huangyingwen/Arch-Setup-Script](https://github.com/huangyingwen/Arch-Setup-Script/blob/main/install.sh)
（fork 自 patarapolw/arch-btrfs 那套针对桌面场景的加固方案），思路分两类：

- **nodatacow 类**：`/var/log` `/var/cache` `/tmp` `/var/tmp` `/var/spool` 这些高频写入、
  内容本身就是易失/可重建数据的目录，关掉 CoW 减少写放大，体积增长快也没必要挤进
  snapper 快照占地方。
- **快照隔离类**：`/home` `/root` `/srv` `/var/lib/docker` `/var/lib/libvirt/images`
  `/var/lib/machines` 这些属于"数据"而不是"系统状态"，独立成子卷后就不会在根分区
  snapper 回滚时被一起"传送"回去——比如你回滚系统配置，不应该连带把昨天新建的
  虚拟机镜像也删掉。
- `/var/lib/sddm` `/var/lib/AccountsService` 单独分出，是因为如果以后把根快照设为
  只读默认子卷（更彻底的加固方案），sddm 仍需要写这两个目录，官方 wiki 也建议独立出来。

相比参考脚本，本脚本**去掉了这几类子卷**，原因：

| 去掉的子卷               | 原因                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------- |
| `@boot`、`@cryptkey` | `/boot` 现在直接是 `@` 里的普通目录，不需要单独子卷；也没有 LUKS，不需要 cryptkey |
| `@var_crash`           | 桌面场景很少主动分析 crash dump，如果你需要可以自己按同样方式加一个                   |
| `@var_lib_ollama`      | 参考脚本的作者本地跑 ollama，这里默认不装，如果你会用可以照葫芦画瓢加一个子卷         |

如果你确实需要 docker / libvirt / ollama 之外的其他工作负载专属子卷（比如某个数据库的数据目录），
可以在 `01-install-base.sh` 里模仿现有写法（创建子卷 + 挂载）加一份，并同步在
`03-mount-for-repair.sh` 的 `SUBVOLS` 数组里加对应的一行，否则系统崩溃后用它挂载维护时会漏挂。

## zram swap

不再创建物理 swap 分区，改用 `zram-generator`，配置写在 `/etc/systemd/zram-generator.conf`：

```ini
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
```

`zram-size = min(ram / 2, 8192)` 表示取"内存的一半"和"8GiB"中较小值作为压缩后的 zram
容量（实际能放进去的数据量因为压缩通常是这个数字的 2-3 倍）。开机时 `systemd-zram-generator`
会自动创建并启用这块 swap，不需要手动 `systemctl enable`，也不需要写 fstab。如果你的机器
内存较小（比如 ≤4GiB），可以把 `ram / 2` 改成 `ram`，即整个内存大小都拿来做压缩 swap 上限。

## 系统崩溃/无法启动时的维护

如果系统坏到进不去（GRUB 挂了、mkinitcpio 生成失败、忘记密码等），用 Arch 官方 ISO 启动机器，
联网后运行：

```bash
chmod +x 03-mount-for-repair.sh
./03-mount-for-repair.sh
```

它会按固定的分区标签（`ESP` / `root`，都是 `01-install-base.sh` 分区时打上的）自动找到
对应分区，按与安装时一致的选项把所有 btrfs 子卷（含 `/boot`，它就在 `@` 子卷里，随 `@`
一起挂载出来）和 `/boot/efi` 全部挂载到 `/mnt` 下，然后自动 `arch-chroot` 进去，退出 chroot
shell 时会自动卸载所有挂载点，不用担心漏卸载。常见用途：

- 重新生成 GRUB 配置：`grub-mkconfig -o /boot/grub/grub.cfg`
- 重新生成 initramfs：`mkinitcpio -P`
- 忘记密码：`passwd <用户名>`
- 直接在 chroot 里执行 `snapper -c root rollback <编号>` 手动回滚
- 单纯想在文件层面进去看/改点东西

只想挂载、不进 chroot，可以加参数：`./03-mount-for-repair.sh --no-chroot`，结束后自己
`umount -R /mnt` 卸载。

## 备份与恢复

- `snapper-timeline.timer` 自动定时快照，`snapper-cleanup.timer` 自动清理旧快照。
- `grub-btrfsd.service` 会把快照自动写入 GRUB 菜单，可直接从快照启动。
- 回滚方法（`snapper rollback` 可以直接在当前运行的系统里执行，不需要先从快照启动）：
  1. `sudo snapper -c root list` 查看快照列表和编号。
  2. `sudo snapper -c root rollback <编号>`。命令会先自动创建一份当前状态的快照，
     再把选中的快照设为新的默认子卷。
  3. 重启后即进入回滚后的状态（**`/boot` 会一起回滚**，内核/initramfs/GRUB 配置和根
     文件系统状态自动保持一致）；原来的快照仍会保留，可再次切换。
  4. 如果系统已经进不去，用上面的 `03-mount-for-repair.sh` 挂载后 chroot 进去再执行
     上面两条命令。

## 中文支持

系统语言默认保持英文 (`LANG=en_US.UTF-8`)，同时：

- 已生成 `zh_CN.UTF-8` locale，可在需要的场景下临时使用，例如 `LC_ALL=zh_CN.UTF-8 <命令>`。
- 已安装中文字体：`inter-font` `adobe-source-serif-fonts` `noto-fonts-cjk` `noto-fonts-emoji` `ttf-sarasa-gothic`。
- 已安装 fcitx5 中文输入法（`fcitx5` + `fcitx5-chinese-addons` + `fcitx5-gtk` + `fcitx5-qt`），
  环境变量已写入 `/etc/environment`；`02-install-hyprland.sh` 会自动在 `hyprland.conf`
  中添加 `exec-once = fcitx5 -d` 保证登录 Hyprland 后自动启动输入法。
- 首次使用可运行 `fcitx5-configtool` 添加拼音输入方案。

如果希望系统整体切换为中文界面，把 `/etc/locale.conf` 里的 `LANG=en_US.UTF-8` 改为
`LANG=zh_CN.UTF-8` 即可（本脚本按你的要求默认保持英文）。
