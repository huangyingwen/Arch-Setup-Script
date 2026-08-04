#!/bin/bash
#
# 03-repair.sh — 挂载已安装系统以便维护/修复
#
# 用法：系统无法正常启动时，用 Arch 官方安装 ISO 启动机器，联网后运行：
#   curl -O https://.../03-repair.sh
#   chmod +x 03-repair.sh
#   ./03-repair.sh               # 默认：基线 + 注册表
#   ./03-repair.sh --from-fstab  # 基线 + fstab（注册表不可用时备选）
#   ./03-repair.sh --no-chroot   # 仅挂载，不进入 chroot
#
# 子卷发现策略（按优先级合并，去重）：
#   1. 硬编码基线列表（始终加载，保证核心子卷不遗漏）
#   2. 默认读取 /etc/btrfs-subvols.conf（由 04-subvol.sh 维护）
#   3. --from-fstab 时改为解析 /etc/fstab 中的 btrfs 子卷条目
#
# 本脚本假定磁盘分区是用 01-base.sh 创建的，分区标签固定为
# ESP / root，通过 /dev/disk/by-partlabel/ 直接找到。/boot 是根子卷 @ 里的
# 普通目录，随 @ 一起挂载，不需要单独处理；没有 swap 分区（用 zram）。
#
# 挂载完成后默认自动 arch-chroot 进入系统，退出 shell 后会自动卸载全部
# 挂载点。
#
# 常见用途：
#   - GRUB 配置损坏，需要 chroot 进去重新 grub-mkconfig / grub-install
#   - mkinitcpio 需要重新生成
#   - 忘记密码，需要 chroot 进去 passwd
#   - 想在 chroot 里手动执行 snapper 回滚
#   - 单纯想在文件层面读写 / 排查系统内的文件
#
set -euo pipefail

FROM_FSTAB=false
NO_CHROOT=false

for arg in "${@}"; do
    case "${arg}" in
        --from-fstab) FROM_FSTAB=true ;;
        --no-chroot)  NO_CHROOT=true  ;;
        *)            ;;
    esac
done

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

# ===========================================================================
# 硬编码基线子卷列表（@ 除外，单独挂载）
# 格式: "子卷名 挂载路径(相对 /mnt) 是否 nodatacow(1/0)"
# 这是最后的兜底——即使注册表和 fstab 都不可用，核心子卷也不会遗漏
# ===========================================================================
BASELINE_SUBVOLS=(
    "@home        home                                0"
    "@root        root                                0"
    "@snapshots   .snapshots                          0"
    "@srv         srv                                 0"
    "@var_log     var/log                             1"
    "@var_cache   var/cache                           1"
    "@tmp         tmp                                 1"
    "@var_tmp     var/tmp                             1"
    "@var_spool   var/spool                           1"
    "@var_lib_docker            var/lib/docker              1"
    "@var_lib_libvirt_images    var/lib/libvirt/images       1"
    "@var_lib_machines          var/lib/machines             1"
    "@var_lib_sddm              var/lib/sddm                 1"
    "@var_lib_AccountsService   var/lib/AccountsService      1"
)

ESP=/dev/disk/by-partlabel/ESP
ROOTPART=/dev/disk/by-partlabel/root

for dev in "${ESP}" "${ROOTPART}"; do
    if [ ! -e "${dev}" ]; then
        err "找不到 ${dev}，本脚本假定分区标签为 ESP / root。"
        err '如果你的分区不是用 01-base.sh 创建的，请手动 lsblk 确认分区并手动挂载。'
        lsblk
        exit 1
    fi
done

output '检测到以下分区：'
output "  ESP  : ${ESP}"
output "  root : ${ROOTPART}"

