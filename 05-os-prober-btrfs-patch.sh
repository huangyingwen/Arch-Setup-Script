#!/bin/bash
#
# 05-os-prober-btrfs-patch.sh — 修复 os-prober 对 btrfs 子卷系统的检测与引导
#
# 运行环境: 已安装运行中的系统（root）
# 前置条件: 已安装 os-prober（01-base.sh 双系统分支会安装）
#
# 解决的问题（三层，均为 os-prober 对 btrfs 子卷布局的缺陷）:
#   1. os-probes/50mounted-tests 与 linux-boot-probes/50mounted-tests 用
#      grub-mount 挂载 btrfs 分区，grub-mount 读的是顶层（FS_TREE），看不到
#      默认子卷 @ 里的 /etc/os-release 与内核，导致检测不到子卷系统。
#      改为对 btrfs 分区用内核 mount（读默认子卷）。
#   2. linux-boot-probes/90fallback 生成的引导路径不带子卷名前缀（/boot/ 而非
#      /@/boot/），而 GRUB 读 btrfs 从顶层开始，会报 "file not found"。
#      改为在路径前加默认子卷名。
#   3. 90fallback 不加载 CPU 微码（amd-ucode.img / intel-ucode.img），补上。
#
# 用法:
#   sudo ./05-os-prober-btrfs-patch.sh            # 应用补丁（幂等，可重复运行）
#   sudo ./05-os-prober-btrfs-patch.sh --restore  # 用 .bak 备份回滚
#
# 注意: pacman 升级 os-prober 会覆盖补丁，重新运行本脚本即可再次应用。

set -euo pipefail

output() { printf '\e[1;34m%-6s\e[m\n' "${@}"; }
err()    { printf '\e[1;31m%-6s\e[m\n' "${@}" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err '请以 root 运行：sudo ./05-os-prober-btrfs-patch.sh'
    exit 1
fi

# ---------------------------------------------------------------------------
# --restore：用 .bak 备份回滚补丁
# ---------------------------------------------------------------------------
if [ "${1:-}" = '--restore' ]; then
    output '恢复 os-prober 原始文件（.bak）...'
    for f in \
        /usr/lib/linux-boot-probes/mounted/90fallback \
        /usr/lib/os-probes/50mounted-tests \
        /usr/lib/linux-boot-probes/50mounted-tests; do
        if [ -f "${f}.bak" ]; then
            cp -a "${f}.bak" "${f}"
            output "  已恢复 ${f}"
        else
            output "  无备份，跳过 ${f}"
        fi
    done
    output '恢复完成。'
    exit 0
fi

if [ ! -f /usr/lib/os-probes/50mounted-tests ]; then
    err '未找到 os-prober，请先安装：pacman -S os-prober'
    exit 1
fi

output '为 os-prober 应用 btrfs 子卷补丁 ...'

python3 - <<'PYEOF'
import os, shutil, sys


def apply(path, patches, marker):
    """对 path 应用 patches（(old, new) 列表）。marker 已存在则视为已打补丁跳过。"""
    with open(path) as f:
        content = f.read()
    if marker in content:
        print("  已打补丁，跳过: {}".format(os.path.basename(path)))
        return
    bak = path + '.bak'
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print("  已备份: {}".format(bak))
    for old, new in patches:
        if content.count(old) != 1:
            print("  错误: {} 补丁点未唯一匹配，os-prober 版本可能变化，请手动检查".format(path))
            sys.exit(1)
        content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("  已打补丁: {}".format(path))


# 补丁 1: 90fallback —— 路径加 btrfs 默认子卷前缀 + 加载 CPU 微码
subvol_block = '''mappedpartition=$(mapdevfs "$partition" 2>/dev/null) || mappedpartition="$partition"

# 检测 btrfs 默认子卷：GRUB 读 btrfs 从顶层开始，路径需带子卷名前缀（如 /@/boot/...）
subvol_prefix=""
if [ "$type" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
    defsubvol=$(btrfs subvolume get-default "$mpoint" 2>/dev/null | awk 'NR==1 && $2 != 5 {print $NF}')
    if [ -n "$defsubvol" ]; then
        subvol_prefix="/$defsubvol"
    fi
fi

# 检测 CPU 微码文件（os-prober 默认不加载微码，这里补上）
ucode=""
for ucodef in "$mpoint"/boot/amd-ucode.img "$mpoint"/boot/intel-ucode.img "$mpoint"/amd-ucode.img "$mpoint"/intel-ucode.img; do
    if [ -f "$ucodef" ] && [ ! -L "$ucodef" ]; then
        ucode="${subvol_prefix}$(echo "$ucodef" | sed "s!^$mpoint!!") "
        break
    fi
done
'''

apply('/usr/lib/linux-boot-probes/mounted/90fallback', [
    ('mappedpartition=$(mapdevfs "$partition" 2>/dev/null) || mappedpartition="$partition"',
     subvol_block),
    ('kernbasefile=$(echo "$kernfile" | sed "s!^$mpoint!!")',
     'kernbasefile="${subvol_prefix}$(echo "$kernfile" | sed "s!^$mpoint!!")"'),
    ('initrd=$(echo "$initrd" | sed "s!^$mpoint!!")',
     'initrd="${subvol_prefix}$(echo "$initrd" | sed "s!^$mpoint!!")"'),
    ('result "$partition:$kernbootpart::$kernbasefile:$initrd:root=$mappedpartition"',
     'result "$partition:$kernbootpart::$kernbasefile:${ucode}${initrd}:root=$mappedpartition"'),
], '检测 btrfs 默认子卷')

# 补丁 2 & 3: 两个 50mounted-tests —— btrfs 分区改用内核 mount（读默认子卷）
mount_block = '''mounted=
# btrfs 分区用内核 mount（读默认子卷），grub-mount 读的是顶层，会漏掉子卷里的系统
if [ "$types" = "btrfs" ]; then
    if mount -o ro "$partition" "$tmpmnt" 2>/dev/null; then
        mounted=1
        type=btrfs
        debug "mounted btrfs using kernel driver (default subvolume)"
    fi
fi

if [ -z "$mounted" ] && type grub-mount >/dev/null 2>&1 &&'''

for path in ('/usr/lib/os-probes/50mounted-tests',
             '/usr/lib/linux-boot-probes/50mounted-tests'):
    apply(path, [
        ('mounted=\nif type grub-mount >/dev/null 2>&1 &&', mount_block),
    ], 'btrfs 分区用内核 mount')

print('补丁应用完成。')
PYEOF

output '完成。重新生成 GRUB 配置即可生效：'
output '  sudo grub-mkconfig -o /boot/grub/grub.cfg'
