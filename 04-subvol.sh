#!/bin/bash
#
# 04-subvol.sh — 动态添加 btrfs 子卷（适用于已安装运行的系统）
#
# 用法:
#   sudo ./04-subvol.sh <子卷名> <挂载路径> [nodatacow]
#
# 示例:
#   sudo ./04-subvol.sh @var_lib_postgres /var/lib/postgres nodatacow
#   sudo ./04-subvol.sh @opt_myapp      /opt/myapp
#
# 说明:
#   1. 临时挂载 btrfs 顶层子卷 (subvolid=5)
#   2. 创建子卷，可选设置 nodatacow
#   3. 创建挂载点目录
#   4. 追加 /etc/fstab 条目
#   5. 追加 /etc/btrfs-subvols.conf 注册表（供 03-repair.sh 发现动态子卷）
#   6. 立即挂载
#
set -euo pipefail

output() { printf '\e[1;34m%-6s\e[m\n' "${@}"; }
err()    { printf '\e[1;31m%-6s\e[m\n' "${@}" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err '请以 root 身份运行本脚本。'
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "用法: $0 <子卷名> <挂载路径> [nodatacow]"
    echo "示例: $0 @var_lib_postgres /var/lib/postgres nodatacow"
    exit 1
fi

SUBVOL_NAME="$1"
MOUNT_PATH="$2"
NODATACOW="${3:-}"

# 找到 btrfs 根分区（通过 fstab 中 subvol=@ 的那一行）
ROOT_DEVICE=$(awk '$2=="/" && $3=="btrfs" {print $1}' /etc/fstab)
if [ -z "${ROOT_DEVICE}" ]; then
    err '无法从 /etc/fstab 找到 btrfs 根分区。'
    exit 1
fi
output "根分区: ${ROOT_DEVICE}"

# 检查子卷是否已存在
TEMP_MOUNT=$(mktemp -d)
mount -o subvolid=5 "${ROOT_DEVICE}" "${TEMP_MOUNT}"
trap 'umount "${TEMP_MOUNT}" && rmdir "${TEMP_MOUNT}"' EXIT

if [ -d "${TEMP_MOUNT}/${SUBVOL_NAME}" ]; then
    output "子卷 ${SUBVOL_NAME} 已存在，跳过创建。"
else
    output "创建子卷: ${SUBVOL_NAME}"
    btrfs subvolume create "${TEMP_MOUNT}/${SUBVOL_NAME}"
fi

if [ "${NODATACOW}" = 'nodatacow' ]; then
    output "为 ${SUBVOL_NAME} 设置 nodatacow ..."
    chattr +C "${TEMP_MOUNT}/${SUBVOL_NAME}" || true
fi

# 创建挂载点
output "创建挂载点: ${MOUNT_PATH}"
mkdir -p "${MOUNT_PATH}"

# 检查 fstab 是否已有该条目
if grep -q "subvol=${SUBVOL_NAME}" /etc/fstab; then
    output "fstab 中已存在 ${SUBVOL_NAME} 条目，跳过写入。"
else
    # 构建挂载选项
    MOUNT_OPTS='ssd,noatime,compress=zstd,space_cache=v2'
    [ "${NODATACOW}" = 'nodatacow' ] && MOUNT_OPTS="${MOUNT_OPTS},nodatacow" || true

    output "追加 /etc/fstab 条目 ..."
    cat >> /etc/fstab << EOF
# ${SUBVOL_NAME}
${ROOT_DEVICE} ${MOUNT_PATH} btrfs ${MOUNT_OPTS},subvol=${SUBVOL_NAME} 0 0
EOF
fi

# ---------------------------------------------------------------------------
# 子卷注册表（供 03-repair.sh 发现动态添加的子卷）
# 格式: 子卷名 挂载路径 [nodatacow]
# 与 fstab 独立维护，系统修复时不会因为 fstab 损坏而丢失子卷信息
# ---------------------------------------------------------------------------
REGISTRY='/etc/btrfs-subvols.conf'

if grep -q "^${SUBVOL_NAME} " "${REGISTRY}" 2>/dev/null; then
    output "注册表 ${REGISTRY} 中已存在 ${SUBVOL_NAME}，跳过写入。"
else
    output "追加子卷注册表 ${REGISTRY} ..."
    echo "${SUBVOL_NAME} ${MOUNT_PATH} ${NODATACOW}" >> "${REGISTRY}"
fi

# 挂载
if mountpoint -q "${MOUNT_PATH}"; then
    output "${MOUNT_PATH} 已挂载，跳过。"
else
    output "挂载 ${MOUNT_PATH} ..."
    mount "${MOUNT_PATH}"
fi

output "完成: ${SUBVOL_NAME} -> ${MOUNT_PATH}"