# ---------------------------------------------------------------------------
# 卸载函数：脚本退出时自动调用，按相反顺序卸载
# ---------------------------------------------------------------------------
cleanup() {
    output '正在卸载所有挂载点 ...'
    umount -R "${MOUNT_ROOT}" 2>/dev/null || true
    output '已卸载。'
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 挂载根子卷 @
# ---------------------------------------------------------------------------
output '挂载根子卷 @（/boot 在里面，会一起挂载） ...'
mount -o "${MOUNT_OPTS},subvol=@" "${ROOTPART}" "${MOUNT_ROOT}"

# ---------------------------------------------------------------------------
# 收集动态子卷：优先注册表，--from-fstab 时改用 fstab
# 返回格式与 BASELINE_SUBVOLS 一致: "子卷名 挂载路径(绝对) nodatacow(1/0)"
# ---------------------------------------------------------------------------
declare -a DYNAMIC_SUBVOLS=()

if ${FROM_FSTAB}; then
    # 从 fstab 解析 btrfs 子卷（排除根子卷 @）
    output '子卷来源: 基线 + /etc/fstab'
    FSTAB="${MOUNT_ROOT}/etc/fstab"
    if [ -f "${FSTAB}" ]; then
        while IFS= read -r line; do
            # 跳过空行和注释
            [[ -z "${line}" || "${line}" == '#'* ]] && continue
            # 只处理 btrfs 类型且含 subvol= 的条目
            echo "${line}" | grep -q 'btrfs.*subvol=' || continue
            subvol=$(echo "${line}" | sed -n 's/.*subvol=\([^ ,]*\).*/\1/p')
            [ -z "${subvol}" ] && continue
            # 排除根子卷 @
            [ "${subvol}" = '@' ] && continue
            mount_path=$(echo "${line}" | awk '{print $2}')
            [ -z "${mount_path}" ] && continue
            # 判断 nodatacow
            nodatacow=0
            echo "${line}" | grep -q 'nodatacow' && nodatacow=1
            # 转为注册表格式：路径是绝对路径（如 /home）
            DYNAMIC_SUBVOLS+=("${subvol} ${mount_path} ${nodatacow}")
        done < "${FSTAB}"
        output "  从 fstab 解析到 ${#DYNAMIC_SUBVOLS[@]} 个子卷"
    else
        output "  警告: ${FSTAB} 不存在，仅使用基线列表"
    fi
else
    # 默认从注册表读取
    output '子卷来源: 基线 + /etc/btrfs-subvols.conf'
    REGISTRY="${MOUNT_ROOT}/etc/btrfs-subvols.conf"
    if [ -f "${REGISTRY}" ]; then
        while IFS= read -r line; do
            # 跳过空行和注释
            [[ -z "${line}" || "${line}" == '#'* ]] && continue
            # 格式: 子卷名 挂载路径 [nodatacow]
            read -r subvol mount_path nodatacow <<< "${line}"
            [ "${nodatacow}" = 'nodatacow' ] && nodatacow=1 || nodatacow=0
            DYNAMIC_SUBVOLS+=("${subvol} ${mount_path} ${nodatacow}")
        done < "${REGISTRY}"
        output "  从注册表解析到 ${#DYNAMIC_SUBVOLS[@]} 个动态子卷"
    else
        output "  注册表 ${REGISTRY} 不存在，仅使用基线列表"
    fi
fi

# ---------------------------------------------------------------------------
# 合并基线 + 动态子卷，按子卷名去重（动态覆盖基线同名字卷）
# ---------------------------------------------------------------------------
declare -A SEEN_SUBVOLS  # 子卷名 -> "挂载路径 nodatacow"

# 先加载基线
for entry in "${BASELINE_SUBVOLS[@]}"; do
    read -r subvol relpath nodatacow <<< "${entry}"
    SEEN_SUBVOLS["${subvol}"]="${relpath} ${nodatacow}"
done
output "  基线子卷: ${#BASELINE_SUBVOLS[@]} 个"

# 再加载动态（覆盖同名字卷）
for entry in "${DYNAMIC_SUBVOLS[@]}"; do
    read -r subvol abspath nodatacow <<< "${entry}"
    # 将绝对路径转为相对 /mnt 的路径
    relpath="${abspath#/}"
    SEEN_SUBVOLS["${subvol}"]="${relpath} ${nodatacow}"
done

output "  合并后共 ${#SEEN_SUBVOLS[@]} 个子卷待挂载"

# ---------------------------------------------------------------------------
# 挂载所有子卷
# ---------------------------------------------------------------------------
for subvol in "${!SEEN_SUBVOLS[@]}"; do
    read -r relpath nodatacow <<< "${SEEN_SUBVOLS[${subvol}]}"

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
output '常用命令: snapper -c root list   查看快照编号'
output '        snapper -c root rollback <编号>   回滚到该快照（含 /boot）'

# ---------------------------------------------------------------------------
# 进入 chroot；--no-chroot 则跳过
# ---------------------------------------------------------------------------
if ${NO_CHROOT}; then
    output '已跳过 arch-chroot，维护完成后请手动运行:  umount -R /mnt'
    trap - EXIT
    exit 0
fi

output '进入 arch-chroot，退出 shell (exit) 后会自动卸载所有挂载点 ...'
arch-chroot "${MOUNT_ROOT}" /bin/bash || true

# trap 会在脚本退出时自动执行 cleanup
