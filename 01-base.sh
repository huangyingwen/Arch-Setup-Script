#!/bin/bash
#
# 01-base.sh — Arch Linux 基础安装脚本
#
# 用法：在 Arch Linux 官方安装 ISO 的 live 环境中以 root 运行：
#   curl -O https://.../01-base.sh
#   chmod +x 01-base.sh
#   ./01-base.sh
#
# 分区方案（启动时询问，二选一）：
#   - 单系统：清空整块磁盘，新建 ESP + root 两个分区（原有逻辑）。
#   - 双系统：不清空磁盘，复用已有 EFI 分区（不格式化），在空闲空间创建 root
#     分区，磁盘上其他已有分区（如 Windows）保持不变。
#
#   1) ESP   (fat32) -> /boot/efi   单系统新建；双系统复用已有（无则新建，大小 MiB）
#   2) ROOT  (btrfs)  -> /          单系统占满整块盘；双系统占满空闲空间（大小 GiB）
#
# 没有独立 /boot 分区、也没有 swap 分区：
#   - /boot 就是根子卷 @ 里的普通目录（不是单独的子卷），跟 GRUB + grub-btrfs
#     的标准用法一致：snapper 对根分区打快照时会把 /boot 一起打进去，回滚根
#     分区快照时内核/initramfs 会自动跟着回滚到一致的状态，不需要额外维护
#     一套 /boot 备份机制。
#   - swap 用 zram（内存压缩交换）代替物理分区，不占用磁盘空间，配置在
#     /etc/systemd/zram-generator.conf。
#
# btrfs 子卷划分分三类考虑：
#   - nodatacow 类：/var/log /var/cache /tmp /var/tmp /var/spool 等高频写入、
#     可重新生成或本身就是临时数据的目录，用 nodatacow 减少写放大，
#     体积增长快也没必要挤进 snapper 快照。
#   - 快照隔离类：/home /root /srv /var/lib/docker /var/lib/libvirt/images
#     /var/lib/machines 等，属于"数据"而非"系统状态"，独立子卷后就不会在
#     根分区 snapper 回滚时被一起"传送"回去（比如回滚系统不该连带删掉
#     昨天新建的虚拟机镜像）。
#   - 服务可写类：/var/lib/sddm /var/lib/AccountsService 单独分出，是因为把
#     根快照设为只读默认子卷后，sddm 仍需要写这两个目录，官方 wiki 也建议
#     独立出来。
#
# 备份/恢复策略：
#   - snapper 定时快照 + grub-btrfs 生成可启动的快照菜单项（包含 /boot），
#     出问题时可直接 `snapper rollback` 回滚（无需先从快照启动）。
#
# 系统崩溃后如需从 live ISO 挂载已安装好的系统进行维护，见配套的
# 03-repair.sh。
#
set -euo pipefail

output() {
  printf '\e[1;34m%-6s\e[m\n' "${@}"
}

err() {
  printf '\e[1;31m%-6s\e[m\n' "${@}" >&2
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
if [ ! -d /sys/firmware/efi/efivars ]; then
  err '未检测到 UEFI 引导环境，本脚本仅支持 UEFI + GRUB。请以 UEFI 模式启动安装介质。'
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  err '请以 root 身份运行本脚本（live 环境默认就是 root）。'
  exit 1
fi

timedatectl set-ntp true

# ---------------------------------------------------------------------------
# 虚拟机检测（VMware 需安装 open-vm-tools 获得剪贴板/显示集成）
# 虚拟显卡由内核 vmwgfx + mesa svga 驱动支持，无需额外装包
# ---------------------------------------------------------------------------
VM_PACKAGES=''
VM_SERVICES=''
if systemd-detect-virt --quiet --vmware 2>/dev/null; then
  VM_PACKAGES='open-vm-tools'
  VM_SERVICES='vmtoolsd.service'
  output '检测到 VMware 虚拟机，将安装 open-vm-tools。'
fi

# ---------------------------------------------------------------------------
# 镜像源（中国大陆）
# ---------------------------------------------------------------------------
mirror_prompt() {
  output '是否切换为中国大陆 pacman 镜像源以加速下载？'
  output '1) 是'
  output '2) 否，保留默认'
  read -r choice
  case ${choice} in
  1)
    curl -L 'https://archlinux.org/mirrorlist/?country=CN&protocol=https' -o /etc/pacman.d/mirrorlist
    sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist
    ;;
  2) ;;
  *)
    output '无效选择。'
    mirror_prompt
    ;;
  esac
}

