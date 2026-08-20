# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Arch Linux 自动化安装脚本集，基于 btrfs 子卷 + snapper 快照 + Hyprland 桌面环境。脚本按顺序分为安装阶段（live ISO）、桌面配置阶段（已安装系统）、维护修复阶段（live ISO）。

## 脚本运行环境与执行顺序

| 脚本                          | 运行环境                | 用户身份 | 前置条件                       |
| ----------------------------- | ----------------------- | -------- | ------------------------------ |
| `01-base.sh`                  | Arch 安装 ISO live 环境 | root     | UEFI 引导                      |
| `02-desktop.sh`               | 已安装并重启后的系统    | 普通用户 | `01` 执行完毕                  |
| `03-repair.sh`                | Arch 安装 ISO live 环境 | root     | 系统崩溃/无法启动              |
| `04-subvol.sh`                | 已安装运行中的系统      | root     | btrfs 根分区存在               |
| `05-os-prober-btrfs-patch.sh` | 已安装运行中的系统      | root     | os-prober 已安装（双系统引导） |

## 跨脚本的关键约束

### 子卷管理（三层体系）

子卷定义分散在多处，修改时需确认所有层级：

1. **`01-base.sh`**：创建初始子卷（`btrfs su cr`）+ 创建挂载点目录（`mkdir -p`）+ 挂载（`mount`）+ `genfstab` 生成 fstab。这里的子卷列表是**源头**。

2. **`03-repair.sh`**：`BASELINE_SUBVOLS` 硬编码数组作为**兜底基线**。除此之外，修复挂载时会自动从 `/etc/btrfs-subvols.conf` 注册表读取动态添加的子卷（默认），或通过 `--from-fstab` 从 fstab 解析。子卷合并时按名称去重，动态覆盖基线同名字卷。

3. **`04-subvol.sh`**：运行中系统动态添加子卷，同时写入 `/etc/fstab` 和 `/etc/btrfs-subvols.conf` 注册表。注册表格式简单（`子卷名 挂载路径 [nodatacow]`），独立于 fstab 维护。

4. **README.md**：分区方案 ASCII 图和子卷表格需同步。

修改 `01-base.sh` 的子卷列表时，必须同步更新 `03-repair.sh` 的 `BASELINE_SUBVOLS` 数组和 README。通过 `04-subvol.sh` 动态添加的子卷无需手动同步修复脚本。

### btrfs 挂载选项

所有脚本统一使用 `MOUNT_OPTS='ssd,noatime,compress=zstd,space_cache=v2'`（`ssd` 对 SATA/NVMe 均无害，内核自动忽略不适用的优化）。修改时需保证四个脚本一致。

**根分区默认子卷**：`01-base.sh` 创建 `@` 后立即 `btrfs subvolume set-default` 把默认子卷设为 `@`，fstab 根条目**不写 `subvol=`/`subvolid=`**，靠默认子卷定位。这是 snapper rollback 的前提——rollback 通过 `set-default` 切换默认子卷实现回滚，fstab 里写死 `subvol=` 会覆盖默认子卷导致回滚失效。`03-repair.sh` 挂根同样不写 `subvol`，跟随默认子卷（回滚后默认子卷是快照）。注意 `set-default` 只认数字 ID（不接受路径名），需用 `btrfs subvolume list` 动态取 `@` 的 ID。

### GPT 分区标签与 EFI 分区定位

- `root` 分区：**不再依赖 partlabel 定位**（多系统共存时 `by-partlabel/root` 会歧义）。`01` 单系统分支仍打 `root` 标签（向后兼容），双系统分支不打标签、用「创建前后 `lsblk` 对比」确定设备路径；`03-repair.sh` 按 btrfs 文件系统类型探测（单个自动、多个交互选择）。
- EFI 分区：双系统下可能复用自其他系统（标签未必是 `ESP`），所以 `01`（双系统分支）和 `03-repair.sh` 都按 GPT 类型 GUID（`C12A7328-F81F-11D2-BA4B-00A0C93EC93B`）自动检测，而非依赖 `by-partlabel/ESP`。注意 `lsblk` 输出 GUID 为小写、且默认带树形符号，需用 `-r` 去符号、`tolower` 比较大小写。
- `04-subvol.sh` 不依赖分区标签（它从 `/etc/fstab` 的 `subvol=@` 条目解析根分区）。

## 脚本间的共享模式

```bash
# 所有脚本通用的输出函数
output() { printf '\e[1;34m%-6s\e[m\n' "${@}"; }   # 蓝色信息
err()    { printf '\e[1;31m%-6s\e[m\n' "${@}" >&2; }  # 红色错误

# 所有脚本统一使用严格模式
set -euo pipefail
```

## CI

GitHub Actions `ShellCheck`（`.github/workflows/shellcheck.yml`）在 push/PR 到 main 分支时对所有 `.sh` 文件运行 shellcheck。提交前本地运行：

```bash
shellcheck *.sh
```

## 项目约定

- 注释和用户可见输出使用中文，技术术语（btrfs、subvol、GRUB、ESP、snapper 等）保留英文。
- 脚本不覆盖用户已有配置文件，优先用 `sed` 精确修改指定行（见 `02-desktop.sh` 的 Rofi 主题配置）。
- 分区方案只有 ESP + root 两个分区，`/boot` 是 `@` 子卷内的普通目录，swap 用 zram 替代。
- 没有 LUKS 加密，没有独立 `/boot` 分区。
