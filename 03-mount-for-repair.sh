#!/bin/bash
#
# 03-mount-for-repair.sh — 挂载已安装系统以便维护/修复
#
# 用法：系统无法正常启动时，用 Arch 官方安装 ISO 启动机器，联网后运行：
#   curl -O https://.../03-mount-for-repair.sh
#   chmod +x 03-mount-for-repair.sh
#   ./03-mount-for-repair.sh
#
# 本脚本假定磁盘分区是用 01-install-base.sh 创建的，分区标签固定为
# ESP / root，通过 /dev/disk/by-partlabel/ 直接找到，不需要知道具体是
# /dev/sda 还是 /dev/nvme0n1。/boot 是根子卷 @ 里的普通目录，随 @ 一起挂载，
# 不需要单独处理；没有 swap 分区（用的是 zram，跟磁盘无关，live 环境里也
# 用不上）。
#
# 挂载完成后默认自动 arch-chroot 进入系统，退出 shell 后会自动卸载全部
# 挂载点，避免手动一个个 umount 遗漏导致下次进不去。
#
# 常见用途：
#   - GRUB 配置损坏，需要 chroot 进去重新 grub-mkconfig / grub-install
#   - mkinitcpio 需要重新生成
#   - 忘记密码，需要 chroot 进去 passwd
#   - 想在 chroot 里手动执行 snapper 回滚（sudo snapper -c root list / rollback）
#   - 单纯想在文件层面读写 / 排查系统内的文件
#
set -eu

NO_CHROOT_FLAG="${1:-}"

output() {
    printf '\e[1;34m%-6s\e[m\n' "${@}"
}

err() {
    printf '\e[1;31m%-6s\e[m\n' "${@}" >&2
}

if [ "$(id -u)" -ne 0 ]; then
    err '请以 root 身份运行本脚本（live 环境默认就是 root）。'
    exit 1
fi

MOUNT_ROOT=/mnt
MOUNT_OPTS='ssd,noatime,compress=zstd,space_cache=v2'

# 需要与 01-install-base.sh 保持一致的子卷列表（@ 除外，单独挂载）。
# 格式: "子卷名 挂载路径(相对 /mnt) 是否 nodatacow(1/0)"
SUBVOLS=(
    "@home        home                                0"
    "@root        root                                0"
    "@snapshots   .snapshots                          0"
    "@srv         srv                                 0"
    "@var_log     var/log                             1"
    "@var_cache   var/cache                           1"
    "@tmp         tmp                                 1"
    "@var_tmp     var/tmp                             1"
    "@var_spool   var/spool                            1"
    "@var_lib_docker            var/lib/docker              1"
    "@var_lib_libvirt_images    var/lib/libvirt/images      1"
    "@var_lib_machines          var/lib/machines            1"
    "@var_lib_sddm              var/lib/sddm                1"
    "@var_lib_AccountsService   var/lib/AccountsService     1"
)

ESP=/dev/disk/by-partlabel/ESP
ROOTPART=/dev/disk/by-partlabel/root

for dev in "${ESP}" "${ROOTPART}"; do
    if [ ! -e "${dev}" ]; then
        err "找不到 ${dev}，本脚本假定分区标签为 ESP / root。"
        err '如果你的分区不是用 01-install-base.sh 创建的，请手动 lsblk 确认分区并手动挂载。'
        lsblk
        exit 1
    fi
done

output '检测到以下分区：'
output "  ESP  : ${ESP}"
output "  root : ${ROOTPART}"

# ---------------------------------------------------------------------------
# 卸载函数：脚本退出（包括 chroot 结束后）自动调用，按相反顺序卸载。
# ---------------------------------------------------------------------------
cleanup() {
    output '正在卸载所有挂载点 ...'
    umount -R "${MOUNT_ROOT}" 2>/dev/null || true
    output '已卸载。'
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 挂载
# ---------------------------------------------------------------------------
output '挂载根子卷 @（/boot 就在里面，会一起挂载出来） ...'
mount -o "${MOUNT_OPTS},subvol=@" "${ROOTPART}" "${MOUNT_ROOT}"

for entry in "${SUBVOLS[@]}"; do
    # shellcheck disable=SC2086
    set -- ${entry}
    subvol="$1"
    relpath="$2"
    nodatacow="$3"

    target="${MOUNT_ROOT}/${relpath}"
    mkdir -p "${target}"

    opts="${MOUNT_OPTS},subvol=${subvol}"
    [ "${nodatacow}" = '1' ] && opts="${opts},nodatacow"

    output "挂载子卷 ${subvol} -> /${relpath}"
    mount -o "${opts}" "${ROOTPART}" "${target}"
done

output '挂载 ESP 到 /boot/efi ...'
mkdir -p "${MOUNT_ROOT}/boot/efi"
mount "${ESP}" "${MOUNT_ROOT}/boot/efi"

output '全部挂载完成，挂载点在 /mnt 下。'
output '常用命令: sudo snapper -c root list   查看快照编号'
output '        sudo snapper -c root rollback <编号>   回滚到该快照（含 /boot）'

# ---------------------------------------------------------------------------
# 进入 chroot；使用 --no-chroot 参数则跳过，仅挂载。
# ---------------------------------------------------------------------------
if [ "${NO_CHROOT_FLAG}" = '--no-chroot' ]; then
    output '已跳过 arch-chroot，维护完成后请手动运行:  umount -R /mnt'
    trap - EXIT
    exit 0
fi

output '进入 arch-chroot，退出 shell (exit) 后会自动卸载所有挂载点 ...'
arch-chroot "${MOUNT_ROOT}" /bin/bash || true

# trap 会在脚本退出时自动执行 cleanup