# ---------------------------------------------------------------------------
# 用户输入
# ---------------------------------------------------------------------------
disk_prompt() {
  lsblk
  output '请选择要安装到的磁盘（安装模式稍后询问；单系统会清空整块磁盘，请谨慎选择）：'
  select entry in $(lsblk -dpnoNAME | grep -P "/dev/nvme|/dev/sd|/dev/vd|/dev/mmcblk"); do
    disk="${entry}"
    output "将安装到磁盘：${disk}"
    break
  done
}

dual_boot_prompt() {
  output '请选择安装模式：'
  output '1) 单系统：清空整块磁盘，新建 ESP + root 分区（磁盘上所有数据将被删除）'
  output '2) 双系统：保留磁盘上已有系统（如 Windows），复用 EFI 分区，在空闲空间创建 root 分区'
  read -r choice
  case ${choice} in
  1) DUAL_BOOT=false ;;
  2) DUAL_BOOT=true ;;
  *)
    output '无效选择。'
    dual_boot_prompt
    ;;
  esac
}

is_positive_int() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  *) return 0 ;;
  esac
}

size_prompt() {
  output '设置分区大小。'

  read -r -p 'EFI 分区大小 (MiB, 默认 512，仅在需要新建 EFI 分区时生效): ' esp_size
  esp_size=${esp_size:-512}

  # 验证 ESP 大小
  if ! is_positive_int "${esp_size}"; then
    output "分区大小必须是数字，请重新输入。"
    size_prompt
    return
  fi

  output '根分区大小：直接按 Enter 使用磁盘剩余空间，输入数字则以 GiB 为单位。'
  read -r -p '根分区大小 (GiB, 直接回车使用剩余空间): ' root_size

  # 如果输入了值，验证必须是正整数
  if [ -n "${root_size}" ]; then
    if ! is_positive_int "${root_size}"; then
      output "分区大小必须是数字，请重新输入。"
      size_prompt
      return
    fi
  fi
}

username_prompt() {
  read -r -p '设置用户名: ' username
  [ -z "${username}" ] && {
    output '用户名不能为空。'
    username_prompt
  } || true
}

fullname_prompt() {
  read -r -p '设置用户全名（可留空）: ' fullname
}

user_password_prompt() {
  read -r -s -p '设置用户密码: ' user_password
  echo
  read -r -s -p '再次确认密码: ' user_password2
  echo
  if [ -z "${user_password}" ] || [ "${user_password}" != "${user_password2}" ]; then
    output '密码为空或两次不一致，请重试。'
    user_password_prompt
  fi
}

hostname_prompt() {
  read -r -p '设置主机名: ' hostname
  [ -z "${hostname}" ] && {
    output '主机名不能为空。'
    hostname_prompt
  } || true
}

timezone_prompt() {
  read -r -p '设置时区 (默认 Asia/Shanghai): ' timezone
  timezone=${timezone:-Asia/Shanghai}
}

clear
mirror_prompt
disk_prompt
dual_boot_prompt
size_prompt
username_prompt
fullname_prompt
user_password_prompt
hostname_prompt
timezone_prompt

locale=en_US

# ---------------------------------------------------------------------------
# 分区：根据安装模式分流
# ---------------------------------------------------------------------------
if ${DUAL_BOOT}; then
  # 双系统：不清空磁盘，复用已有 EFI 分区（若有），在空闲空间创建 root 分区
  output "检测 ${disk} 上的分区布局 ..."

  # EFI 系统分区的 GPT 类型 GUID（parttype）
  EFI_TYPE='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'

  # 查找已有 EFI 分区：存在则复用（不格式化，避免破坏已有系统的引导），否则新建
  # 注意：-r 去除 lsblk 树形符号（├─/└─），tolower 处理 GUID 大小写差异
  ESP_PART=$(lsblk -rnpo NAME,PARTTYPE "${disk}" 2>/dev/null | awk -v t="${EFI_TYPE}" 'tolower($2)==tolower(t){print $1; exit}')

  NEW_ESP=false
  if [ -n "${ESP_PART}" ]; then
    ESP="${ESP_PART}"
    output "检测到已有 EFI 分区 ${ESP}，将复用它（不会格式化）。"
  else
    NEW_ESP=true
    output '未检测到 EFI 分区，将新建一个。'
    sgdisk -n "0:0:+${esp_size}M" -t "0:ef00" -c "0:ESP" "${disk}"
    partprobe "${disk}"
    sleep 2
    ESP=$(lsblk -rnpo NAME,PARTTYPE "${disk}" | awk -v t="${EFI_TYPE}" 'tolower($2)==tolower(t){print $1; exit}')
  fi

  # root 分区：在磁盘空闲空间创建（分区号自动分配），输入大小则按 GiB，否则占满剩余空闲空间。
  # 不打 root 标签：多系统共存时 partlabel "root" 会歧义（详见 CLAUDE.md）。
  # 先记录已有分区，创建后对比 lsblk 找出新增分区，用设备路径定位（确定性）。
  output '在空闲空间创建 root 分区 ...'
  existing_parts=$(lsblk -rnpo NAME "${disk}" | sort)
  if [ -n "${root_size}" ]; then
    sgdisk -n "0:0:+${root_size}GiB" -t "0:8300" "${disk}"
  else
    sgdisk -n "0:0:0" -t "0:8300" "${disk}"
  fi

  partprobe "${disk}"
  sleep 2

  ROOTPART=$(lsblk -rnpo NAME "${disk}" | grep -vFxf <(printf '%s\n' "${existing_parts}") | head -1)
  if [ -z "${ROOTPART}" ]; then
    err '未能确定新建的 root 分区设备路径，请手动 lsblk 确认。'
    lsblk
    exit 1
  fi
  output "root 分区：${ROOTPART}"
else
  # 单系统：清空整块磁盘，新建 ESP + root 两个分区（原有逻辑）
  output "正在清空并重新分区 ${disk} ..."
  sgdisk --zap-all "${disk}"
  sgdisk -g "${disk}"

  sgdisk -n "1:0:+${esp_size}M" -t "1:ef00" -c "1:ESP" "${disk}"

  # 根分区：输入了大小则使用指定大小（GiB），否则使用剩余全部空间
  if [ -n "${root_size}" ]; then
    sgdisk -n "2:0:+${root_size}GiB" -t "2:8300" -c "2:root" "${disk}"
  else
    sgdisk -n "2:0:0" -t "2:8300" -c "2:root" "${disk}"
  fi

  partprobe "${disk}"
  sleep 2

  ESP=/dev/disk/by-partlabel/ESP
  ROOTPART=/dev/disk/by-partlabel/root
  NEW_ESP=true
fi

# ---------------------------------------------------------------------------
# 格式化
# ---------------------------------------------------------------------------
if ${NEW_ESP}; then
  output '格式化新建的 EFI 分区为 FAT32 ...'
  mkfs.fat -F 32 -n ESP "${ESP}"
else
  output '复用已有 EFI 分区，跳过格式化 ...'
fi

BTRFS="${ROOTPART}"

output '格式化根分区为 btrfs ...'
mkfs.btrfs -L ARCH-ROOT -f "${BTRFS}"
mount "${BTRFS}" /mnt

output '创建 btrfs 子卷 ...'
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@root
btrfs su cr /mnt/@snapshots
btrfs su cr /mnt/@srv
btrfs su cr /mnt/@var_log
btrfs su cr /mnt/@var_cache
btrfs su cr /mnt/@tmp
btrfs su cr /mnt/@var_tmp
btrfs su cr /mnt/@var_spool
btrfs su cr /mnt/@var_lib_docker
btrfs su cr /mnt/@var_lib_libvirt_images
btrfs su cr /mnt/@var_lib_machines
btrfs su cr /mnt/@var_lib_sddm
btrfs su cr /mnt/@var_lib_AccountsService

# 设置默认子卷为 @：根分区 fstab 不写 subvol，靠默认子卷定位，
# 这样 snapper rollback 的 set-default 才能切换根目录（fstab 里写死 subvol= 会覆盖默认子卷导致回滚失效）。
# 注意：btrfs subvolume set-default 只认数字 ID，故动态取 @ 的 ID 而非写死 256。
AT_ID=$(btrfs subvolume list /mnt | awk '$0 ~ / path @$/ {print $2}')
btrfs subvolume set-default "${AT_ID}" /mnt
umount /mnt

MOUNT_OPTS='ssd,noatime,compress=zstd,space_cache=v2'

# 挂载根子卷 @（默认子卷已设为 @，故无需 subvol=@）；
# /boot 是 @ 里的普通目录（没有单独挂载点），会随根分区快照一起备份。
mount -o "${MOUNT_OPTS}" "${BTRFS}" /mnt
mkdir -p /mnt/{home,root,.snapshots,srv,boot}
mkdir -p /mnt/var/{log,cache,tmp,spool,lib/docker,lib/libvirt/images,lib/machines,lib/sddm,lib/AccountsService}
mkdir -p /mnt/tmp

mount -o "${MOUNT_OPTS},subvol=@home" "${BTRFS}" /mnt/home
mount -o "${MOUNT_OPTS},subvol=@root" "${BTRFS}" /mnt/root
mount -o "${MOUNT_OPTS},subvol=@snapshots" "${BTRFS}" /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@srv" "${BTRFS}" /mnt/srv
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_log" "${BTRFS}" /mnt/var/log
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_cache" "${BTRFS}" /mnt/var/cache
mount -o "${MOUNT_OPTS},nodatacow,subvol=@tmp" "${BTRFS}" /mnt/tmp
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_tmp" "${BTRFS}" /mnt/var/tmp
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_spool" "${BTRFS}" /mnt/var/spool
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_lib_docker" "${BTRFS}" /mnt/var/lib/docker
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_lib_libvirt_images" "${BTRFS}" /mnt/var/lib/libvirt/images
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_lib_machines" "${BTRFS}" /mnt/var/lib/machines
# sddm（在 02-desktop.sh 中安装）在根快照只读时仍需写入这两个目录
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_lib_sddm" "${BTRFS}" /mnt/var/lib/sddm
mount -o "${MOUNT_OPTS},nodatacow,subvol=@var_lib_AccountsService" "${BTRFS}" /mnt/var/lib/AccountsService

output '挂载 ESP 到 /boot/efi ...'
mkdir -p /mnt/boot/efi
mount "${ESP}" /mnt/boot/efi

# ---------------------------------------------------------------------------
# Pacstrap（sddm 由 02-desktop.sh 安装，此处不装）
# ---------------------------------------------------------------------------
output '安装基础系统（这需要一些时间）...'
pacstrap /mnt base base-devel linux linux-firmware linux-headers \
  btrfs-progs grub efibootmgr grub-btrfs inotify-tools snapper snap-pac \
  networkmanager sudo git neovim reflector openssh firewalld \
  zram-generator tmux \
  ${VM_PACKAGES} \
  inter-font adobe-source-serif-fonts noto-fonts-cjk noto-fonts-emoji ttf-sarasa-gothic \
  fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt fcitx5-configtool

# 双系统：安装 os-prober 以便 GRUB 检测 Windows 等其他系统
if ${DUAL_BOOT}; then
  pacstrap /mnt os-prober
fi

# CPU 微码（虚拟机跳过，虚拟 CPU 不需要）
if [ -z "${VM_PACKAGES}" ]; then
  CPU=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
  if [ "${CPU}" = 'GenuineIntel' ]; then
    pacstrap /mnt intel-ucode
  elif [ "${CPU}" = 'AuthenticAMD' ]; then
    pacstrap /mnt amd-ucode
  fi
fi

# ---------------------------------------------------------------------------
# zram swap（代替 swap 分区）
# ---------------------------------------------------------------------------
output '配置 zram swap ...'
cat >/mnt/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# ---------------------------------------------------------------------------
# fstab
# ---------------------------------------------------------------------------
output '生成 fstab ...'
genfstab -U /mnt >>/mnt/etc/fstab

# 根分区条目不写 subvol/subvolid，让它跟随 btrfs 默认子卷（snapper rollback 依赖此机制）。
sed -i -E '/^[^#]/ { /^[^[:space:]]+[[:space:]]+\/[[:space:]]+btrfs[[:space:]]/ s/(,?(subvol|subvolid)=[^ ,[:space:]]+)//g }' /mnt/etc/fstab

# ---------------------------------------------------------------------------
# 主机名 / hosts
# ---------------------------------------------------------------------------
echo "${hostname}" >/mnt/etc/hostname
cat >/mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF

# ---------------------------------------------------------------------------
# 中文支持：系统默认英文（en_US），同时生成 zh_CN locale、安装中文字体与
# fcitx5 中文输入法，供需要时切换/使用。
# ---------------------------------------------------------------------------
output '配置语言环境（系统默认英文，另生成中文 locale）...'
{
  echo "${locale}.UTF-8 UTF-8"
  echo "zh_CN.UTF-8 UTF-8"
} >>/mnt/etc/locale.gen
echo "LANG=${locale}.UTF-8" >/mnt/etc/locale.conf
echo 'KEYMAP=us' >/mnt/etc/vconsole.conf

# ---------------------------------------------------------------------------
# mkinitcpio：单设备 btrfs 根分区，filesystems + autodetect 会在 mkinitcpio -P
# 运行时（此时根分区已经以 btrfs 挂载）自动把 btrfs 模块收进镜像，不需要在
# MODULES 里手动声明（只有 btrfs 多设备 RAID 池才需要）。
# fsck 对 btrfs 是空操作所以不加；microcode 早期加载由 GRUB 自动拼接
# intel-ucode.img/amd-ucode.img 完成，跟 mkinitcpio HOOKS 无关，也不需要
# 新式的 microcode hook。显式指定 zstd 压缩，解压比默认更快。
# ---------------------------------------------------------------------------
output '配置 mkinitcpio ...'
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard)/' /mnt/etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION="zstd"/COMPRESSION="zstd"/' /mnt/etc/mkinitcpio.conf
if ! grep -q '^COMPRESSION="zstd"' /mnt/etc/mkinitcpio.conf; then
  echo 'COMPRESSION="zstd"' >>/mnt/etc/mkinitcpio.conf
fi
if grep -q '^#COMPRESSION_OPTIONS=' /mnt/etc/mkinitcpio.conf; then
  sed -i 's/^#COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-3)/' /mnt/etc/mkinitcpio.conf
else
  echo 'COMPRESSION_OPTIONS=(-3)' >>/mnt/etc/mkinitcpio.conf
fi

# ---------------------------------------------------------------------------
# chroot 内配置
# ---------------------------------------------------------------------------
output '进入 chroot 完成剩余配置 ...'
arch-chroot /mnt /bin/bash -e <<CHROOT
ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime
hwclock --systohc
locale-gen
mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# 双系统：启用 os-prober，让 GRUB 检测到 Windows 等其他系统
if ${DUAL_BOOT}; then
  if grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
  else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
  fi
fi

grub-mkconfig -o /boot/grub/grub.cfg

useradd -c "${fullname}" -m -G wheel "${username}"

# snapper 根分区配置
umount /.snapshots
rm -rf /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable firewalld
systemctl enable sshd
systemctl enable fstrim.timer
systemctl enable grub-btrfsd.service
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
# VMware 集成服务
[ -n "${VM_SERVICES}" ] && systemctl enable ${VM_SERVICES} || true
CHROOT

echo -e "${user_password}\n${user_password}" | arch-chroot /mnt passwd "${username}" || true

output '完成基础安装。现在可以重启进入新系统。'
output '重启后，请以你创建的用户登录，然后运行 02-desktop.sh 安装 Hyprland 桌面环境。'
output '需要回滚时执行: sudo snapper -c root list  查看快照编号，再 sudo snapper -c root rollback <编号>（/boot 会一起回滚）。'
output '系统崩溃无法启动时，用 live ISO 运行 03-repair.sh 挂载后再修复。'
